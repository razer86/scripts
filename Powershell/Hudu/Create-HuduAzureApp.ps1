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
    The number of months the client secret will remain valid. Default is 24 months. Valid range: 1-24 months.

.PARAMETER SkipModuleCheck
    Skip the module installation and import checks. Use only if modules are already installed.

.EXAMPLE
    .\Create-HuduAzureApp.ps1

    Creates the application with the default name and 24-month secret expiry.

.EXAMPLE
    .\Create-HuduAzureApp.ps1 -AppName "Contoso Hudu App" -SecretExpiryInMonths 12

    Creates the application named "Contoso Hudu App" with a 12-month client secret.

.EXAMPLE
    .\Create-HuduAzureApp.ps1 -WhatIf

    Shows what would happen if the script runs without actually creating resources.

.EXAMPLE
    .\Create-HuduAzureApp.ps1 -Verbose

    Runs the script with verbose output for troubleshooting.

.EXAMPLE
    .\Create-HuduAzureApp.ps1 -Remove

    Removes the existing Hudu M365 Integration application if it exists.

.EXAMPLE
    .\Create-HuduAzureApp.ps1 -Recreate

    Removes and recreates the application with fresh credentials.

.EXAMPLE
    .\Create-HuduAzureApp.ps1 -AppName "Custom Hudu App" -Recreate

    Removes and recreates a custom-named application.

.EXAMPLE
    .\Create-HuduAzureApp.ps1 -HuduCompanyName "Contoso"

    Creates the application and pushes the credentials directly into the
    'Hudu-M365 Integration' asset for Contoso in Hudu. Reads HuduApiKey and
    HuduBaseUrl from config.psd1 in the script directory.

.NOTES
    Author: Raymond Slater
    Version: 2.1
    License: MIT
    Last Updated: 2025-01-01
    Requires: PowerShell 5.1 or higher, Microsoft.Graph modules

.LINK
    https://support.hudu.com/hc/en-us/articles/11610345552407-Microsoft-Office-365

.LINK
    https://support.hudu.com/hc/en-us/articles/31877317354391-Microsoft-Intune

.LINK
    https://github.com/razer86/scripts
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [Parameter(HelpMessage = 'The display name for the Azure application')]
    [ValidateNotNullOrEmpty()]
    [string]$AppName = 'Hudu M365 Integration',
    
    [Parameter(HelpMessage = 'Number of months the client secret will remain valid (1-24)')]
    [ValidateRange(1, 24)]
    [int]$SecretExpiryInMonths = 24,

    [Parameter(HelpMessage = 'Skip module installation and import checks')]
    [switch]$SkipModuleCheck,

    [Parameter(HelpMessage = 'Remove the application if it exists and exit')]
    [switch]$Remove,

    [Parameter(HelpMessage = 'Remove and recreate the application if it exists')]
    [switch]$Recreate,

    # ── Hudu integration (optional) ────────────────────────────────────────────
    [Parameter(HelpMessage = 'Hudu company slug or numeric ID — pushes credentials to the Hudu-M365 Integration asset')]
    [string]$HuduCompanyId,

    [Parameter(HelpMessage = 'Exact Hudu company name — alternative to HuduCompanyId')]
    [string]$HuduCompanyName,

    [Parameter(HelpMessage = 'Hudu instance base URL. Falls back to config.psd1, then HuduBaseUrl env var')]
    [string]$HuduBaseUrl,

    [Parameter(HelpMessage = 'Hudu API key. Falls back to config.psd1, then HuduApiKey env var')]
    [string]$HuduApiKey
)

#==============================================================================
# Script-level settings
#==============================================================================
Set-StrictMode -Version Latest              # Catch uninitialized variables and coding errors
$ErrorActionPreference = 'Stop'             # Treat all errors as terminating (enables try/catch)
$ProgressPreference = 'SilentlyContinue'    # Hide progress bars for faster execution

#==============================================================================
# Config loading — reads config.psd1 from the script directory.
# Explicit command-line parameters always take precedence.
#==============================================================================
$_configPath = Join-Path $PSScriptRoot 'config.psd1'
if (Test-Path $_configPath) {
    try {
        $_cfg = Import-PowerShellDataFile -Path $_configPath
        if (-not $HuduApiKey  -and $_cfg.HuduApiKey)              { $HuduApiKey              = $_cfg.HuduApiKey }
        if (-not $HuduBaseUrl -and $_cfg.HuduBaseUrl)             { $HuduBaseUrl              = $_cfg.HuduBaseUrl }
        if (-not $HuduBaseUrl -and $env:HUDU_BASE_URL)            { $HuduBaseUrl              = $env:HUDU_BASE_URL }
        if (-not $HuduApiKey  -and $env:HUDU_API_KEY)             { $HuduApiKey               = $env:HUDU_API_KEY }
        if ($_cfg.HuduM365AssetLayoutId) {
            $script:HuduM365AssetLayoutId = $_cfg.HuduM365AssetLayoutId
        }
        if ($_cfg.HuduM365AssetName) {
            $script:HuduM365AssetName = $_cfg.HuduM365AssetName
        }
    }
    catch { Write-Warning "Could not load config.psd1: $_" }
}

