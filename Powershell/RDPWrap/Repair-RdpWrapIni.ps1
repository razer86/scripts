<#
.SYNOPSIS
    Adds the missing [termsrv version] section to rdpwrap.ini after a Windows Update bumps termsrv.dll.

.DESCRIPTION
    Idempotent. Exits 0 with no changes if the ini already covers the installed termsrv.dll.
    Otherwise finds offsets, in order of preference:
      1. Upstream sebaxakerhtc/rdpwrap.ini (if it already has the section)
      2. rdpwrap-offset-finder.exe (symbol mode, then --nosymbol) in the same folder as this script

    The ini is backed up (rdpwrap.ini.<timestamp>.bak) and the section(s) appended. RDP Wrapper only
    reads the ini at service start, so TermService must be restarted before it takes effect - that is
    NOT done unless -RestartService is passed (it drops every active RDP session).

    Event IDs (Application log, source RDPWrapMonitor):
      1003 = Error, ini patched, TermService restart REQUIRED (Atera alerts so someone schedules it)
      1004 = Error, could not repair (no offsets available / validation failed)
      1005 = Information, ini already current, or restart done and check passed

    Exit codes: 0 = nothing needed / repaired (and restarted if asked), 1 = repair failed, 2 = repaired but restart pending
#>

[CmdletBinding()]
param(
    [switch]$RestartService,        # restart TermService after patching and re-run the health check
    [switch]$DryRun,                # print what would be appended, change nothing
    [switch]$SkipUpstream,          # go straight to the offset finder (testing)
    [string]$IniPath,               # override (default: next to the ServiceDll rdpwrap.dll)
    [string]$TermsrvPath = "$env:SystemRoot\System32\termsrv.dll",
    [string]$OffsetFinderPath = (Join-Path $PSScriptRoot 'rdpwrap-offset-finder.exe'),
    [string]$UpstreamIniUrl = 'https://raw.githubusercontent.com/sebaxakerhtc/rdpwrap.ini/master/rdpwrap.ini'
)

$ErrorActionPreference = 'Stop'
$Source  = 'RDPWrapMonitor'
$LogName = 'Application'

function Write-MonitorEvent([int]$Id, [string]$Type, [string]$Message) {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) { New-EventLog -LogName $LogName -Source $Source }
        Write-EventLog -LogName $LogName -Source $Source -EntryType $Type -EventId $Id -Message $Message
    } catch { Write-Warning "Could not write event ${Id}: $($_.Exception.Message)" }
    Write-Output $Message
}

# Pull "[ver]" and "[ver-SLInit]" blocks out of ini text. Returns $null if the main section is absent.
function Get-IniSections([string]$Text, [string]$Version) {
    $blocks = @(foreach ($name in @($Version, "$Version-SLInit")) {
        $m = [regex]::Match($Text, "(?ms)^\[$([regex]::Escape($name))\]\s*$.*?(?=^\[|\z)")
        if ($m.Success) { $m.Value.TrimEnd() }
    })
    if (-not $blocks -or $blocks[0] -notmatch "^\[$([regex]::Escape($Version))\]") { return $null }
    return ($blocks -join "`r`n`r`n")
}

function Test-SectionValid([string]$Section, [string]$Version) {
    $required = 'LocalOnlyOffset.x64', 'SingleUserOffset.x64', 'DefPolicyOffset.x64', 'SLInitOffset.x64'
    $missing = $required | Where-Object { $Section -notmatch "(?m)^$([regex]::Escape($_))\s*=\s*[0-9A-Fa-f]+" }
    if ($missing) { throw "Section for $Version is missing keys: $($missing -join ', ')" }
    if ($Section -notmatch "(?m)^\[$([regex]::Escape($Version))-SLInit\]") { throw "Section for $Version has no -SLInit block" }
}

