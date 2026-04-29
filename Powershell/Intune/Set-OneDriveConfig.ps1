#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Applies OneDrive configuration policies to a device.

    USAGE - Direct with parameter:
      .\Set-OneDriveConfig.ps1 -TenantID "your-tenant-id"

    USAGE - Via irm | iex (pre-set TenantID before piping):
      $TenantID = "your-tenant-id"; Invoke-Expression (Invoke-RestMethod "https://your-url/Set-OneDriveConfig.ps1")

    The tenant ID can be found in:
      - Intune Admin Center > Tenant administration > Properties
      - Azure AD Portal > Overview

.DESCRIPTION
    Sets the following OneDrive policies under HKLM:\SOFTWARE\Policies\Microsoft\OneDrive:
      - Silent Account Config (SSO sign-in)
      - Known Folder Move (Desktop, Documents, Pictures) silently
      - Files On Demand
      - Disable First Delete Dialog
      - Sync Admin Reports
      - PST file sync block

.PARAMETER TenantID
    The Azure AD / Intune Tenant ID for the customer. Required.

.NOTES
    Must be run as Administrator.
#>
param(
    [string]$TenantID = $TenantID  # Falls back to $TenantID if pre-set in session (irm | iex usage)
)

# ---------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------
$RegPath = "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive"

# ---------------------------------------------------------------
# Functions
# ---------------------------------------------------------------
function Write-Status {
    param([string]$Message, [string]$Type = "INFO")
    $colour = switch ($Type) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
    }
    Write-Host "[$Type] $Message" -ForegroundColor $colour
}

function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [string]$Type = "DWORD"
    )
    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
            Write-Status "Created registry key: $Path" "INFO"
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        Write-Status "Set $Name = $Value" "SUCCESS"
    }
    catch {
        Write-Status "Failed to set ${Name}: $_" "ERROR"
    }
}

# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "       OneDrive Policy Deployment Script        " -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# Verify running as admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Status "This script must be run as Administrator. Exiting." "ERROR"
    exit 1
}

# Verify TenantID has been provided
if ([string]::IsNullOrWhiteSpace($TenantID)) {
    Write-Status "No TenantID provided. Use -TenantID parameter or pre-set TenantID before invoking." "ERROR"
    Write-Status "Example: .\Set-OneDriveConfig.ps1 -TenantID 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'" "ERROR"
    Write-Status "Example: TenantID = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'; iex (irm 'https://your-url/Set-OneDriveConfig.ps1')" "ERROR"
    exit 1
}

Write-Status "Applying OneDrive policies to: $env:COMPUTERNAME" "INFO"
Write-Status "Tenant ID: $TenantID" "INFO"
Write-Status "Target registry path: $RegPath" "INFO"
Write-Host ""

# --- Silent Account Config ---
Set-RegValue -Path $RegPath -Name "SilentAccountConfig" -Value 1 -Type "DWORD"

# --- Known Folder Move (KFM) ---
Set-RegValue -Path $RegPath -Name "KFMSilentOptIn"                -Value $TenantID -Type "String"
Set-RegValue -Path $RegPath -Name "KFMSilentOptInWithNotification" -Value 0         -Type "DWORD"
Set-RegValue -Path $RegPath -Name "KFMSilentOptInDesktop"          -Value 1         -Type "DWORD"
Set-RegValue -Path $RegPath -Name "KFMSilentOptInDocuments"        -Value 1         -Type "DWORD"
Set-RegValue -Path $RegPath -Name "KFMSilentOptInPictures"         -Value 1         -Type "DWORD"

# --- Files On Demand ---
Set-RegValue -Path $RegPath -Name "FilesOnDemandEnabled" -Value 1 -Type "DWORD"

# --- UX ---
Set-RegValue -Path $RegPath -Name "DisableFirstDeleteDialog" -Value 1 -Type "DWORD"

# --- Sync Admin Reports ---
Set-RegValue -Path $RegPath -Name "EnableSyncAdminReports" -Value 1         -Type "DWORD"
Set-RegValue -Path $RegPath -Name "SyncAdminReports"       -Value $TenantID -Type "String"

# --- PST Block ---
$IgnoreListPath = "$RegPath\EnableODIgnoreListFromGPO"
Set-RegValue -Path $IgnoreListPath -Name "pst" -Value "pst" -Type "String"

# ---------------------------------------------------------------
# Verify
# ---------------------------------------------------------------
Write-Host ""
Write-Status "Verifying applied settings..." "INFO"
Write-Host ""

$applied = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
if ($applied) {
    $applied | Format-List SilentAccountConfig, KFMSilentOptIn, KFMSilentOptInWithNotification,
                            KFMSilentOptInDesktop, KFMSilentOptInDocuments, KFMSilentOptInPictures,
                            FilesOnDemandEnabled, DisableFirstDeleteDialog,
                            EnableSyncAdminReports, SyncAdminReports
    Write-Status "All policies applied successfully." "SUCCESS"
} else {
    Write-Status "Could not verify registry path. Please check manually." "ERROR"
}

# ---------------------------------------------------------------
# Restart OneDrive
# Skipped if running as SYSTEM (e.g. via ScreenConnect/RMM)
# ---------------------------------------------------------------
Write-Host ""

$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$isSystem    = $currentUser -eq "NT AUTHORITY\SYSTEM"

if ($isSystem) {
    Write-Status "Running as SYSTEM - skipping OneDrive restart." "WARN"
    Write-Status "OneDrive will apply the new config on next user login or manual restart." "WARN"
} else {
    Write-Status "Restarting OneDrive in user context..." "INFO"

    Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $oneDrivePaths = @(
        "C:\Program Files\Microsoft OneDrive\OneDrive.exe",
        "C:\Program Files (x86)\Microsoft OneDrive\OneDrive.exe"
    )

    $userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object { $_.Name -notin @("Public", "Default", "Default User") }
    foreach ($profile in $userProfiles) {
        $perUserPath = "$($profile.FullName)\AppData\Local\Microsoft\OneDrive\OneDrive.exe"
        if (Test-Path $perUserPath) {
            $oneDrivePaths = @($perUserPath) + $oneDrivePaths
        }
    }

    $oneDriveExe = $oneDrivePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($oneDriveExe) {
        $taskName  = "RestartOneDrive-TempTask"
        $action    = New-ScheduledTaskAction -Execute $oneDriveExe
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
        $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 8
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        Write-Status "OneDrive restarted from: $oneDriveExe" "SUCCESS"
    } else {
        Write-Status "OneDrive executable not found. Please restart OneDrive manually." "WARN"
    }
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Done. Policies applied to $env:COMPUTERNAME"   -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
