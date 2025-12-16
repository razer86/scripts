<#
.SYNOPSIS
    Enable in-place archive for mailboxes with less than 25% free space and report licensing.

.DESCRIPTION
    Connects to Exchange Online and Microsoft Graph to:
    - Scan all user mailboxes for size, quota, and archive status
    - Retrieve assigned licenses for each user
    - Enable archives automatically when free space is less than 25%
    - Generate comprehensive CSV report with all findings

.PARAMETER ReportOnly
    Generate the license/usage report without enabling any archives.

.PARAMETER LogPath
    Specify folder path where the CSV report should be saved.
    Default: Documents folder
    Filename format: Mailbox_Report_<CompanyName>_yyyyMMdd.csv
    Company name is automatically retrieved from the tenant.

.NOTES
    Requirements:
    - PowerShell 5.1 or later
    - ExchangeOnlineManagement module
    - Microsoft.Graph.Users module
    - Appropriate admin permissions
    
    Permissions:
    - Exchange Online: Exchange Administrator or Global Administrator
    - Microsoft Graph: User.Read.All, Directory.Read.All
    
    Behavior:
    - Archives are enabled automatically without prompts (unless -WhatIf is used)
    - Use -ReportOnly for audit-only runs
    - Use -WhatIf for simulation mode

    Author: Raymond Slater
    Version: 2.1
    Date: 2025-12-16
    Link: https://github.com/razer86/scripts

.EXAMPLE
    .\Enable-ExchOnlineArchive-Enhanced.ps1
    
    Runs the script and enables archives as needed.
    Company name retrieved automatically from tenant.

.EXAMPLE
    .\Enable-ExchOnlineArchive-Enhanced.ps1 -WhatIf
    
    Runs in simulation mode without making changes.

.EXAMPLE
    .\Enable-ExchOnlineArchive-Enhanced.ps1 -ReportOnly
    
    Generates report only without enabling any archives.
    Output: Mailbox_Report_<TenantCompanyName>_20251216.csv

.EXAMPLE
    .\Enable-ExchOnlineArchive-Enhanced.ps1 -LogPath "C:\Reports"
    
    Saves the report to C:\Reports\Mailbox_Report_<TenantCompanyName>_20251216.csv

.EXAMPLE
    .\Enable-ExchOnlineArchive-Enhanced.ps1 -ReportOnly -LogPath "\\fileserver\compliance"
    
    Generates report-only mode and saves to network share.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false, HelpMessage = 'Generate report without enabling archives')]
    [switch]$ReportOnly,
    
    [Parameter(Mandatory = $false, HelpMessage = 'Folder path where CSV report should be saved')]
    [ValidateScript({
        if (-not (Test-Path -Path $_ -PathType Container)) {
            throw "The folder path '$_' does not exist. Please create it first or use a valid folder path."
        }
        $true
    })]
    [string]$LogPath
)

#region Functions

<#
.SYNOPSIS
    Convert size string to bytes for calculations.
#>
function ConvertTo-BytesFromString {
    [CmdletBinding()]
    [OutputType([long])]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$SizeString
    )

    if ([string]::IsNullOrWhiteSpace($SizeString)) {
        return 0
    }

    # Handle "Unlimited" quota
    if ($SizeString -match 'Unlimited') {
        return [long]::MaxValue
    }

    # Extract just the size portion before any parentheses
    # e.g., "4.3 GB (4,621,234 bytes)" becomes "4.3 GB"
    if ($SizeString -match '^([\d,\.]+)\s*(B|KB|MB|GB|TB)') {
        $value = $Matches[1] -replace ',', ''
        $value = [double]$value
        $unit = $Matches[2].ToUpper()

        switch ($unit) {
            'B'  { return [long]$value }
            'KB' { return [long]($value * 1KB) }
            'MB' { return [long]($value * 1MB) }
            'GB' { return [long]($value * 1GB) }
            'TB' { return [long]($value * 1TB) }
            default { return 0 }
        }
    }

    return 0
}

<#
.SYNOPSIS
    Get user license information from Microsoft Graph.