#==============================================================================
# Script variables
#==============================================================================
$script:ScriptStart = Get-Date             # Track start time for performance monitoring
$script:GraphContext = $null               # Will store Graph connection context for cleanup

# Hudu target asset layout for M365 integration credentials
if (-not $script:HuduM365AssetLayoutId) { $script:HuduM365AssetLayoutId = 0 }   # 0 = auto-discover by name
if (-not $script:HuduM365AssetName)     { $script:HuduM365AssetName     = 'Hudu-M365 Integration' }

# Set to $true by Grant-AppAdminConsent when any permission assignment fails
$script:NeedsManualConsent = $false

# Microsoft Graph Resource App ID
$script:MsGraphResourceId = '00000003-0000-0000-c000-000000000000'

# Required Graph API permissions
$script:RequiredPermissions = @(
    @{ Id = '7ab1d382-f21e-4acd-a863-ba3e13f7da61'; Type = 'Role'; Name = 'Directory.Read.All' }
    @{ Id = '230c1aed-a721-4c5d-9cb4-a90514e508ef'; Type = 'Role'; Name = 'Reports.Read.All' }
    @{ Id = 'df021288-bdef-4463-88db-98f22de89214'; Type = 'Role'; Name = 'User.Read.All' }
    @{ Id = '7438b122-aefc-4978-80ed-43db9fcc7715'; Type = 'Role'; Name = 'Device.Read.All' }
    @{ Id = '5b567255-7703-4780-807c-7be8301ae99b'; Type = 'Role'; Name = 'Group.Read.All' }
)

# Required modules
$script:RequiredModules = @(
    'Microsoft.Graph.Authentication'
    'Microsoft.Graph.Applications'
    'Microsoft.Graph.Users'
    'Microsoft.Graph.Identity.DirectoryManagement'
)

#==============================================================================
# Functions
#==============================================================================

function Write-Status {
    <#
    .SYNOPSIS
        Writes formatted status messages to the console.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        
        [Parameter(Position = 1)]
        [ValidateSet('Info', 'Success', 'Error', 'Warning')]
        [string]$Type = 'Info'
    )
    
    $statusConfig = @{
        Info    = @{ Prefix = '[INFO]'; Color = 'Cyan' }
        Success = @{ Prefix = '[SUCCESS]'; Color = 'Green' }
        Error   = @{ Prefix = '[ERROR]'; Color = 'Red' }
        Warning = @{ Prefix = '[WARNING]'; Color = 'Yellow' }
    }
    
    $config = $statusConfig[$Type]
    Write-Host "$($config.Prefix) $Message" -ForegroundColor $config.Color
}

function Test-PowerShellVersion {
    <#
    .SYNOPSIS
        Validates PowerShell version meets requirements.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    
    $requiredVersion = [Version]'5.1'
    $recommendedVersion = [Version]'7.0'
    $currentVersion = $PSVersionTable.PSVersion
    
    Write-Verbose "Current PowerShell version: $currentVersion"
    
    if ($currentVersion -lt $requiredVersion) {
        Write-Error "This script requires PowerShell $requiredVersion or higher. Current: $currentVersion"
        return $false
    }
    
    if ($currentVersion -lt $recommendedVersion) {
        Write-Warning "PowerShell $recommendedVersion or higher is recommended for best performance. Current: $currentVersion"
    }
    
    return $true
}

function Install-RequiredModule {
    <#
    .SYNOPSIS
        Installs a PowerShell module if not already present.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$ModuleName
    )
    
    # Check if module is already installed
    if (Get-Module -ListAvailable -Name $ModuleName) {
        Write-Verbose "Module '$ModuleName' is already installed"
        return $true
    }
    
    if ($PSCmdlet.ShouldProcess($ModuleName, 'Install module')) {
        try {
            Write-Status "Installing module: $ModuleName" -Type Info
            Install-Module -Name $ModuleName -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
            Write-Verbose "Successfully installed module: $ModuleName"
            return $true
        }
        catch {
            Write-Error "Failed to install module '$ModuleName': $($_.Exception.Message)"
            return $false
        }
    }
    
    return $false
}

function Import-RequiredModule {
    <#
    .SYNOPSIS
        Imports a PowerShell module with error handling.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ModuleName
    )
    
    try {
        Write-Verbose "Importing module: $ModuleName"
        Import-Module -Name $ModuleName -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-Error "Failed to import module '$ModuleName': $($_.Exception.Message)"
        return $false
    }
}

function Initialize-GraphModules {
    <#
    .SYNOPSIS
        Ensures all required Microsoft Graph modules are installed and imported.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    
    Write-Status 'Checking for required Microsoft Graph modules' -Type Info
    
    # Install all required modules
    foreach ($moduleName in $script:RequiredModules) {
        if (-not (Install-RequiredModule -ModuleName $moduleName)) {
            throw "Failed to install required module: $moduleName"
        }
    }
    
    # Import Authentication module first (required for other Graph modules to work)
    if (-not (Import-RequiredModule -ModuleName 'Microsoft.Graph.Authentication')) {
        throw 'Failed to import Microsoft.Graph.Authentication module'
    }
    
    # Import remaining modules
    $remainingModules = $script:RequiredModules | Where-Object { $_ -ne 'Microsoft.Graph.Authentication' }
    foreach ($moduleName in $remainingModules) {
        if (-not (Import-RequiredModule -ModuleName $moduleName)) {
            throw "Failed to import required module: $moduleName"
        }
    }
    
    Write-Verbose 'All required modules installed and imported successfully'
}

