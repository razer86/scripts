<#
.SYNOPSIS
    Silently sets the OneDrive TimerAutoMount registry key at user login using a scheduled task.

.DESCRIPTION
    This script creates a PowerShell script to configure TimerAutoMount, wraps it with a VBScript launcher
    to suppress any window flashing, and registers a scheduled task to run it at every user login.

.AUTHOR
    Raymond Slater

.VERSION
    1.2
#>

# =============================
# ===   Configuration Block ===
# =============================

$basePath        = "$env:ProgramData\WebbBros\scripts"
$psScriptName    = "FixTimerAutoMount.ps1"
$vbsScriptName   = "FixTimerAutoMount.vbs"
$taskName        = "Fix-OneDrive-TimerAutoMount"
$logPath         = "$basePath\TimerAutoMount.log"
$enableLogging   = $true

$psScriptPath    = Join-Path $basePath $psScriptName
$vbsScriptPath   = Join-Path $basePath $vbsScriptName

# Ensure the directory exists
if (-not (Test-Path -Path $basePath)) {
    New-Item -Path $basePath -ItemType Directory -Force | Out-Null
}

# =============================
# ===   Logging Function     ===
# =============================

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    if ($enableLogging) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$timestamp [$Level] $Message" | Out-File -FilePath $logPath -Append -Encoding utf8
    }
}

# =============================
# ===   Script Generators   ===
# =============================

function Create-FixScript {
    Write-Log "Creating PowerShell fix script at $psScriptPath"

    $psContent = @'
$regPath = "HKCU:\Software\Microsoft\OneDrive\Accounts\Business1"
$regName = "Timerautomount"
$desiredValue = 1

try {
    if (-not (Test-Path -Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name $regName -Value $desiredValue -Type QWord
} catch {
    # Optional: error handling/logging
}
'@

    try {
        Set-Content -Path $psScriptPath -Value $psContent -Encoding UTF8 -Force
        Write-Log "PowerShell script created successfully."
    } catch {
        Write-Log "Failed to create PowerShell script: $_" "ERROR"
        throw
    }
}

function Create-VbsLauncher {
    Write-Log "Creating simplified VBS launcher at $vbsScriptPath"

    $vbsContent = @"
Set objShell = CreateObject("Wscript.Shell")
objShell.Run "reg add HKCU\Software\Microsoft\OneDrive\Accounts\Business1 /v Timerautomount /t REG_QWORD /d 1 /f", 0, False
"@

    try {
        Set-Content -Path $vbsScriptPath -Value $vbsContent -Encoding ASCII -Force
        Write-Log "VBS launcher created successfully."
    } catch {
        Write-Log "Failed to create VBS launcher: $_" "ERROR"
        throw
    }
}


# =============================
# ===   Task Registration   ===
# =============================

function Register-LoginTask {
    Write-Log "Registering scheduled task: $taskName"

    $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsScriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId "Users" -RunLevel Limited

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force
        Write-Log "Scheduled task registered successfully."
    } catch {
        Write-Log "Failed to register scheduled task: $_" "ERROR"
        throw
    }
}

# =============================
# ===   Main Execution      ===
# =============================

try {
    Write-Log "Starting OneDrive TimerAutoMount fix setup..."
    Create-FixScript
    Create-VbsLauncher
    Register-LoginTask
    Write-Log "Setup completed successfully."
} catch {
    Write-Log "Setup failed: $_" "CRITICAL"
    exit 1
}