try {
    $v   = (Get-Item $TermsrvPath).VersionInfo
    $ver = '{0}.{1}.{2}.{3}' -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart

    if (-not $IniPath) {
        $svcDll = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters' -Name ServiceDll).ServiceDll)
        if ($svcDll -notmatch 'rdpwrap\.dll$') { throw "ServiceDll is '$svcDll', not rdpwrap.dll - RDP Wrapper is not installed; nothing to patch" }
        $IniPath = Join-Path (Split-Path $svcDll -Parent) 'rdpwrap.ini'
    }
    if (-not (Test-Path $IniPath)) { throw "rdpwrap.ini not found at $IniPath" }

    $iniText = Get-Content $IniPath -Raw
    if (Get-IniSections $iniText $ver) {
        Write-MonitorEvent 1005 Information "rdpwrap.ini already has [$ver]; no repair needed ($IniPath)"
        exit 0
    }

    # --- find offsets ---
    $section = $null; $origin = $null
    if (-not $SkipUpstream) {
        try {
            $upstream = (Invoke-WebRequest -Uri $UpstreamIniUrl -UseBasicParsing -TimeoutSec 30).Content
            $section  = Get-IniSections $upstream $ver
            if ($section) { $origin = "upstream ($UpstreamIniUrl)" }
            else { Write-Output "Upstream ini does not have [$ver] yet" }
        } catch { Write-Output "Upstream fetch failed: $($_.Exception.Message)" }
    }

    if (-not $section) {
        if (-not (Test-Path $OffsetFinderPath)) { throw "No upstream section and offset finder not found at $OffsetFinderPath" }
        foreach ($mode in @(@(), @('--nosymbol'))) {
            $out = & $OffsetFinderPath $TermsrvPath @mode 2>&1 | Out-String
            $candidate = Get-IniSections $out $ver
            if ($candidate) {
                try { Test-SectionValid $candidate $ver; $section = $candidate; $origin = "rdpwrap-offset-finder $($mode -join ' ')".Trim(); break }
                catch { Write-Output "Offset finder ($($mode -join ' ')) output rejected: $($_.Exception.Message)" }
            } else {
                Write-Output "Offset finder ($($mode -join ' ')) produced no [$ver] section: $($out.Trim())"
            }
        }
        if (-not $section) { throw "Could not obtain offsets for termsrv.dll $ver from upstream or offset finder" }
    }
    Test-SectionValid $section $ver

    if ($DryRun) {
        Write-Output "DRY RUN - would append to ${IniPath} (source: $origin):`n`n$section"
        exit 0
    }

    # --- apply ---
    $backup = "$IniPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item $IniPath $backup
    $sep = if ($iniText.EndsWith("`n")) { "`r`n" } else { "`r`n`r`n" }
    [IO.File]::AppendAllText($IniPath, "$sep$section`r`n", [Text.Encoding]::ASCII)

    if (-not (Get-IniSections (Get-Content $IniPath -Raw) $ver)) { throw "Appended section but re-read of $IniPath does not contain [$ver]" }

    $summary = "rdpwrap.ini patched for termsrv.dll $ver on $env:COMPUTERNAME`nSource : $origin`nBackup : $backup`n`n$section"

    if (-not $RestartService) {
        Write-MonitorEvent 1003 Error "$summary`n`nTermService restart REQUIRED for this to take effect - run outside business hours:`n  Repair-RdpWrapIni.ps1 -RestartService   (or Restart-Service TermService -Force)"
        exit 2
    }

    Write-Output "Restarting TermService..."
    Restart-Service TermService -Force
    Start-Sleep -Seconds 10
    $check = Join-Path $PSScriptRoot 'Test-RdpWrapStatus.ps1'
    $checkOut = if (Test-Path $check) { & $check 2>&1 | Out-String } else { "(Test-RdpWrapStatus.ps1 not found beside this script; check skipped)" }
    if ($LASTEXITCODE -eq 0) {
        Write-MonitorEvent 1005 Information "$summary`n`nTermService restarted; post-restart check:`n$checkOut"
        exit 0
    } else {
        Write-MonitorEvent 1004 Error "$summary`n`nTermService restarted but post-restart check FAILED:`n$checkOut"
        exit 1
    }
}
catch {
    Write-MonitorEvent 1004 Error "RDP Wrapper auto-repair FAILED on $env:COMPUTERNAME`n$($_.Exception.Message)`n$($_.ScriptStackTrace)"
    exit 1
}
