<#
.SYNOPSIS
    Verifies RDP Wrapper is patched and functional. Logs result to the Application
    event log (source RDPWrapMonitor) so Atera can alert on it.

.DESCRIPTION
    Checks performed:
      1. TermService is running
      2. TermService ServiceDll points at rdpwrap.dll (not the stock termsrv.dll)
      3. rdpwrap.dll is actually loaded inside the TermService svchost process
      4. The installed termsrv.dll version has a matching [x.x.x.x] section in rdpwrap.ini
      5. RDP listener port is in LISTEN state
      6. fSingleSessionPerUser / fDenyTSConnections not set against us

    Event IDs (Application log, source RDPWrapMonitor):
      1000 = Information, all checks passed
      1001 = Error, one or more checks failed (Atera alerts on this)
      1002 = Error, check script itself hit an exception
      1003-1005 are written by Repair-RdpWrapIni.ps1 (see that script)

    Exit code 0 = healthy, 1 = failed. Atera Automation Profiles show non-zero as a failed run.
#>

[CmdletBinding()]
param(
    # Set this if users share a single account and each connection must get its own session.
    # Without it, fSingleSessionPerUser=1 (the Windows default) is reported but not treated as a failure.
    [switch]$RequireMultiSessionPerUser,
    # When the failure is a missing rdpwrap.ini section, run Repair-RdpWrapIni.ps1 (same folder) to add it.
    # Never restarts TermService; the repair script logs 1003 so the restart gets scheduled.
    [switch]$AutoRepair
)

$ErrorActionPreference = 'Stop'
$Source  = 'RDPWrapMonitor'
$LogName = 'Application'

if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
    New-EventLog -LogName $LogName -Source $Source
}

$fail = New-Object System.Collections.Generic.List[string]
$info = New-Object System.Collections.Generic.List[string]