#>
function Get-UserLicenseInfo {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$UserPrincipalName,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$SkuCache
    )
    
    try {
        $user = Get-MgUser -UserId $UserPrincipalName -Property AssignedLicenses -ErrorAction Stop
        
        if ($null -eq $user.AssignedLicenses -or $user.AssignedLicenses.Count -eq 0) {
            return 'No License'
        }
        
        # Get friendly names for SKUs
        $licenseNames = [System.Collections.ArrayList]::new()
        
        foreach ($license in $user.AssignedLicenses) {
            $skuId = $license.SkuId
            
            # Check cache first
            if ($SkuCache.ContainsKey($skuId)) {
                $skuPartNumber = $SkuCache[$skuId]
            }
            else {
                # Not in cache, retrieve and cache it
                try {
                    $sku = Get-MgSubscribedSku -All | Where-Object { $_.SkuId -eq $skuId } | Select-Object -First 1
                    if ($sku) {
                        $skuPartNumber = $sku.SkuPartNumber
                        $SkuCache[$skuId] = $skuPartNumber
                    }
                    else {
                        $skuPartNumber = $skuId
                        $SkuCache[$skuId] = $skuId
                    }
                }
                catch {
                    $skuPartNumber = $skuId
                    $SkuCache[$skuId] = $skuId
                }
            }
            
            # Convert SKU to friendly name
            $friendlyName = ConvertTo-FriendlyLicenseName -SkuPartNumber $skuPartNumber
            [void]$licenseNames.Add($friendlyName)
        }
        
        return ($licenseNames -join '; ')
    }
    catch {
        Write-Warning "Error retrieving license for $UserPrincipalName : $($_.Exception.Message)"
        return 'Error retrieving license'
    }
}

<#
.SYNOPSIS
    Convert SKU part number to friendly license name.