function Connect-MicrosoftGraphWithRetry {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph with the required scopes.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    
    # Disconnect any existing session to start fresh
    $existingContext = Get-MgContext
    if ($null -ne $existingContext) {
        Write-Verbose 'Disconnecting existing Microsoft Graph session'
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    
    # Define scopes needed for app registration and permission management
    $requiredScopes = @(
        'Application.ReadWrite.All'
        'AppRoleAssignment.ReadWrite.All'
        'Directory.AccessAsUser.All'
        'Policy.Read.All'
    )
    
    Write-Status 'Connecting to Microsoft Graph... (This may take a moment)' -Type Info
    Write-Verbose "Required scopes: $($requiredScopes -join ', ')"
    
    try {
        Connect-MgGraph -Scopes $requiredScopes -ContextScope Process -NoWelcome -ErrorAction Stop
        
        # Verify connection was established
        $script:GraphContext = Get-MgContext
        if ($null -eq $script:GraphContext) {
            throw 'Failed to establish Graph context'
        }
        
        Write-Verbose "Connected to tenant: $($script:GraphContext.TenantId)"
        return $true
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
        return $false
    }
}

function Get-TenantInformation {
    <#
    .SYNOPSIS
        Retrieves tenant organization information.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    
    Write-Verbose 'Retrieving tenant information'
    
    try {
        $organization = Get-MgOrganization -ErrorAction Stop | Select-Object -First 1
        
        if ($null -eq $organization) {
            throw 'No organization found in tenant'
        }
        
        $tenantInfo = @{
            TenantId    = $organization.Id
            DisplayName = if ($organization.DisplayName) { $organization.DisplayName } else { 'your organization' }
        }
        
        Write-Verbose "Tenant: $($tenantInfo.DisplayName) ($($tenantInfo.TenantId))"
        return $tenantInfo
    }
    catch {
        throw "Failed to retrieve tenant information: $($_.Exception.Message)"
    }
}

function Find-ExistingApplication {
    <#
    .SYNOPSIS
        Checks if an application with the specified name already exists.
    #>
    [CmdletBinding()]
    [OutputType([Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication])]
    param (
        [Parameter(Mandatory)]
        [string]$DisplayName
    )
    
    Write-Verbose "Searching for existing application: $DisplayName"
    
    try {
        $existingApps = @(Get-MgApplication -Filter "displayName eq '$DisplayName'" -ErrorAction Stop)
        
        if ($existingApps.Count -gt 0) {
            Write-Verbose "Found $($existingApps.Count) application(s) with name: $DisplayName"
            return $existingApps[0]
        }
        
        Write-Verbose "No existing application found with name: $DisplayName"
        return $null
    }
    catch {
        Write-Warning "Error searching for existing application: $($_.Exception.Message)"
        return $null
    }
}

function Compare-ApplicationPermissions {
    <#
    .SYNOPSIS
        Compares existing app permissions with required permissions.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication]$Application
    )
    
    Write-Verbose "Comparing application permissions"
    
    # Find Microsoft Graph resource access in the app's permissions
    $existingGraphAccess = $Application.RequiredResourceAccess | Where-Object { $_.ResourceAppId -eq $script:MsGraphResourceId }
    
    if ($null -eq $existingGraphAccess) {
        Write-Verbose "No Microsoft Graph permissions found on existing app"
        return $false
    }
    
    # Extract permission IDs for comparison
    $existingPermissionIds = $existingGraphAccess.ResourceAccess | ForEach-Object { $_.Id }
    $requiredPermissionIds = $script:RequiredPermissions | ForEach-Object { $_.Id }
    
    # Check for missing and extra permissions
    $missingPermissions = @($requiredPermissionIds | Where-Object { $_ -notin $existingPermissionIds })
    $extraPermissions = @($existingPermissionIds | Where-Object { $_ -notin $requiredPermissionIds })
    
    if ($missingPermissions.Count -gt 0) {
        Write-Verbose "Missing permissions: $($missingPermissions.Count)"
        return $false
    }
    
    if ($extraPermissions.Count -gt 0) {
        Write-Verbose "Extra permissions found: $($extraPermissions.Count)"
    }
    
    Write-Verbose "All required permissions are present"
    return $true
}

function Update-ExistingApplication {
    <#
    .SYNOPSIS
        Updates an existing application with required permissions.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication])]
    param (
        [Parameter(Mandatory)]
        [Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication]$Application
    )
    
    if (-not $PSCmdlet.ShouldProcess($Application.DisplayName, 'Update application permissions')) {
        return $Application
    }
    
    Write-Status "Updating application permissions: $($Application.DisplayName)" -Type Info
    
    try {
        $updateParams = @{
            ApplicationId = $Application.Id
            RequiredResourceAccess = @(
                @{
                    ResourceAppId  = $script:MsGraphResourceId
                    ResourceAccess = $script:RequiredPermissions | ForEach-Object {
                        @{ Id = $_.Id; Type = $_.Type }
                    }
                }
            )
        }
        
        $updatedApp = Update-MgApplication @updateParams -ErrorAction Stop
        
        Write-Status 'Application permissions updated successfully' -Type Success
        return $updatedApp
    }
    catch {
        throw "Failed to update application permissions: $($_.Exception.Message)"
    }
}

