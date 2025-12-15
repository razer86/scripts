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

.NOTES
    Author: Raymond Slater
    Version: 2.0
    License: MIT
    Last Updated: 2024-12-15
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
    [switch]$Recreate
)

#==============================================================================
# Script-level settings
#==============================================================================
Set-StrictMode -Version Latest              # Catch uninitialized variables and coding errors
$ErrorActionPreference = 'Stop'             # Treat all errors as terminating (enables try/catch)
$ProgressPreference = 'SilentlyContinue'    # Hide progress bars for faster execution

#==============================================================================
# Script variables
#==============================================================================
$script:ScriptStart = Get-Date             # Track start time for performance monitoring
$script:GraphContext = $null               # Will store Graph connection context for cleanup

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
    $missingPermissions = $requiredPermissionIds | Where-Object { $_ -notin $existingPermissionIds }
    $extraPermissions = $existingPermissionIds | Where-Object { $_ -notin $requiredPermissionIds }
    
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
        [string]$TenantId
    )
    
    $separator = '=' * 80
    
    Write-Host "`n$separator" -ForegroundColor Cyan
    Write-Host '  Application Details for Hudu' -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Cyan
    Write-Host "App Name:        $($Application.DisplayName)"
    Write-Host "Application ID:  $($Application.AppId)"
    Write-Host "Tenant ID:       $TenantId"
    Write-Host "Secret Key:      $($Secret.SecretText)" -ForegroundColor Yellow
    Write-Host "Secret Expires:  $($Secret.EndDateTime.ToString('yyyy-MM-dd HH:mm:ss'))"
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
        
        #======================================================================
        # Display configuration
        #======================================================================
        
        Show-ApplicationDetails -Application $application -Secret $secret -TenantId $tenantInfo.TenantId
        
        #======================================================================
        # Request admin consent
        #======================================================================
        
        Request-AdminConsent -ApplicationId $application.AppId -CompanyName $tenantInfo.DisplayName
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