#>
function ConvertTo-FriendlyLicenseName {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SkuPartNumber
    )
    
    # Comprehensive mapping of SKU codes to friendly names
    $skuMapping = @{
        # Microsoft 365 Enterprise
        'SPE_E3'                        = 'Microsoft 365 E3'
        'SPE_E5'                        = 'Microsoft 365 E5'
        'SPE_E3_USGOV_DOD'             = 'Microsoft 365 E3 (US Gov DoD)'
        'SPE_E3_USGOV_GCCHIGH'         = 'Microsoft 365 E3 (US Gov GCC High)'
        'SPE_E5_USGOV_DOD'             = 'Microsoft 365 E5 (US Gov DoD)'
        'SPE_E5_USGOV_GCCHIGH'         = 'Microsoft 365 E5 (US Gov GCC High)'
        
        # Microsoft 365 Frontline
        'SPE_F1'                        = 'Microsoft 365 F1'
        'SPE_F3'                        = 'Microsoft 365 F3'
        'SPE_F5'                        = 'Microsoft 365 F5'
        'Microsoft_365_F1'              = 'Microsoft 365 F1'
        'Microsoft_365_F3'              = 'Microsoft 365 F3'
        
        # Office 365 Enterprise
        'ENTERPRISEPACK'                = 'Office 365 E3'
        'ENTERPRISEPREMIUM'             = 'Office 365 E5'
        'ENTERPRISEPREMIUM_NOPSTNCONF'  = 'Office 365 E5 (No Audio Conferencing)'
        'ENTERPRISEPACK_USGOV_DOD'      = 'Office 365 E3 (US Gov DoD)'
        'ENTERPRISEPACK_USGOV_GCCHIGH'  = 'Office 365 E3 (US Gov GCC High)'
        'ENTERPRISEPREMIUM_USGOV_DOD'   = 'Office 365 E5 (US Gov DoD)'
        'ENTERPRISEPREMIUM_USGOV_GCCHIGH' = 'Office 365 E5 (US Gov GCC High)'
        
        # Office 365 Small/Medium Business
        'O365_BUSINESS'                 = 'Microsoft 365 Apps for Business'
        'O365_BUSINESS_ESSENTIALS'      = 'Office 365 Business Essentials'
        'O365_BUSINESS_PREMIUM'         = 'Microsoft 365 Business Premium'
        'SMB_BUSINESS'                  = 'Microsoft 365 Business Basic'
        'SMB_BUSINESS_PREMIUM'          = 'Microsoft 365 Business Premium'
        'BUSINESS_ESSENTIALS'           = 'Office 365 Business Essentials'
        'BUSINESS_PREMIUM'              = 'Microsoft 365 Business Premium'
        'SPB'                           = 'Microsoft 365 Business Premium'
        
        # Exchange Plans
        'EXCHANGESTANDARD'              = 'Exchange Online Plan 1'
        'EXCHANGEENTERPRISE'            = 'Exchange Online Plan 2'
        'EXCHANGEARCHIVE'               = 'Exchange Online Archiving'
        'EXCHANGEARCHIVE_ADDON'         = 'Exchange Online Archiving (Add-on)'
        'EXCHANGEDESKLESS'              = 'Exchange Online Kiosk'
        'EXCHANGE_S_STANDARD'           = 'Exchange Online Plan 1'
        'EXCHANGE_S_ENTERPRISE'         = 'Exchange Online Plan 2'
        'EXCHANGE_S_ARCHIVE'            = 'Exchange Online Archiving'
        'EXCHANGE_S_DESKLESS'           = 'Exchange Online Kiosk'
        
        # Exchange Standalone
        'EXCHANGEONLINE_MULTIGEO'       = 'Exchange Online Multi-Geo'
        'EXCHANGETELCO'                 = 'Exchange Online POP'
        
        # Microsoft 365 Apps
        'OFFICESUBSCRIPTION'            = 'Microsoft 365 Apps for Enterprise'
        'STANDARDPACK'                  = 'Office 365 E1'
        'STANDARDWOFFPACK'              = 'Office 365 E2'
        
        # Visio and Project
        'VISIOCLIENT'                   = 'Visio Online Plan 2'
        'VISIOONLINE_PLAN1'             = 'Visio Online Plan 1'
        'PROJECTCLIENT'                 = 'Project Online Plan 3'
        'PROJECTESSENTIALS'             = 'Project Online Essentials'
        'PROJECTONLINE_PLAN_1'          = 'Project Online Plan 1'
        'PROJECTONLINE_PLAN_2'          = 'Project Online Plan 2'
        'PROJECTPREMIUM'                = 'Project Online Premium'
        'PROJECTPROFESSIONAL'           = 'Project Online Professional'
        
        # Education
        'STANDARDPACK_STUDENT'          = 'Office 365 A1 (Student)'
        'STANDARDWOFFPACK_STUDENT'      = 'Office 365 A2 (Student)'
        'ENTERPRISEPACK_STUDENT'        = 'Office 365 A3 (Student)'
        'ENTERPRISEPREMIUM_STUDENT'     = 'Office 365 A5 (Student)'
        'STANDARDPACK_FACULTY'          = 'Office 365 A1 (Faculty)'
        'STANDARDWOFFPACK_FACULTY'      = 'Office 365 A2 (Faculty)'
        'ENTERPRISEPACK_FACULTY'        = 'Office 365 A3 (Faculty)'
        'ENTERPRISEPREMIUM_FACULTY'     = 'Office 365 A5 (Faculty)'
        
        # Teams and Communication
        'MCOSTANDARD'                   = 'Microsoft Teams'
        'MCOEV'                         = 'Microsoft 365 Phone System'
        'TEAMS_EXPLORATORY'             = 'Microsoft Teams Exploratory'
        'TEAMS1'                        = 'Microsoft Teams (Free)'
        'PHONESYSTEM_VIRTUALUSER'       = 'Phone System - Virtual User'
        
        # Security and Compliance
        'THREAT_INTELLIGENCE'           = 'Microsoft Defender for Office 365 Plan 2'
        'ATP_ENTERPRISE'                = 'Microsoft Defender for Office 365 Plan 1'
        'EMS'                           = 'Enterprise Mobility + Security E3'
        'EMSPREMIUM'                    = 'Enterprise Mobility + Security E5'
        'INFORMATION_PROTECTION_COMPLIANCE' = 'Microsoft 365 E5 Compliance'
        'IDENTITY_THREAT_PROTECTION'    = 'Microsoft 365 E5 Security'
        'M365_SECURITY_COMPLIANCE_FOR_FLW' = 'Microsoft 365 F5 Security & Compliance'
        
        # Power Platform
        'POWER_BI_STANDARD'             = 'Power BI (Free)'
        'POWER_BI_PRO'                  = 'Power BI Pro'
        'POWER_BI_PREMIUM'              = 'Power BI Premium'
        'POWERAPPS_PER_USER'            = 'Power Apps per User'
        'FLOW_FREE'                     = 'Power Automate (Free)'
        'FLOW_P2'                       = 'Power Automate per User'
        
        # Dynamics 365
        'DYN365_ENTERPRISE_PLAN1'       = 'Dynamics 365 Customer Engagement Plan'
        'DYN365_ENTERPRISE_SALES'       = 'Dynamics 365 Sales'
        'DYN365_ENTERPRISE_CUSTOMER_SERVICE' = 'Dynamics 365 Customer Service'
        'DYN365_FINANCIALS_BUSINESS'    = 'Dynamics 365 Business Central'
        
        # Windows and Intune
        'WIN10_PRO_ENT_SUB'             = 'Windows 10/11 Enterprise E3'
        'WIN10_VDA_E3'                  = 'Windows 10/11 Enterprise E3 VDA'
        'WIN10_VDA_E5'                  = 'Windows 10/11 Enterprise E5 VDA'
        'INTUNE_A'                      = 'Microsoft Intune'
        'INTUNE_A_D'                    = 'Microsoft Intune Device'
        
        # Azure and Developer
        'DEVELOPERPACK'                 = 'Microsoft 365 E3 Developer'
        'ENTERPRISEPACK_B_PILOT'        = 'Office 365 E3 (Preview)'
        
        # Specialized
        'RIGHTSMANAGEMENT'              = 'Azure Rights Management'
        'RIGHTSMANAGEMENT_ADHOC'        = 'Azure Rights Management (Ad-hoc)'
        'MCOMEETADV'                    = 'Microsoft 365 Audio Conferencing'
        'SHAREPOINTSTANDARD'            = 'SharePoint Online Plan 1'
        'SHAREPOINTENTERPRISE'          = 'SharePoint Online Plan 2'
        'SHAREPOINTSTORAGE'             = 'SharePoint Online Storage'
        'STREAM'                        = 'Microsoft Stream'
        'MYANALYTICS_P2'                = 'Microsoft MyAnalytics'
        
        # Nonprofit
        'ENTERPRISEPACK_NONPROFIT'      = 'Office 365 E3 (Nonprofit)'
        'ENTERPRISEPREMIUM_NONPROFIT'   = 'Office 365 E5 (Nonprofit)'
        
        # US Government
        'ENTERPRISEPACKLRG'             = 'Office 365 E3 (Large Enterprise)'
        'ENTERPRISEWITHSCAL'            = 'Office 365 E4'
        
        # Common Aliases
        'M365EDU_A3_FACULTY'            = 'Microsoft 365 A3 (Faculty)'
        'M365EDU_A3_STUDENT'            = 'Microsoft 365 A3 (Student)'
        'M365EDU_A5_FACULTY'            = 'Microsoft 365 A5 (Faculty)'
        'M365EDU_A5_STUDENT'            = 'Microsoft 365 A5 (Student)'
    }
    
    # Check if we have a friendly name mapping
    if ($skuMapping.ContainsKey($SkuPartNumber)) {
        return $skuMapping[$SkuPartNumber]
    }
    
    # If no mapping found, try to make it more readable
    $readable = $SkuPartNumber -replace '_', ' ' -replace 'ENTERPRISE', 'Enterprise' -replace 'STANDARD', 'Standard'
    
    # Return original if no mapping found (with note)
    return "$readable (SKU: $SkuPartNumber)"
}