function Remove-ExistingApplication {
    <#
    .SYNOPSIS
        Removes an existing application registration.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication]$Application
    )
    
    if (-not $PSCmdlet.ShouldProcess($Application.DisplayName, 'Remove Azure application')) {
        return $false
    }
    
    Write-Status "Removing application: $($Application.DisplayName)" -Type Info
    
    try {
        Remove-MgApplication -ApplicationId $Application.Id -ErrorAction Stop
        Write-Status 'Application removed successfully' -Type Success
        return $true
    }
    catch {
        throw "Failed to remove application: $($_.Exception.Message)"
    }
}

function Invoke-ApplicationChoice {
    <#
    .SYNOPSIS
        Handles logic for existing application based on parameters.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        [Parameter(Mandatory)]
        [Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication]$ExistingApp,
        
        [Parameter(Mandatory)]
        [bool]$HasCorrectPermissions,

        [Parameter()]
        [bool]$RemoveOnly = $false,

        [Parameter()]
        [bool]$RecreateApp = $false
    )
    
    Write-Host ""
    Write-Status "Application '$($ExistingApp.DisplayName)' already exists" -Type Info
    Write-Host "Application ID: $($ExistingApp.AppId)"
    Write-Host "Object ID: $($ExistingApp.Id)"
    Write-Host "Created: $($ExistingApp.CreatedDateTime)"
    
    if ($HasCorrectPermissions) {
        Write-Host "Permissions: " -NoNewline
        Write-Host "All required permissions are present" -ForegroundColor Green
    } else {
        Write-Host "Permissions: " -NoNewline
        Write-Host "Missing some required permissions" -ForegroundColor Yellow
    }
    Write-Host ""

    # Handle -Remove parameter
    if ($RemoveOnly) {
        Write-Status "Remove parameter specified - will remove application" -Type Warning
        return @{
            Action = 'Remove'
            UpdatePermissions = $false
        }
    }

    # Handle -Recreate parameter
    if ($RecreateApp) {
        Write-Status "Recreate parameter specified - will remove and recreate application" -Type Warning
        return @{
            Action = 'Recreate'
            UpdatePermissions = $false
        }
    }

    # Default behavior: use existing and update permissions if needed
    if ($HasCorrectPermissions) {
        Write-Status "Using existing application (will generate new secret)" -Type Info
        return @{
            Action = 'Use'
            UpdatePermissions = $false
        }
    } else {
        Write-Status "Updating permissions on existing application" -Type Info
        return @{
            Action = 'Use'
            UpdatePermissions = $true
        }
    }
}

function New-HuduAzureApplication {
    <#
    .SYNOPSIS
        Creates the Azure AD application registration for Hudu.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication])]
    param (
        [Parameter(Mandatory)]
        [string]$DisplayName
    )
    
    if (-not $PSCmdlet.ShouldProcess($DisplayName, 'Create Azure application')) {
        return $null
    }
    
    Write-Status "Creating Azure application: $DisplayName" -Type Info
    
    try {
        $appParams = @{
            DisplayName           = $DisplayName
            RequiredResourceAccess = @(
                @{
                    ResourceAppId  = $script:MsGraphResourceId
                    ResourceAccess = $script:RequiredPermissions | ForEach-Object {
                        @{ Id = $_.Id; Type = $_.Type }
                    }
                }
            )
        }
        
        $application = New-MgApplication @appParams -ErrorAction Stop
        
        # Verify critical properties
        if ([string]::IsNullOrEmpty($application.AppId) -or [string]::IsNullOrEmpty($application.Id)) {
            throw 'Application was created but critical properties are missing'
        }
        
        Write-Status 'Application created successfully' -Type Success
        Write-Verbose "Application ID: $($application.AppId)"
        Write-Verbose "Object ID: $($application.Id)"
        
        return $application
    }
    catch {
        throw "Failed to create Azure application: $($_.Exception.Message)"
    }
}

function New-ApplicationSecret {
    <#
    .SYNOPSIS
        Generates a client secret for the application.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([Microsoft.Graph.PowerShell.Models.MicrosoftGraphPasswordCredential])]
    param (
        [Parameter(Mandatory)]
        [string]$ApplicationId,
        
        [Parameter(Mandatory)]
        [int]$ExpiryInMonths
    )
    
    if (-not $PSCmdlet.ShouldProcess($ApplicationId, "Generate client secret (expires in $ExpiryInMonths months)")) {
        return $null
    }
    
    Write-Status "Generating client secret (valid for $ExpiryInMonths months)" -Type Info
    
    try {
        $startDate = Get-Date
        $endDate = $startDate.AddMonths($ExpiryInMonths)
        
        $secretParams = @{
            ApplicationId      = $ApplicationId
            PasswordCredential = @{
                DisplayName   = 'Hudu Secret'
                StartDateTime = $startDate
                EndDateTime   = $endDate
            }
        }
        
        $secret = Add-MgApplicationPassword @secretParams -ErrorAction Stop
        
        # Verify secret was created with valid text
        if ([string]::IsNullOrEmpty($secret.SecretText)) {
            throw 'Secret was created but SecretText is empty'
        }
        
        Write-Status 'Client secret generated successfully' -Type Success
        Write-Verbose "Secret expires: $($secret.EndDateTime)"
        
        return $secret
    }
    catch {
        throw "Failed to create client secret: $($_.Exception.Message)"
    }
}