try {
    # 1. Service running (allow up to 3 min on a slow boot before calling it a failure)
    $svc = Get-Service TermService
    if ($svc.Status -ne 'Running') {
        try { $svc.WaitForStatus('Running', [TimeSpan]::FromMinutes(3)) } catch {}
        $svc.Refresh()
    }
    if ($svc.Status -ne 'Running') { $fail.Add("TermService status is '$($svc.Status)'") }

    # 2. ServiceDll -> rdpwrap.dll
    $svcDll = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters' -Name ServiceDll).ServiceDll
    $svcDll = [Environment]::ExpandEnvironmentVariables($svcDll)
    $info.Add("ServiceDll = $svcDll")
    if ($svcDll -notmatch 'rdpwrap\.dll$') {
        $fail.Add("ServiceDll is not rdpwrap.dll (RDP Wrapper uninstalled or reverted by Windows Update)")
    }
    elseif (-not (Test-Path $svcDll)) {
        $fail.Add("ServiceDll path does not exist: $svcDll")
    }

    # 3. rdpwrap.dll loaded in the TermService host process
    $pidTS = (Get-CimInstance Win32_Service -Filter "Name='TermService'").ProcessId
    if ($pidTS -gt 0) {
        $loaded = $false
        try {
            $loaded = [bool]((Get-Process -Id $pidTS).Modules | Where-Object { $_.ModuleName -ieq 'rdpwrap.dll' })
        } catch {
            # Modules enumeration can fail for a 64-bit svchost from a 32-bit host; fall back to tasklist
            $loaded = (tasklist /m rdpwrap.dll /fi "PID eq $pidTS" 2>$null) -match 'svchost'
        }
        $info.Add("rdpwrap.dll loaded in PID $pidTS = $loaded")
        if (-not $loaded) { $fail.Add("rdpwrap.dll is not loaded in TermService process (PID $pidTS)") }
    } else {
        $fail.Add("TermService has no running process")
    }

    # 4. termsrv.dll version has a section in rdpwrap.ini
    $termsrv    = Join-Path $env:SystemRoot 'System32\termsrv.dll'
    $termsrvVer = (Get-Item $termsrv).VersionInfo
    $verString  = '{0}.{1}.{2}.{3}' -f $termsrvVer.FileMajorPart, $termsrvVer.FileMinorPart, $termsrvVer.FileBuildPart, $termsrvVer.FilePrivatePart
    $info.Add("termsrv.dll = $verString")

    # Only meaningful when ServiceDll is rdpwrap.dll; otherwise check 2 already reported the real problem
    if ($svcDll -match 'rdpwrap\.dll$') {
        $iniPath = Join-Path (Split-Path $svcDll -Parent) 'rdpwrap.ini'
        if (-not (Test-Path $iniPath)) {
            $fail.Add("rdpwrap.ini not found at $iniPath")
        } else {
            $iniText = Get-Content $iniPath -Raw
            if ($iniText -notmatch "(?m)^\[$([regex]::Escape($verString))\]\s*$") {
                $fail.Add("rdpwrap.ini has no [$verString] section - termsrv.dll was updated and is NOT supported by the current ini")
                $repair = Join-Path $PSScriptRoot 'Repair-RdpWrapIni.ps1'
                if ($AutoRepair -and (Test-Path $repair)) {
                    $repairOut = & $repair 2>&1 | Out-String
                    $info.Add("Auto-repair (exit $LASTEXITCODE):`n" + (($repairOut.Trim() -split "`r?`n" | ForEach-Object { "    $_" }) -join "`n"))
                }
            } else {
                $info.Add("rdpwrap.ini has [$verString] section")
            }
            if ($iniText -match '(?m)^Updated=(.+)$') { $info.Add("rdpwrap.ini Updated=$($Matches[1].Trim())") }
        }
    }

    # 5. Listener port
    $port = 3389
    try { $port = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name PortNumber).PortNumber } catch {}
    $listening = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    $info.Add("Port $port listening = $([bool]$listening)")
    if (-not $listening) { $fail.Add("Nothing is listening on TCP $port") }

    # 6. Policy / registry flags that would silently kill multi-session
    $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    if ($ts.fDenyTSConnections -eq 1)   { $fail.Add("fDenyTSConnections=1 (Remote Desktop disabled)") }
    $polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
    $pol = if (Test-Path $polPath) { Get-ItemProperty $polPath } else { $null }
    if ($pol -and $pol.MaxInstanceCount -eq 1) { $fail.Add("GPO MaxInstanceCount=1 (limits server to one RDP session)") }

    # fSingleSessionPerUser=1 only stops the SAME account holding two sessions; different users are unaffected.
    $singlePerUser = ($ts.fSingleSessionPerUser -eq 1) -or ($pol -and $pol.fSingleSessionPerUser -eq 1)
    $srcNote = if ($pol -and $pol.fSingleSessionPerUser -eq 1) { 'enforced by GPO' } else { 'registry' }
    $info.Add("SingleSessionPerUser = $singlePerUser ($srcNote)")
    if ($RequireMultiSessionPerUser -and $singlePerUser) {
        $fail.Add("fSingleSessionPerUser=1 ($srcNote) but multiple sessions per account are required")
    }

    # Active sessions (informational, helps with post-mortem)
    $sessions = (query session 2>$null | Select-String -Pattern '^\s*(rdp-tcp#\d+)' -AllMatches).Count
    $info.Add("Active RDP sessions = $sessions")
}
catch {
    $msg = "RDPWrapMonitor script exception: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    Write-EventLog -LogName $LogName -Source $Source -EntryType Error -EventId 1002 -Message $msg
    Write-Output $msg
    exit 1
}

$detail = ($info | ForEach-Object { "  $_" }) -join "`n"

if ($fail.Count -gt 0) {
    $msg = "RDP Wrapper check FAILED on $env:COMPUTERNAME`n`nFailures:`n" + (($fail | ForEach-Object { "  - $_" }) -join "`n") + "`n`nDetails:`n$detail"
    Write-EventLog -LogName $LogName -Source $Source -EntryType Error -EventId 1001 -Message $msg
    Write-Output $msg
    exit 1
}
else {
    $msg = "RDP Wrapper check OK on $env:COMPUTERNAME`n`nDetails:`n$detail"
    Write-EventLog -LogName $LogName -Source $Source -EntryType Information -EventId 1000 -Message $msg
    Write-Output $msg
    exit 0
}

