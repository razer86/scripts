<#
.SYNOPSIS
    Basic onboarding for a new Windows device: time settings, rename, and agent installs.

.DESCRIPTION
    A framework for new device run-ups. Each step runs only when its parameter is supplied
    (time zone and time sync run by default), so the same script covers any customer:

      - Sets the time zone (-TimeZone) and syncs time to an NTP server (-TimeServer)
      - Renames the computer, either to an exact name (-ComputerName) or to a prefix plus the
        end of the BIOS serial number (-NamePrefix)
      - Installs the Atera, ScreenConnect and Sophos agents from their download links

    Inputs are validated before any changes are made, one failed step doesn't stop the rest, and
    a summary at the end lists failures and anything that needs a reboot.

    To add a step, wrap it in Invoke-Step in the Steps region. Throw on failure; add to
    $rebootRequired if the step needs a reboot to finish.

.PARAMETER ComputerName
    Exact new computer name (max 15 letters, digits or hyphens). Can't be combined with -NamePrefix.

.PARAMETER NamePrefix
    Name the device <NamePrefix><end of the BIOS serial>. Uses the last -SerialLength serial
    characters, or fewer if the prefix is long, to fit the 15-character name limit (minimum 4).
    e.g. 'LJHB-' gives LJHB-5CD1234X, 'LJHBTLPT-' gives LJHBTLPT-D1234X.

.PARAMETER SerialLength
    Maximum trailing serial number characters -NamePrefix uses. Default 8.

.PARAMETER TimeZone
    Windows time zone ID. Default 'E. Australia Standard Time' (AEST, Brisbane - no daylight
    saving). Run Get-TimeZone -ListAvailable for IDs. Pass an empty string to skip.

.PARAMETER TimeServer
    NTP server to sync time from. Default time.google.com. Pass an empty string to skip.

.PARAMETER AteraInstallerUrl
    The customer's Atera agent download link (MSI or EXE). Skipped if omitted.

.PARAMETER ScreenConnectInstallerUrl
    The customer's ScreenConnect client MSI link (from Build Installer). Skipped if omitted.

.PARAMETER SophosInstallerUrl
    Tenant-specific SophosSetup.exe download link from Sophos Central. Skipped if omitted.

.PARAMETER Restart
    Restart automatically at the end (after a 60 second warning) if any step needs a reboot.

.EXAMPLE
    .\Invoke-DeviceOnboarding.ps1 -NamePrefix 'LJHB-' -AteraInstallerUrl '<Atera link>' -ScreenConnectInstallerUrl '<ScreenConnect link>' -SophosInstallerUrl '<Sophos link>' -Restart
    Full run-up: sets AEST and time sync, renames to LJHB-<last 8 of serial>, installs all three
    agents, and restarts.

.EXAMPLE
    .\Invoke-DeviceOnboarding.ps1 -ComputerName 'RECEPTION-01'
    Sets AEST and time sync and renames the device.

.NOTES
    File Name      : Invoke-DeviceOnboarding.ps1
    Author         : Raymond Slater
    Prerequisite   : PowerShell 5.1 or later, run as Administrator
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ComputerName,
    [string]$NamePrefix,
    [ValidateRange(1, 14)]
    [int]$SerialLength = 8,
    [string]$TimeZone = 'E. Australia Standard Time',
    [string]$TimeServer = 'time.google.com',
    [string]$AteraInstallerUrl,
    [string]$ScreenConnectInstallerUrl,
    [string]$SophosInstallerUrl,
    [switch]$Restart
)

#Region Helpers
function Write-OK   ($msg = 'OK') { Write-Host "   $msg" -ForegroundColor Green }
function Write-Warn ($msg)        { Write-Host "   $msg" -ForegroundColor Yellow }