function Show-ApplicationDetails {
    <#
    .SYNOPSIS
        Displays the application configuration details.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [Microsoft.Graph.PowerShell.Models.MicrosoftGraphApplication]$Application,

        [Parameter(Mandatory)]
        [Microsoft.Graph.PowerShell.Models.MicrosoftGraphPasswordCredential]$Secret,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter()]
        [string]$CompanyName
    )

    $separator = '=' * 80
    $displayName = if ($CompanyName) { "Hudu-M365 Integration - $CompanyName" } else { $Application.DisplayName }

    Write-Host "`n$separator" -ForegroundColor Cyan
    Write-Host '  Application Details for Hudu' -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Cyan
    Write-Host "Name:            $displayName"
    Write-Host "Application ID:  $($Application.AppId)"
    Write-Host "Tenant ID:       $TenantId"
    Write-Host "Secret Key:      $($Secret.SecretText)" -ForegroundColor Yellow
    Write-Host "Secret Expiry:   $($Secret.EndDateTime.ToString('dd/MM/yyyy')) (dd/MM/yyyy)"
    Write-Host "$separator`n" -ForegroundColor Cyan
}

function Request-AdminConsent {
    <#
    .SYNOPSIS
        Opens browser for admin consent and provides instructions.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ApplicationId,
        
        [Parameter(Mandatory)]
        [string]$CompanyName
    )
    
    # Direct link to API permissions page where admin consent button is located
    $portalUrl = "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$ApplicationId/isMSAApp~/false"
    
    Write-Status 'IMPORTANT: You must manually grant admin consent for this application' -Type Warning
    Write-Host ''
    Write-Host "   Waiting for Azure AD to finish replicating the application..." -ForegroundColor Yellow
    Write-Host "   This usually takes 5-10 seconds." -ForegroundColor Yellow
    Write-Host ''
    
    # Wait for Azure AD replication to complete before opening browser
    # This prevents the "application not found" error when the page loads
    Start-Sleep -Seconds 10
    
    Write-Host "   Opening Azure portal to API permissions page..." -ForegroundColor Yellow
    Write-Host "   In the Azure portal, click: 'Grant admin consent for $CompanyName'." -ForegroundColor Yellow
    Write-Host ''
    Write-Host "   If the browser doesn't open automatically, use this URL:" -ForegroundColor Cyan
    Write-Host "   $portalUrl" -ForegroundColor Cyan
    Write-Host ''
    
    try {
        Start-Process $portalUrl -ErrorAction Stop
        Write-Verbose 'Browser window opened successfully'
    }
    catch {
        Write-Warning "Unable to open browser automatically: $($_.Exception.Message)"
    }
}

function Disconnect-MicrosoftGraphSafely {
    <#
    .SYNOPSIS
        Safely disconnects from Microsoft Graph with error handling.
    #>
    [CmdletBinding()]
    param()
    
    if ($null -ne (Get-MgContext)) {
        try {
            Disconnect-MgGraph -ErrorAction Stop | Out-Null
            Write-Verbose 'Disconnected from Microsoft Graph'
        }
        catch {
            Write-Verbose "Disconnect warning: $($_.Exception.Message)"
        }
    }
}

function Resolve-ServicePrincipal {
    <#
    .SYNOPSIS
        Returns the service principal for an app, creating it if absent.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param (
        [Parameter(Mandatory)]
        [string]$AppId
    )

    $sp = Get-MgServicePrincipal -Filter "appId eq '$AppId'" -ErrorAction SilentlyContinue
    if (-not $sp) {
        Write-Status 'Creating service principal for app...' -Type Info
        $sp = New-MgServicePrincipal -AppId $AppId -ErrorAction Stop
    }
    return $sp
}

