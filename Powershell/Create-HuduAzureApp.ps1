# =========================================
# ===   Create Azure App for Hudu     ===
# =========================================
# Author: Raymond Slater
# Version: 1.0
# Date: 2025-05-28
# https://github.com/razer86/scripts

param (
    [string]$AppName = "Hudu M365 Integration",
    [int]$SecretExpiryInMonths = 12
)

# =========================================
# ===   Pre-Flight Checks for Hudu App ===
# =========================================

# Minimum PowerShell version
$requiredPSVersion = [Version]"7.0"
if ($PSVersionTable.PSVersion -lt $requiredPSVersion) {
    Write-Error "This script requires PowerShell $requiredPSVersion or higher. Current: $($PSVersionTable.PSVersion)"
    exit 1
}

# Required module
$moduleName = "Microsoft.Graph"
$requiredCmds = @("Connect-MgGraph", "Get-MgOrganization", "New-MgApplication")

# Check for module
if (-not (Get-Module -ListAvailable -Name $moduleName)) {
    Write-Warning "The required module '$moduleName' is not installed."
    $install = Read-Host "Would you like to install it now? (Y/N)"
    if ($install -match '^y') {
        try {
            Install-Module -Name $moduleName -Scope CurrentUser -Force
        } catch {
            Write-Error "Failed to install Microsoft.Graph: $_"
            exit 1
        }
    } else {
        Write-Error "Cannot continue without Microsoft.Graph. Exiting."
        exit 1
    }
}

# Import the module and verify required commands
Import-Module $moduleName -Force
$missingCmds = $requiredCmds | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if ($missingCmds) {
    Write-Error "The following required cmdlets are missing even after importing the module: $($missingCmds -join ', ')"
    exit 1
}


# === Connect to Microsoft Graph ===
Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All", "Directory.AccessAsUser.All", "Policy.Read.All" -ContextScope Process -NoWelcome

# === Create App Registration ===
$app = New-MgApplication -DisplayName $AppName -RequiredResourceAccess @(
    @{
        ResourceAppId = "00000003-0000-0000-c000-000000000000" # Microsoft Graph
        ResourceAccess = @(
            @{ Id = "7ab1d382-f21e-4acd-a863-ba3e13f7da61"; Type = "Role" }  # Directory.Read.All
            @{ Id = "230c1aed-a721-4c5d-9cb4-a90514e508ef"; Type = "Role" }  # Reports.Read.All
            @{ Id = "df021288-bdef-4463-88db-98f22de89214"; Type = "Role" }  # User.Read.All
        )
    }
)

# === Create Service Principal ===
$sp = New-MgServicePrincipal -AppId $app.AppId

# === Create a Client Secret ===
$startDate = Get-Date
$endDate = $startDate.AddMonths($SecretExpiryInMonths)
$secret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{
    DisplayName = "Hudu Secret"
    StartDateTime = $startDate
    EndDateTime = $endDate
}

# === Output Details ===
$tenantId = (Get-MgOrganization).Id
Write-Host "`n=== Application Details for Hudu ==="
Write-Host "App Name:        $($app.DisplayName)"
Write-Host "Application ID:  $($app.AppId)"
Write-Host "Tenant ID:       $tenantId"
Write-Host "Client Secret:   $($secret.SecretText)"
Write-Host "Expires:         $($secret.EndDateTime)"


Write-Host "`n⚠️  You must manually grant admin consent in the portal:"
Write-Host "   https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$($app.AppId)/isMSAApp~/false"
