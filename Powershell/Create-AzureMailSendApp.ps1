<#
.SYNOPSIS
    Creates an Azure App Registration for sending email via Microsoft Graph using application permissions.

.DESCRIPTION
    This script registers a new Azure AD App with Microsoft Graph Mail.Send application permissions.
    It creates an associated Service Principal and generates a client secret for use in app-only
    authentication scenarios. This app can then be used to send email using the Microsoft Graph API
    on behalf of any mailbox in the tenant (with proper permission).

    The script performs the following:
        - Connects to Microsoft Graph with required scopes
        - Validates that the user has all required Graph permissions
        - Registers a new application (default name: GraphMailSendApp)
        - Creates a Service Principal for the app
        - Adds a client secret
        - Assigns Mail.Send (application) permissions to Microsoft Graph API
        - Outputs Tenant ID, Client ID, and Client Secret for use in automation

.PARAMETER None
    This script takes no parameters.

.REQUIREMENTS
    - Microsoft.Graph PowerShell SDK must be installed
    - Executing user must have sufficient Azure AD permissions (e.g., Global Admin or App Admin)

.NOTES
    Author: Raymond Slater
    Version: 1.0
    Created: 2025-07-28
    https://github.com/razer86

.EXAMPLE
    PS> .\Create-AzureMailSendApp.ps1

    Creates a new app registration and outputs client credentials for use in automated email sending.
#>

# Check if the required module is available
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Host "Microsoft.Graph module not found. Installing..."
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# Connect to Microsoft Graph
$requiredScopes = @(
    "Application.ReadWrite.All",
    "AppRoleAssignment.ReadWrite.All",
    "Directory.ReadWrite.All"
)

try {
    Write-Host "Connecting to Microsoft Graph with required scopes..."
    Connect-MgGraph -Scopes $requiredScopes
} catch {
    Write-Error "Failed to connect to Microsoft Graph. Ensure you have the required permissions."
    return
}

# Verify required scopes were granted
$ctx = Get-MgContext
$missingScopes = $requiredScopes | Where-Object { $_ -notin $ctx.Scopes }

if ($missingScopes.Count -gt 0) {
    Write-Error "Missing required permissions: $($missingScopes -join ', ')"
    Write-Host "Please reconnect using:"
    Write-Host "Connect-MgGraph -Scopes $($requiredScopes -join ', ')"
    return
}

# Create App Registration
$appDisplayName = "GraphMailSendApp"
Write-Host "Creating App Registration '$appDisplayName'..."

try {
    $app = New-MgApplication -DisplayName $appDisplayName -SignInAudience "AzureADMyOrg"
} catch {
    Write-Error "Failed to create App Registration: $_"
    return
}

# Create Service Principal
try {
    $sp = New-MgServicePrincipal -AppId $app.AppId
} catch {
    Write-Error "Failed to create Service Principal: $_"
    return
}

# Create Client Secret
try {
    $secret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{ displayName = "GraphClientSecret" }
} catch {
    Write-Error "Failed to create Client Secret: $_"
    return
}

# Assign Microsoft Graph Mail.Send permission
try {
    $graphSp = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'"
    $mailSendRole = $graphSp.AppRoles | Where-Object {
        $_.Value -eq "Mail.Send" -and $_.AllowedMemberTypes -contains "Application"
    }

    if (-not $mailSendRole) {
        Write-Error "Could not find Mail.Send AppRole in Microsoft Graph Service Principal."
        return
    }

    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id `
        -PrincipalId $sp.Id `
        -ResourceId $graphSp.Id `
        -AppRoleId $mailSendRole.Id
} catch {
    Write-Error "Failed to assign Mail.Send role: $_"
    return
}

# Output credentials
$tenantId = $ctx.TenantId

Write-Host ""
Write-Host "App Registration Complete"
Write-Host "---------------------------------------------"
Write-Host "Tenant ID     : $tenantId"
Write-Host "Client ID     : $($app.AppId)"
Write-Host "Client Secret : $($secret.SecretText)"
Write-Host "---------------------------------------------"
Write-Host "Use these credentials with Microsoft Graph to send email via /users/{user}/sendMail endpoint."