function Grant-AppAdminConsent {
    <#
    .SYNOPSIS
        Programmatically grants admin consent for all required Graph permissions.
        Sets $script:NeedsManualConsent if any assignment fails.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$ApplicationAppId
    )

    Write-Status 'Granting admin consent for required permissions...' -Type Info

    # Resolve (or create) the service principal for our app registration
    $ourSp = Resolve-ServicePrincipal -AppId $ApplicationAppId

    # Resolve the Microsoft Graph service principal to get ResourceId
    $graphSp = Get-MgServicePrincipal -Filter "appId eq '$script:MsGraphResourceId'" -ErrorAction Stop
    if (-not $graphSp) { throw 'Microsoft Graph service principal not found in tenant.' }

    # Fetch already-granted assignments so we can skip them
    $grantedIds = @(
        Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ourSp.Id -All -ErrorAction SilentlyContinue |
            ForEach-Object { $_.AppRoleId }
    )

    foreach ($perm in $script:RequiredPermissions) {
        if ($perm.Id -in $grantedIds) {
            Write-Verbose "Permission '$($perm.Name)' already granted — skipping."
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($perm.Name, 'Grant admin consent')) { continue }

        try {
            New-MgServicePrincipalAppRoleAssignment `
                -ServicePrincipalId $ourSp.Id `
                -PrincipalId        $ourSp.Id `
                -ResourceId         $graphSp.Id `
                -AppRoleId          $perm.Id `
                -ErrorAction Stop | Out-Null

            Write-Status "Granted: $($perm.Name)" -Type Success
        }
        catch {
            $script:NeedsManualConsent = $true
            Write-Status ("Automatic consent failed for '$($perm.Name)': $($_.Exception.Message)") -Type Warning
        }
    }
}

function Get-ElapsedTime {
    <#
    .SYNOPSIS
        Calculates and returns elapsed time since script start.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $elapsed = (Get-Date) - $script:ScriptStart
    return $elapsed.TotalSeconds.ToString('0.0')
}

function Push-HuduM365Asset {
    <#
    .SYNOPSIS
        Creates or updates the 'Hudu-M365 Integration' asset for a company in Hudu.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'SecretKey',
        Justification = 'Plain text required — value is written to Hudu password field via REST API.')]
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)] [string]   $ApplicationId,
        [Parameter(Mandatory)] [string]   $TenantId,
        [Parameter(Mandatory)] [string]   $SecretKey,
        [Parameter(Mandatory)] [datetime] $SecretExpiry,

        # ── Hudu integration (all optional) ───────────────────────────────────
        [Parameter()] [string] $AzureCompanyName = '',
        [Parameter()] [string] $HuduCompanyId    = '',
        [Parameter()] [string] $HuduCompanyName  = '',
        [Parameter()] [string] $HuduBaseUrl      = '',
        [Parameter()] [string] $HuduApiKey       = ''
    )

    $huduUrl = $HuduBaseUrl.TrimEnd('/')
    $huduKey = $HuduApiKey

    if (-not $huduUrl -or -not $huduKey) {
        Write-Status 'Hudu credentials not configured — skipping Hudu push.' -Type Warning
        Write-Host '  Add HuduBaseUrl and HuduApiKey to config.psd1 in the script directory,' -ForegroundColor DarkGray
        Write-Host '  or pass -HuduApiKey and -HuduBaseUrl on the command line.' -ForegroundColor DarkGray
        return
    }

    $headers = @{ 'x-api-key' = $huduKey; 'Content-Type' = 'application/json' }

    # ── Resolve asset layout ID ───────────────────────────────────────────────
    $layoutId = $script:HuduM365AssetLayoutId
    if ($layoutId -eq 0) {
        try {
            $layoutName = 'Hudu-M365 Integration'
            $encoded    = [uri]::EscapeDataString($layoutName)
            $layouts    = @((Invoke-RestMethod -Uri "$huduUrl/api/v1/asset_layouts?search=$encoded&page_size=25" `
                            -Headers $headers -Method Get).asset_layouts)
            $layout     = $layouts | Where-Object { $_.name -eq $layoutName } | Select-Object -First 1

            if (-not $layout) {
                Write-Status "No asset layout named '$layoutName' found in Hudu — skipping Hudu push." -Type Warning
                Write-Host "  Create the layout first or set HuduM365AssetLayoutId in config.psd1." -ForegroundColor DarkGray
                return
            }
            $layoutId = $layout.id
            Write-Verbose "Resolved asset layout '$layoutName' to id $layoutId"
        }
        catch {
            Write-Status "Could not query Hudu asset layouts: $_ — skipping Hudu push." -Type Warning
            return
        }
    }

    # ── Resolve company ───────────────────────────────────────────────────────
    $company = $null

    if ($HuduCompanyId) {
        try {
            if ($HuduCompanyId -match '^\d+$') {
                $company = (Invoke-RestMethod -Uri "$huduUrl/api/v1/companies/$HuduCompanyId" `
                            -Headers $headers -Method Get).company
            }
            else {
                $encoded = [uri]::EscapeDataString($HuduCompanyId)
                $company = @((Invoke-RestMethod -Uri "$huduUrl/api/v1/companies?slug=$encoded&page_size=1" `
                              -Headers $headers -Method Get).companies) | Select-Object -First 1
            }
        }
        catch { Write-Status "Hudu company lookup failed for '$HuduCompanyId': $_" -Type Warning; return }
    }
    elseif ($HuduCompanyName) {
        try {
            $encoded = [uri]::EscapeDataString($HuduCompanyName)
            $company = @((Invoke-RestMethod -Uri "$huduUrl/api/v1/companies?search=$encoded&page_size=25" `
                          -Headers $headers -Method Get).companies) |
                        Where-Object { $_.name -eq $HuduCompanyName } | Select-Object -First 1
        }
        catch { Write-Status "Hudu company lookup failed for '$HuduCompanyName': $_" -Type Warning; return }
    }
    else {
        # Interactive prompt
        Write-Host ''
        Write-Host '  Paste the Hudu company URL, slug, or numeric ID' -ForegroundColor DarkCyan
        Write-Host '  (or press Enter to skip Hudu push):' -ForegroundColor DarkCyan
        $companyInput = (Read-Host '  Company URL / slug / ID').Trim()

        if (-not $companyInput) {
            Write-Status 'Hudu push skipped.' -Type Info
            return
        }

        $companyId = if ($companyInput -match '://') {
            try { ([System.Uri]$companyInput).Segments[-1].TrimEnd('/') }
            catch { Write-Status "Could not parse URL '$companyInput': $_" -Type Warning; return }
        } else { $companyInput }

        try {
            if ($companyId -match '^\d+$') {
                $company = (Invoke-RestMethod -Uri "$huduUrl/api/v1/companies/$companyId" `
                            -Headers $headers -Method Get).company
            }
            else {
                $encoded = [uri]::EscapeDataString($companyId)
                $company = @((Invoke-RestMethod -Uri "$huduUrl/api/v1/companies?slug=$encoded&page_size=1" `
                              -Headers $headers -Method Get).companies) | Select-Object -First 1
            }
        }
        catch { Write-Status "Hudu company lookup failed: $_" -Type Warning; return }
    }

    if (-not $company) {
        Write-Status 'No matching Hudu company found — skipping Hudu push.' -Type Warning
        return
    }

    $companyId   = $company.id
    $companyName = $company.name
    Write-Host "  Company: $companyName (id: $companyId)" -ForegroundColor Green

    # ── Build payload ─────────────────────────────────────────────────────────
    $assetName = "Hudu-M365 Integration - $(if ($AzureCompanyName) { $AzureCompanyName } else { $companyName })"

    $body = @{
        name            = $assetName
        asset_layout_id = $layoutId
        custom_fields   = @(
            @{ application_id = $ApplicationId }
            @{ tenant_id      = $TenantId }
            @{ secret_key     = $SecretKey }
            @{ secret_expiry  = $SecretExpiry.ToString('yyyy/MM/dd') }
        )
    } | ConvertTo-Json -Depth 5

    # ── Find existing asset ───────────────────────────────────────────────────
    try {
        $existingAsset = @((Invoke-RestMethod `
            -Uri     "$huduUrl/api/v1/assets?company_id=$companyId&asset_layout_id=$layoutId&page_size=5" `
            -Headers $headers -Method Get).assets) | Select-Object -First 1
    }
    catch {
        Write-Warning "Could not query Hudu assets: $_"
        $existingAsset = $null
    }

    # ── Push ──────────────────────────────────────────────────────────────────
    $whatIfTarget = if ($existingAsset) { "Update Hudu asset '$($existingAsset.name)' (id: $($existingAsset.id))" }
                   else                 { "Create Hudu asset '$assetName' for company '$companyName'" }

    if (-not $PSCmdlet.ShouldProcess($whatIfTarget, 'Push to Hudu')) { return }

    try {
        if ($existingAsset) {
            Invoke-RestMethod -Uri "$huduUrl/api/v1/assets/$($existingAsset.id)" `
                -Headers $headers -Method Put -Body $body | Out-Null
            Write-Status "Hudu asset updated: $($existingAsset.name) (id: $($existingAsset.id))" -Type Success
        }
        else {
            $created = Invoke-RestMethod -Uri "$huduUrl/api/v1/companies/$companyId/assets" `
                -Headers $headers -Method Post -Body $body
            Write-Status "Hudu asset created: $($created.asset.name) (id: $($created.asset.id))" -Type Success
        }
    }
    catch {
        Write-Status "Hudu asset push failed — save the details above manually: $_" -Type Warning
    }
}

#==============================================================================
# Main script execution
#==============================================================================

try {
    #==========================================================================
    # Pre-flight checks
    #==========================================================================
    
    if (-not (Test-PowerShellVersion)) {
        exit 1
    }
    
    #==========================================================================
    # Module setup
    #==========================================================================
    
    if (-not $SkipModuleCheck) {
        Initialize-GraphModules
    }
    else {
        Write-Verbose 'Skipping module checks (SkipModuleCheck specified)'
    }
    
    #==========================================================================
    # Connect to Microsoft Graph
    #==========================================================================
    
    if (-not (Connect-MicrosoftGraphWithRetry)) {
        throw 'Failed to connect to Microsoft Graph'
    }
    
    #==========================================================================
    # Get tenant information
    #==========================================================================
    
    $tenantInfo = Get-TenantInformation
    
    #==========================================================================
    # Check for existing application
    #==========================================================================
    
    $existingApp = Find-ExistingApplication -DisplayName $AppName
    $application = $null
    
    if ($null -ne $existingApp) {
        $hasCorrectPermissions = Compare-ApplicationPermissions -Application $existingApp
        
        # Determine action based on parameters
        $choice = Invoke-ApplicationChoice `
            -ExistingApp $existingApp `
            -HasCorrectPermissions $hasCorrectPermissions `
            -RemoveOnly $Remove `
            -RecreateApp $Recreate
        
        switch ($choice.Action) {
            'Remove' {
                if ($PSCmdlet.ShouldProcess($AppName, 'Remove Azure application')) {
                    $removed = Remove-ExistingApplication -Application $existingApp
                    if ($removed) {
                        Write-Status "Application removed successfully" -Type Success
                    }
                }
                # Exit after remove operation
                $elapsedTime = Get-ElapsedTime
                Write-Status "Script completed in $elapsedTime seconds" -Type Success
                exit 0
            }
            'Recreate' {
                if ($PSCmdlet.ShouldProcess($AppName, 'Remove and recreate Azure application')) {
                    $removed = Remove-ExistingApplication -Application $existingApp
                    if ($removed) {
                        Write-Status "Creating new application..." -Type Info
                        Start-Sleep -Seconds 3  # Allow Azure AD replication time
                        $application = New-HuduAzureApplication -DisplayName $AppName
                    }
                } else {
                    # WhatIf mode
                    Write-Host "`n[WHATIF] Would remove existing application: $AppName"
                    Write-Host "[WHATIF] Would create new application: $AppName"
                    Write-Host "[WHATIF] Would generate client secret valid for $SecretExpiryInMonths months"
                    Write-Host "[WHATIF] Would request admin consent"
                }
            }
            'Use' {
                if ($choice.UpdatePermissions) {
                    if ($PSCmdlet.ShouldProcess($AppName, 'Update application permissions')) {
                        $application = Update-ExistingApplication -Application $existingApp
                        Write-Status "IMPORTANT: You must re-grant admin consent after updating permissions" -Type Warning
                    } else {
                        # WhatIf mode
                        Write-Host "`n[WHATIF] Would update permissions on existing application: $AppName"
                        Write-Host "[WHATIF] Would generate client secret valid for $SecretExpiryInMonths months"
                    }
                } else {
                    $application = $existingApp
                }
            }
        }
    } else {
        # No existing app found - create new one unless just trying to remove
        if ($Remove) {
            Write-Status "No application named '$AppName' found to remove" -Type Warning
            $elapsedTime = Get-ElapsedTime
            Write-Status "Script completed in $elapsedTime seconds" -Type Success
            exit 0
        }
        
        $application = New-HuduAzureApplication -DisplayName $AppName
    }
    
    # Handle WhatIf mode when no existing app or when using existing app
    if ($null -eq $application -and $WhatIfPreference) {
        if ($null -eq $existingApp) {
            Write-Host "`n[WHATIF] Would create application: $AppName"
            Write-Host "[WHATIF] Would generate client secret valid for $SecretExpiryInMonths months"
            Write-Host "[WHATIF] Would request admin consent"
        } elseif ($null -ne $existingApp) {
            Write-Host "`n[WHATIF] Would use existing application: $AppName"
            Write-Host "[WHATIF] Would generate client secret valid for $SecretExpiryInMonths months"
        }
    }
    elseif ($null -ne $application) {
        #======================================================================
        # Create client secret
        #======================================================================
        
        $secret = New-ApplicationSecret -ApplicationId $application.Id -ExpiryInMonths $SecretExpiryInMonths

        if ($null -eq $secret) {
            # WhatIf mode — secret was not actually created
            Write-Host "`n[WHATIF] Would display application details and credentials"
            if ($HuduCompanyId -or $HuduCompanyName) {
                Write-Host "[WHATIF] Would push credentials to Hudu"
            }
            Write-Host "[WHATIF] Would grant admin consent"
        }
        else {
            #======================================================================
            # Display configuration
            #======================================================================

            Show-ApplicationDetails -Application $application -Secret $secret -TenantId $tenantInfo.TenantId `
                -CompanyName $tenantInfo.DisplayName

            #======================================================================
            # Push credentials to Hudu (if configured)
            #======================================================================

            if ($HuduCompanyId -or $HuduCompanyName) {
                Write-Status 'Pushing credentials to Hudu...' -Type Info
                Push-HuduM365Asset `
                    -ApplicationId    $application.AppId `
                    -TenantId         $tenantInfo.TenantId `
                    -SecretKey        $secret.SecretText `
                    -SecretExpiry     $secret.EndDateTime `
                    -AzureCompanyName $tenantInfo.DisplayName `
                    -HuduCompanyId    $HuduCompanyId `
                    -HuduCompanyName  $HuduCompanyName `
                    -HuduBaseUrl      $HuduBaseUrl `
                    -HuduApiKey       $HuduApiKey
            }

            #======================================================================
            # Grant admin consent
            #======================================================================

            Grant-AppAdminConsent -ApplicationAppId $application.AppId

            if ($script:NeedsManualConsent) {
                Write-Status 'One or more permissions could not be granted automatically — manual consent required.' -Type Warning
                Request-AdminConsent -ApplicationId $application.AppId -CompanyName $tenantInfo.DisplayName
            } else {
                Write-Status 'Admin consent granted successfully — no portal action required.' -Type Success
            }
        }
    }
    
    #==========================================================================
    # Success
    #==========================================================================
    
    $elapsedTime = Get-ElapsedTime
    Write-Status "Script completed successfully in $elapsedTime seconds" -Type Success
}
catch {
    #==========================================================================
    # Error handling
    #==========================================================================
    
    Write-Status "Script failed: $($_.Exception.Message)" -Type Error
    
    if ($PSCmdlet.MyInvocation.BoundParameters['Verbose']) {
        Write-Host "`nFull error details:" -ForegroundColor Red
        Write-Host $_.Exception.ToString() -ForegroundColor Red
        Write-Host "`nStack trace:" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
    
    exit 1
}
finally {
    #==========================================================================
    # Cleanup
    #==========================================================================
    
    Disconnect-MicrosoftGraphSafely
}