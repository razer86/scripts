#Requires -RunAsAdministrator

# ---------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------

function Write-Section ($title) {
    Write-Host ""
    Write-Host "=== $title ===" -ForegroundColor Cyan
    Write-Host ""
}

function Write-StepHeader ($step, $total, $label) {
    Write-Host "[$step/$total] " -ForegroundColor DarkGray -NoNewline
    Write-Host $label -ForegroundColor White
}

function Write-OK ($msg = "OK") {
    Write-Host "         $msg" -ForegroundColor Green
}

function Write-Warn ($msg) {
    Write-Host "         $msg" -ForegroundColor Yellow
}

function Write-Fail ($msg) {
    Write-Host "         FAILED: $msg" -ForegroundColor Red
}

function Invoke-Download ($url, $dest) {
    Write-Host "         Downloading..." -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

# ---------------------------------------------------------------
# Setup
# ---------------------------------------------------------------

$tempDir = Join-Path $env:TEMP "LaptopSetup"
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$rebootRequired = @()
$failed = @()

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Laptop Setup Script" -ForegroundColor Cyan
Write-Host "  Machine: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------
# SECTION 1: HP Driver SoftPaqs
# ---------------------------------------------------------------

Write-Section "HP Drivers"

$softpaqs = Get-ChildItem -Path $PSScriptRoot -Filter "sp*.exe" | Sort-Object Name
$driverTotal = $softpaqs.Count
Write-Host "Found $driverTotal softpaqs" -ForegroundColor DarkGray
Write-Host ""

for ($i = 0; $i -lt $driverTotal; $i++) {
    $exe = $softpaqs[$i]
    $spNumber = $exe.BaseName

    $cvaPath = Join-Path $PSScriptRoot "$spNumber.cva"
    $friendlyName = $spNumber
    if (Test-Path $cvaPath) {
        $titleLine = Select-String -Path $cvaPath -Pattern "^US=" | Select-Object -First 1
        if ($titleLine) { $friendlyName = $titleLine.Line -replace "^US=", "" }
    }

    Write-StepHeader ($i + 1) $driverTotal $friendlyName
    Write-Host "         $spNumber" -ForegroundColor DarkGray

    $proc = Start-Process -FilePath $exe.FullName -ArgumentList "/s" -Wait -PassThru -NoNewWindow

    switch ($proc.ExitCode) {
        0      { Write-OK }
        3010   { Write-Warn "OK (reboot required)"; $rebootRequired += $friendlyName }
        default { Write-Fail "exit code $($proc.ExitCode)"; $failed += "Driver: $friendlyName (exit $($proc.ExitCode))" }
    }
    Write-Host ""
}

# ---------------------------------------------------------------
# SECTION 2: System Configuration
# ---------------------------------------------------------------

Write-Section "System Configuration"

# -- Time sync --
Write-StepHeader 1 2 "Configure time sync (time.google.com)"
try {
    w32tm /config /manualpeerlist:"time.google.com" /syncfromflags:manual /reliable:YES /update | Out-Null
    Restart-Service w32tm -Force
    w32tm /resync /force | Out-Null
    Write-OK "Time server set and synced"
} catch {
    Write-Fail $_.Exception.Message
    $failed += "Time sync"
}
Write-Host ""

# -- Computer rename --
Write-StepHeader 2 2 "Rename computer"
try {
    $serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim()
    $newName = "LJHBTLPT-$($serial.Substring($serial.Length - 4))"
    if ($env:COMPUTERNAME -eq $newName) {
        Write-OK "Already named $newName - skipping"
    } else {
        Rename-Computer -NewName $newName -Force -ErrorAction Stop
        Write-OK "Renamed to $newName (takes effect after reboot)"
        $rebootRequired += "Computer rename ($newName)"
    }
} catch {
    Write-Fail $_.Exception.Message
    $failed += "Computer rename"
}
Write-Host ""

# ---------------------------------------------------------------
# SECTION 3: Software Installation
# ---------------------------------------------------------------

Write-Section "Software Installation"

# -- Atera --
Write-StepHeader 1 4 "Atera Agent"
try {
    $ateraExe = Join-Path $tempDir "AteraAgent.exe"
    Invoke-Download 'https://NQBE184848.servicedesk.atera.com/api/utils/agent-install/windows/?cid=384&aeid=2d04f0af12544f838df2c7b5fa3dbca2' $ateraExe
    $proc = Start-Process -FilePath $ateraExe -ArgumentList "/silent" -Wait -PassThru
    if ($proc.ExitCode -eq 0) { Write-OK } else { Write-Warn "Exit code $($proc.ExitCode) (may still be OK)" }
} catch {
    Write-Fail $_.Exception.Message
    $failed += "Atera Agent"
}
Write-Host ""

# -- ScreenConnect --
Write-StepHeader 2 4 "ScreenConnect"
try {
    $scMsi = Join-Path $tempDir "ScreenConnect.msi"
    Invoke-Download 'https://neconnect.screenconnect.com/Bin/ScreenConnect.ClientSetup.msi?e=Access&y=Guest&c=LJ%20Hooker%20Gladstone%2FBoyne&c=Boyne%20Tannum&c=&c=&c=CAPC&c=&c=&c=' $scMsi
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $scMsi, '/qn', '/norestart') -Wait -PassThru
    if ($proc.ExitCode -eq 0) {
        Write-OK
    } else {
        Write-Fail ('msiexec exit code ' + $proc.ExitCode)
        $failed += ('ScreenConnect (exit ' + $proc.ExitCode + ')')
    }
} catch {
    Write-Fail $_.Exception.Message
    $failed += "ScreenConnect"
}
Write-Host ""

# -- Sophos --
Write-StepHeader 3 4 "Sophos"
try {
    $sophosExe = Join-Path $tempDir "SophosSetup.exe"
    Invoke-Download "https://dzr-api-amzn-us-west-2-fa88.api-upe.p.hmr.sophos.com/api/download/e5bbb4e592523cccc8a66c58f2b68ec5/SophosSetup.exe" $sophosExe
    $proc = Start-Process -FilePath $sophosExe -ArgumentList "--quiet" -Wait -PassThru
    if ($proc.ExitCode -eq 0) { Write-OK } else { Write-Warn "Exit code $($proc.ExitCode) (Sophos may continue in background)" }
} catch {
    Write-Fail $_.Exception.Message
    $failed += "Sophos"
}
Write-Host ""

# -- Printer --
Write-StepHeader 4 4 "Printer"
$printerSetup = "F:\Drivers\Printer\setup.exe"
if (Test-Path $printerSetup) {
    try {
        $proc = Start-Process -FilePath $printerSetup -ArgumentList "/s" -Wait -PassThru
        if ($proc.ExitCode -eq 0) { Write-OK } else { Write-Fail "exit code $($proc.ExitCode)"; $failed += "Printer (exit $($proc.ExitCode))" }
    } catch {
        Write-Fail $_.Exception.Message
        $failed += "Printer"
    }
} else {
    Write-Warn "Skipped - setup.exe not found at $printerSetup"
}
Write-Host ""

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Setup Complete" -ForegroundColor Cyan
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
    Write-Host ""
    Write-Host "  Reboot before handing over to the client." -ForegroundColor Yellow
}

if ($failed.Count -eq 0 -and $rebootRequired.Count -eq 0) {
    Write-Host ""
    Write-Host "  All tasks completed successfully." -ForegroundColor Green
}

Write-Host ""

# Cleanup temp files
Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