<#
.SYNOPSIS
    Clean company name for use in filename.
#>
function Get-CleanedCompanyName {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$CompanyName
    )
    
    # Remove spaces and special characters
    $cleaned = $CompanyName -replace '\s+', '' -replace '[^\w\d]', ''
    
    return $cleaned
}

<#
.SYNOPSIS
    Write colored output with timestamp.
#>
function Write-ColorOutput {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Black', 'DarkBlue', 'DarkGreen', 'DarkCyan', 'DarkRed', 'DarkMagenta', 'DarkYellow', 'Gray', 
                     'DarkGray', 'Blue', 'Green', 'Cyan', 'Red', 'Magenta', 'Yellow', 'White')]
        [string]$ForegroundColor = 'White'
    )
    
    Write-Host $Message -ForegroundColor $ForegroundColor
}

#endregion Functions

#region Main Script

try {
    # Display header
    Write-ColorOutput -Message '========================================' -ForegroundColor Cyan
    Write-ColorOutput -Message 'Exchange Online Archive Management Tool' -ForegroundColor Cyan
    Write-ColorOutput -Message '========================================' -ForegroundColor Cyan
    Write-Host ''

    # Display mode
    if ($ReportOnly) {
        Write-ColorOutput -Message 'MODE: Report Only (No changes will be made)' -ForegroundColor Yellow
        Write-Host ''
    }
    elseif ($WhatIfPreference) {
        Write-ColorOutput -Message 'MODE: WhatIf (Simulation mode)' -ForegroundColor Yellow
        Write-Host ''
    }

    # Validate LogPath if provided
    if ($PSBoundParameters.ContainsKey('LogPath')) {
        Write-ColorOutput -Message "Reports will be saved to: $LogPath" -ForegroundColor Cyan
        Write-Host ''
    }

    #region Connect to Services
    
    # Connect to Exchange Online
    Write-ColorOutput -Message 'Connecting to Exchange Online... (Mailbox Tasks)' -ForegroundColor Yellow
    try {
        $null = Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
        Write-ColorOutput -Message '✓ Connected to Exchange Online' -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to Exchange Online: $($_.Exception.Message)"
        exit 1
    }

    # Connect to Microsoft Graph for license information
    Write-ColorOutput -Message 'Connecting to Microsoft Graph... (License assignments)' -ForegroundColor Yellow
    $graphConnected = $false
    try {
        $null = Connect-MgGraph -Scopes 'User.Read.All', 'Directory.Read.All' -NoWelcome -ErrorAction Stop
        Write-ColorOutput -Message '✓ Connected to Microsoft Graph' -ForegroundColor Green
        $graphConnected = $true
    }
    catch {
        Write-Warning "Failed to connect to Microsoft Graph: $($_.Exception.Message)"
        Write-ColorOutput -Message 'Continuing without license information...' -ForegroundColor Yellow
    }

    # Retrieve organization/company name from Exchange Online (no additional Graph permissions needed)
    $companyName = 'Unknown'
    $cleanCompanyName = 'Unknown'
    
    Write-ColorOutput -Message 'Retrieving organization information...' -ForegroundColor Yellow
    try {
        $orgConfig = Get-OrganizationConfig -ErrorAction Stop
        if ($orgConfig -and $orgConfig.DisplayName) {
            $companyName = $orgConfig.DisplayName
            $cleanCompanyName = Get-CleanedCompanyName -CompanyName $companyName
            Write-ColorOutput -Message "✓ Organization: $companyName" -ForegroundColor Green
        }
        elseif ($orgConfig -and $orgConfig.Name) {
            # Fallback to Name property if DisplayName is not available
            $companyName = $orgConfig.Name
            $cleanCompanyName = Get-CleanedCompanyName -CompanyName $companyName
            Write-ColorOutput -Message "✓ Organization: $companyName" -ForegroundColor Green
        }
        else {
            Write-Warning 'Could not retrieve organization name, using "Unknown"'
        }
    }
    catch {
        Write-Warning "Could not retrieve organization name: $($_.Exception.Message)"
        Write-ColorOutput -Message '  Using "Unknown" for filename' -ForegroundColor Yellow
    }

    Write-Host ''
    
    #endregion Connect to Services

    #region Initialize Variables
    
    # Initialize collections
    $logEntries = [System.Collections.ArrayList]::new()
    $errorEntries = [System.Collections.ArrayList]::new()
    $skuCache = @{}
    
    # Initialize counters
    $counter = 0
    $archivesEnabled = 0
    
    #endregion Initialize Variables

    #region Get Mailboxes
    
    Write-ColorOutput -Message 'Retrieving mailboxes...' -ForegroundColor Yellow
    try {
        $mailboxes = Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox -ErrorAction Stop
        Write-ColorOutput -Message "✓ Found $($mailboxes.Count) user mailboxes" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to retrieve mailboxes: $($_.Exception.Message)"
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        if ($graphConnected) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue
        }
        exit 1
    }

    Write-Host ''
    Write-ColorOutput -Message 'Processing mailboxes...' -ForegroundColor Yellow
    Write-Host ''
    
    #endregion Get Mailboxes

    #region Process Mailboxes
    
    foreach ($mailbox in $mailboxes) {
        $counter++
        $userPrincipalName = $mailbox.UserPrincipalName
        $percentComplete = [math]::Round(($counter / $mailboxes.Count) * 100, 1)
        
        Write-Progress -Activity 'Processing Mailboxes' `
                       -Status "Processing $userPrincipalName ($counter of $($mailboxes.Count))" `
                       -PercentComplete $percentComplete
        
        try {
            # Get mailbox statistics
            $stats = Get-MailboxStatistics -Identity $userPrincipalName -ErrorAction Stop
            
            # Get mailbox details
            $mailboxDetails = Get-Mailbox -Identity $userPrincipalName -ErrorAction Stop
            
            # Extract primary mailbox info
            $quotaString = $mailboxDetails.ProhibitSendQuota.ToString()
            $usedString = $stats.TotalItemSize.ToString()
            
            # Convert to bytes
            $quotaBytes = ConvertTo-BytesFromString -SizeString $quotaString
            $usedBytes = ConvertTo-BytesFromString -SizeString $usedString
            
            # Get license information
            $licenseInfo = 'N/A'
            if ($graphConnected) {
                $licenseInfo = Get-UserLicenseInfo -UserPrincipalName $userPrincipalName -SkuCache $skuCache
            }
            
            # Calculate free percentage
            $freePercent = 0
            if ($quotaBytes -gt 0 -and $quotaBytes -ne [long]::MaxValue) {
                $freePercent = (($quotaBytes - $usedBytes) / $quotaBytes) * 100
            }
            elseif ($quotaBytes -eq [long]::MaxValue) {
                $freePercent = 100  # Unlimited quota = 100% free
            }
            
            # Check archive status
            $hasArchive = $mailboxDetails.ArchiveStatus -eq 'Active'
            
            # Get archive stats if archive exists
            $archiveUsedString = 'N/A'
            $archiveQuotaString = 'N/A'
            if ($hasArchive) {
                try {
                    $archiveStats = Get-MailboxStatistics -Identity $userPrincipalName -Archive -ErrorAction Stop
                    $archiveUsedString = $archiveStats.TotalItemSize.ToString()
                    $archiveQuotaString = $mailboxDetails.ArchiveQuota.ToString()
                }
                catch {
                    Write-Warning "Error retrieving archive stats for $userPrincipalName : $($_.Exception.Message)"
                    $archiveUsedString = 'Error'
                    $archiveQuotaString = 'Error'
                }
            }
            
            # Determine action
            $actionTaken = 'None'
            
            if ($quotaBytes -eq 0) {
                $actionTaken = 'Skipped - Unable to read quota'
            }
            elseif ($freePercent -lt 25 -and -not $hasArchive) {
                if ($ReportOnly) {
                    $actionTaken = 'Would Enable Archive (Report Only Mode)'
                }
                elseif ($WhatIfPreference) {
                    # In WhatIf mode, just log what would happen
                    $actionTaken = 'Would Enable Archive (WhatIf)'
                    Write-ColorOutput -Message "  What if: Enabling archive for $userPrincipalName (Free: $([math]::Round($freePercent, 2))%)" -ForegroundColor Cyan
                }
                else {
                    # Normal execution - enable without confirmation
                    try {
                        $null = Enable-Mailbox -Identity $userPrincipalName -Archive -Confirm:$false -ErrorAction Stop -WarningAction SilentlyContinue
                        $actionTaken = 'Archive Enabled'
                        $archivesEnabled++
                        Write-ColorOutput -Message "  ✓ Enabled archive for $userPrincipalName (Free: $([math]::Round($freePercent, 2))%)" -ForegroundColor Green
                    }
                    catch {
                        $actionTaken = "Failed to Enable Archive: $($_.Exception.Message)"
                        Write-ColorOutput -Message "  ✗ Failed to enable archive for $userPrincipalName" -ForegroundColor Red
                        
                        [void]$errorEntries.Add([PSCustomObject]@{
                            User      = $userPrincipalName
                            Error     = $_.Exception.Message
                            Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        })
                    }
                }
            }
            elseif ($hasArchive) {
                $actionTaken = 'Archive Already Enabled'
            }
            else {
                $actionTaken = 'No Action Needed (Sufficient Space)'
            }
            
            # Log the results
            [void]$logEntries.Add([PSCustomObject]@{
                UserPrincipalName   = $userPrincipalName
                DisplayName         = $mailbox.DisplayName
                PrimaryMailboxUsed  = $usedString
                PrimaryMailboxQuota = $quotaString
                FreeSpacePercent    = [math]::Round($freePercent, 2)
                ArchiveStatus       = $mailboxDetails.ArchiveStatus
                ArchiveUsed         = $archiveUsedString
                ArchiveQuota        = $archiveQuotaString
                AssignedLicenses    = $licenseInfo
                ActionTaken         = $actionTaken
                ProcessedDateTime   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            })
        }
        catch {
            Write-Warning "Error processing $userPrincipalName : $($_.Exception.Message)"
            
            [void]$errorEntries.Add([PSCustomObject]@{
                User      = $userPrincipalName
                Error     = $_.Exception.Message
                Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            })
            
            # Add to log with error status
            [void]$logEntries.Add([PSCustomObject]@{
                UserPrincipalName   = $userPrincipalName
                DisplayName         = $mailbox.DisplayName
                PrimaryMailboxUsed  = 'Error'
                PrimaryMailboxQuota = 'Error'
                FreeSpacePercent    = 'N/A'
                ArchiveStatus       = 'Error'
                ArchiveUsed         = 'N/A'
                ArchiveQuota        = 'N/A'
                AssignedLicenses    = 'N/A'
                ActionTaken         = "Error: $($_.Exception.Message)"
                ProcessedDateTime   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            })
        }
    }

    Write-Progress -Activity 'Processing Mailboxes' -Completed
    
    #endregion Process Mailboxes

    #region Generate Reports
    
    Write-Host ''
    Write-ColorOutput -Message '========================================' -ForegroundColor Cyan
    Write-ColorOutput -Message 'Processing Complete' -ForegroundColor Cyan
    Write-ColorOutput -Message '========================================' -ForegroundColor Cyan
    Write-ColorOutput -Message "Total mailboxes processed: $counter" -ForegroundColor White

    if ($ReportOnly) {
        Write-ColorOutput -Message 'Archives enabled: N/A (Report Only Mode)' -ForegroundColor Yellow
    }
    else {
        Write-ColorOutput -Message "Archives enabled: $archivesEnabled" -ForegroundColor Green
    }

    Write-ColorOutput -Message "Errors encountered: $($errorEntries.Count)" `
                     -ForegroundColor $(if ($errorEntries.Count -gt 0) { 'Red' } else { 'Green' })
    Write-Host ''

    # Generate filename with company name and date
    $dateStamp = Get-Date -Format 'yyyyMMdd'
    $reportFilename = "Mailbox_Report_${cleanCompanyName}_${dateStamp}.csv"

    # Determine log folder
    if ($PSBoundParameters.ContainsKey('LogPath')) {
        $finalLogPath = Join-Path -Path $LogPath -ChildPath $reportFilename
    }
    else {
        # Use Documents folder as default
        $documentsPath = [Environment]::GetFolderPath('MyDocuments')
        $finalLogPath = Join-Path -Path $documentsPath -ChildPath $reportFilename
    }

    # Export main report
    $logEntries | Export-Csv -Path $finalLogPath -NoTypeInformation -Encoding UTF8
    Write-ColorOutput -Message "✓ Report exported to: $finalLogPath" -ForegroundColor Green

    # Export error log if there were errors
    if ($errorEntries.Count -gt 0) {
        # Generate error log filename
        $errorFilename = "Mailbox_Report_${cleanCompanyName}_${dateStamp}_Errors.csv"
        
        if ($PSBoundParameters.ContainsKey('LogPath')) {
            $errorLogPath = Join-Path -Path $LogPath -ChildPath $errorFilename
        }
        else {
            $documentsPath = [Environment]::GetFolderPath('MyDocuments')
            $errorLogPath = Join-Path -Path $documentsPath -ChildPath $errorFilename
        }
        
        $errorEntries | Export-Csv -Path $errorLogPath -NoTypeInformation -Encoding UTF8
        Write-ColorOutput -Message "✓ Error log exported to: $errorLogPath" -ForegroundColor Yellow
    }

    Write-Host ''
    
    #endregion Generate Reports
}
catch {
    Write-Error "An unexpected error occurred: $($_.Exception.Message)"
    exit 1
}
finally {
    #region Cleanup
    
    # Disconnect sessions
    Write-ColorOutput -Message 'Disconnecting from services...' -ForegroundColor Yellow
    $null = Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    if ($graphConnected) {
        $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
    }
    Write-ColorOutput -Message '✓ Disconnected' -ForegroundColor Green

    Write-Host ''
    Write-ColorOutput -Message 'Script execution completed successfully!' -ForegroundColor Cyan
    
    #endregion Cleanup
}

#endregion Main Script