function Write-Section ($title) {
    Write-Host ""
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

function Invoke-Step {
    <#
    .SYNOPSIS
        Runs one onboarding step, recording it as failed if it throws, so later steps still run.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Host ""
    Write-Host "-> $Name" -ForegroundColor White
    try {
        & $Action
    }
    catch {
        Write-Host "   FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $failed.Add($Name)
    }
}

function Invoke-InstallerFromUrl {
    <#
    .SYNOPSIS
        Downloads an installer and runs it silently: MSIs via msiexec, EXEs with -ExeArguments.
        Returns the finished process so the caller can judge the exit code.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$ExeArguments
    )

    $download = Join-Path $tempDir $Name
    Write-Host "   Downloading..." -ForegroundColor DarkGray
    $ProgressPreference = 'SilentlyContinue'  # the progress bar makes Invoke-WebRequest very slow in 5.1
    Invoke-WebRequest -Uri $Url -OutFile $download -UseBasicParsing -ErrorAction Stop

    # Download links don't reliably say what they return, so check the file header:
    # MSIs are OLE compound files (D0 CF 11 E0), EXEs start with "MZ"
    $stream = [System.IO.File]::OpenRead($download)
    try {
        $header = [byte[]]::new(4)
        [void]$stream.Read($header, 0, 4)
    }
    finally {
        $stream.Dispose()
    }

    if ($header[0] -eq 0xD0 -and $header[1] -eq 0xCF -and $header[2] -eq 0x11 -and $header[3] -eq 0xE0) {
        $msi = [System.IO.Path]::ChangeExtension($download, '.msi')
        Move-Item -LiteralPath $download -Destination $msi -Force
        Write-Host "   Installing (MSI)..." -ForegroundColor DarkGray
        return Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
    }
    if ($header[0] -eq 0x4D -and $header[1] -eq 0x5A) {
        $exe = [System.IO.Path]::ChangeExtension($download, '.exe')
        Move-Item -LiteralPath $download -Destination $exe -Force
        Write-Host "   Installing (EXE)..." -ForegroundColor DarkGray
        return Start-Process -FilePath $exe -ArgumentList $ExeArguments -Wait -PassThru
    }
    throw "downloaded file is neither an MSI nor an EXE - check the link hasn't expired"
}

function Resolve-InstallerExitCode {
    <#
    .SYNOPSIS
        Treats 0 as success, 3010/1641 as success-pending-reboot, and anything else as a failure.
    #>
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$Label
    )

    switch ($Process.ExitCode) {
        0                     { Write-OK }
        { $_ -in 3010, 1641 } { Write-Warn 'OK (reboot required)'; $rebootRequired.Add($Label) }
        default               { throw "exit code $($Process.ExitCode)" }
    }
}

function Get-TargetComputerName {
    if ($ComputerName) { return $ComputerName }

    $rawSerial = "$((Get-CimInstance -ClassName Win32_BIOS).SerialNumber)".Trim()

    # Whitebox and virtual machines often report a placeholder, which would give every such
    # device the same name
    $placeholders = 'Default string', 'To be filled by O.E.M.', 'System Serial Number',
                    'Not Specified', 'Not Applicable', 'None', 'Chassis Serial Number', '0', 'INVALID'
    if ($placeholders -contains $rawSerial -or $rawSerial -match '^(0+|1234567890?)$') {
        throw "BIOS serial is a placeholder ('$rawSerial') - use -ComputerName instead"
    }

    # Use up to -SerialLength serial characters, fewer if needed to fit the 15-character limit,
    # but never fewer than 4 or names stop being reliably unique
    $maxLength = 15
    $minSerialChars = 4
    $take = [math]::Min($SerialLength, $maxLength - $NamePrefix.Length)
    if ($take -lt $minSerialChars) {
        throw "Prefix '$NamePrefix' is too long - it must leave room for at least $minSerialChars serial characters (max $($maxLength - $minSerialChars) characters)"
    }

    $serial = $rawSerial -replace '[^A-Za-z0-9]', ''
    $take = [math]::Min($take, $serial.Length)
    if ($take -lt $minSerialChars) {
        throw "BIOS serial '$serial' is too short to build a name from - use -ComputerName instead"
    }
    return $NamePrefix + $serial.Substring($serial.Length - $take)
}
#EndRegion Helpers

#Region Pre-flight checks
# Validate everything up front so a bad input fails now, not halfway through the run.
$problems = [System.Collections.Generic.List[string]]::new()
$targetName = $null

if ($ComputerName -and $NamePrefix) {
    $problems.Add('Use either -ComputerName or -NamePrefix, not both.')
}
elseif ($ComputerName -or $NamePrefix) {
    try {
        $targetName = Get-TargetComputerName
        if ($targetName.Length -gt 15 -or $targetName -notmatch '^[A-Za-z0-9-]+$') {
            $problems.Add("'$targetName' is not a valid computer name (max 15 letters, digits or hyphens).")
        }
    }
    catch {
        $problems.Add($_.Exception.Message)
    }
}

if ($TimeZone -and -not (Get-TimeZone -ListAvailable | Where-Object Id -eq $TimeZone)) {
    $problems.Add("Unknown time zone '$TimeZone'. Run Get-TimeZone -ListAvailable for valid IDs.")
}

