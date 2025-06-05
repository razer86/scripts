<#
.SYNOPSIS
    Creates a Microsoft Entra ID (Azure AD) application for use with Hudu M365 integration.

.DESCRIPTION
    This script automates the creation of an Azure application registration for Hudu. It assigns the required Microsoft Graph
    application permissions (Directory.Read.All, User.Read.All, Reports.Read.All), generates a client secret, and outputs the
    necessary configuration details for use within Hudu.

.PARAMETER AppName
    The display name for the Azure application. Default is "Hudu M365 Integration".

.PARAMETER SecretExpiryInMonths
    The number of months the client secret will remain valid. Default is 12 months.

.EXAMPLE
    .\Create-HuduAzureApp.ps1

    Creates the application with the default name and 12-month secret expiry.

.EXAMPLE
    .\Create-HuduAzureApp.ps1 -AppName "Contoso Hudu App" -SecretExpiryInMonths 24

    Creates the application named "Contoso Hudu App" with a 24-month client secret.

.NOTES
    Author: Raymond Slater
    Version: 1.2
    License: MIT
    Last Updated: 2025-06-04

.LINK
    https://support.hudu.com/hc/en-us/articles/11610345552407-Microsoft-Office-365
    https://github.com/razer86/scripts
#>

param (
    [string]$AppName = "Hudu M365 Integration",
    [int]$SecretExpiryInMonths = 12
)

# === Track start time for elapsed duration ===
$scriptStart = Get-Date

# === PowerShell version check ===
$requiredPSVersion = [Version]"7.0"
if ($PSVersionTable.PSVersion -lt $requiredPSVersion) {
    Write-Error "This script requires PowerShell $requiredPSVersion or higher. Current: $($PSVersionTable.PSVersion)"
    exit 1
}

# === Status output function ===
function Write-Status {
    param (
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("info", "success", "error")][string]$Type = "info"
    )
    $prefix = switch ($Type) {
        "info"    { "🔄" }
        "success" { "✅" }
        "error"   { "❌" }
        "warning" { "⚠️" }
    }
    $color = switch ($Type) {
        "info"    { "Cyan" }
        "success" { "Green" }
        "error"   { "Red" }
        "warning" { "Yellow" }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

# === Required Graph modules ===
$requiredModules = @(
    "Microsoft.Graph.Applications",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Authentication"
)

Write-Status -Message "Checking for required Microsoft Graph modules." -Type "info"
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        try {
            Write-Status -Message "Installing module: $mod" -Type "info"
            Install-Module $mod -Scope CurrentUser -Force -ErrorAction Stop
        } catch {
            Write-Status -Message "Failed to install module '$mod': $_" -Type "error"
            exit 1
        }
    }
    try {
        Import-Module $mod -Force -ErrorAction Stop
    } catch {
        Write-Status -Message "Failed to import module '$mod': $_" -Type "error"
        exit 1
    }
}

# === Disconnect existing Graph session ===
Write-Status -Message "Disconnected previous Microsoft Graph session." -Type "info"
try {
    if ($null -ne (Get-MgContext)) {
        Disconnect-MgGraph | Out-Null
    }
} catch {}

# === Connect to Graph ===
Write-Status -Message "Connecting to Microsoft Graph...(This can take a moment to load)" -Type "info"
try {
    Select-MgProfile -Name "v1.0"
    Connect-MgGraph -Scopes @(
        "Application.ReadWrite.All",
        "AppRoleAssignment.ReadWrite.All",
        "Directory.AccessAsUser.All",
        "Policy.Read.All"
    ) -ContextScope Process
} catch {
    Write-Status -Message "Failed to connect to Microsoft Graph: $_" -Type "error"
    Disconnect-MgGraph
    exit 1
}

# === Create the app registration ===
Write-Status -Message "Creating Azure application: $AppName..." -Type "info"
try {
    $app = New-MgApplication -DisplayName $AppName -RequiredResourceAccess @(
        @{
            ResourceAppId = "00000003-0000-0000-c000-000000000000"
            ResourceAccess = @(
                @{ Id = "7ab1d382-f21e-4acd-a863-ba3e13f7da61"; Type = "Role" },   # Directory.Read.All
                @{ Id = "230c1aed-a721-4c5d-9cb4-a90514e508ef"; Type = "Role" },   # Reports.Read.All
                @{ Id = "df021288-bdef-4463-88db-98f22de89214"; Type = "Role" }    # User.Read.All
            )
        }
    )
} catch {
    Write-Status -Message "Failed to create Azure application: $_" -Type "error"
    Disconnect-MgGraph
    exit 1
}

# === Create client secret ===
Write-Status -Message "Generating client secret (valid for $SecretExpiryInMonths months)..." -Type "info"
try {
    $startDate = Get-Date
    $endDate = $startDate.AddMonths($SecretExpiryInMonths)
    $secret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{
        DisplayName = "Hudu Secret"
        StartDateTime = $startDate
        EndDateTime   = $endDate
    }
} catch {
    Write-Status -Message "Failed to create client secret: $_" -Type "error"
    Disconnect-MgGraph
    exit 1
}


if (-not $app.AppId -or -not $app.Id) {
    Write-Status -Message "Failed to retrieve Application ID: $_" -Type "error"
    Disconnect-MgGraph
    exit 1
}

# === Output Details ===
$tenantId = (Get-MgOrganization).Id
Write-Host "`n=== Application Details for Hudu ==="
Write-Host "App Name:        $($app.DisplayName)"
Write-Host "Application ID:  $($app.AppId)"
Write-Host "Tenant ID:       $tenantId"
Write-Host "Client Secret:   $($secret.SecretText)"
Write-Host "Expires:         $($secret.EndDateTime)"


Write-Status -Message "You must manually grant admin consent in the portal:"  -Type "warning"
Write-Host "   https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$($app.AppId)/isMSAApp~/false"

# === Elapsed Time ===
$elapsed = (Get-Date) - $scriptStart
Write-Status -Message "Script completed in $($elapsed.TotalSeconds.ToString("0.0")) seconds." -Type "success"

# === Disconnect from Microsoft Graph ===
try {
    Disconnect-MgGraph
    Write-Status -Message "Disconnected from Microsoft Graph." -Type "info"
} catch {
    Write-Status -Message "Failed to disconnect from Microsoft Graph: $_" -Type "error"
}