$installerUrls = [ordered]@{
    'AteraInstallerUrl'         = $AteraInstallerUrl
    'ScreenConnectInstallerUrl' = $ScreenConnectInstallerUrl
    'SophosInstallerUrl'        = $SophosInstallerUrl
}
foreach ($param in $installerUrls.Keys) {
    $url = $installerUrls[$param]
    if ($url -and $url -notmatch '^https?://') {
        $problems.Add("-$param must be an http(s) link.")
    }
}

if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "ERROR: $_" -ForegroundColor Red }
    return
}
#EndRegion Pre-flight checks

#Region Steps
$failed = [System.Collections.Generic.List[string]]::new()
$rebootRequired = [System.Collections.Generic.List[string]]::new()
$tempDir = Join-Path $env:TEMP 'DeviceOnboarding'
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

# Windows PowerShell 5.1 may not offer TLS 1.2 by default, which the download links need
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Device Onboarding" -ForegroundColor Cyan
Write-Host "  Machine: $env:COMPUTERNAME$(if ($targetName) { " -> $targetName" })" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if ($TimeZone -or $TimeServer -or $targetName) {
    Write-Section 'System Configuration'
}

if ($TimeZone) {
    Invoke-Step "Set time zone ($TimeZone)" {
        Set-TimeZone -Id $TimeZone -ErrorAction Stop
        Write-OK
    }
}

if ($TimeServer) {
    Invoke-Step "Sync time ($TimeServer)" {
        Set-Service -Name W32Time -StartupType Automatic -ErrorAction Stop
        Start-Service -Name W32Time -ErrorAction Stop

        w32tm /config /manualpeerlist:$TimeServer /syncfromflags:manual /update | Out-Null
        if ($LASTEXITCODE) { throw "w32tm /config failed (exit $LASTEXITCODE)" }

        Restart-Service -Name W32Time -Force -ErrorAction Stop
        w32tm /resync /force | Out-Null
        if ($LASTEXITCODE) { throw "w32tm /resync failed (exit $LASTEXITCODE)" }
        Write-OK "Time server set and synced"
    }
}

if ($targetName) {
    Invoke-Step "Rename computer to $targetName" {
        if ($env:COMPUTERNAME -eq $targetName) {
            Write-OK "Already named $targetName - skipping"
            return
        }
        Rename-Computer -NewName $targetName -Force -ErrorAction Stop
        Write-OK "Renamed (takes effect after reboot)"
        $rebootRequired.Add("Computer rename ($targetName)")
    }
}

if ($AteraInstallerUrl -or $ScreenConnectInstallerUrl -or $SophosInstallerUrl) {
    Write-Section 'Software'
}

if ($AteraInstallerUrl) {
    Invoke-Step 'Atera agent' {
        $proc = Invoke-InstallerFromUrl -Url $AteraInstallerUrl -Name 'AteraAgent' -ExeArguments '/silent'
        Resolve-InstallerExitCode -Process $proc -Label 'Atera agent'
    }
}

if ($ScreenConnectInstallerUrl) {
    Invoke-Step 'ScreenConnect client' {
        $proc = Invoke-InstallerFromUrl -Url $ScreenConnectInstallerUrl -Name 'ScreenConnect' -ExeArguments '/quiet'
        Resolve-InstallerExitCode -Process $proc -Label 'ScreenConnect client'
    }
}

if ($SophosInstallerUrl) {
    Invoke-Step 'Sophos endpoint agent' {
        $proc = Invoke-InstallerFromUrl -Url $SophosInstallerUrl -Name 'SophosSetup' -ExeArguments '--quiet'
        if ($proc.ExitCode -eq 0) {
            Write-OK
        } else {
            # SophosSetup often hands off to a background installer and returns non-zero anyway
            Write-Warn "Exit code $($proc.ExitCode) - Sophos may still be installing in the background; check Sophos Central"
        }
    }
}
#EndRegion Steps

#Region Summary
Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Onboarding Complete" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "FAILED ($($failed.Count)):" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

if ($rebootRequired.Count -gt 0) {
    Write-Host ""
    Write-Host "Reboot required for:" -ForegroundColor Yellow
    $rebootRequired | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }

    if ($Restart) {
        Write-Host ""
        Write-Host "  Restarting in 60 seconds (run 'shutdown /a' to cancel)..." -ForegroundColor Yellow
        shutdown.exe /r /t 60 /c "Device onboarding complete - restarting to apply changes."
    } else {
        Write-Host ""
        Write-Host "  Reboot before handing over to the client." -ForegroundColor Yellow
    }
}

if ($failed.Count -eq 0 -and $rebootRequired.Count -eq 0) {
    Write-Host ""
    Write-Host "  All tasks completed successfully." -ForegroundColor Green
}
Write-Host ""
#EndRegion Summary
