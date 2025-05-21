<#
.SYNOPSIS
    Adds or removes firewall rules and folder permissions for Reckon Accounts (2013–2024).

.DESCRIPTION
    Allows you to select a Reckon Accounts version, then add or remove:
    - Windows Firewall rules for executables and ports
    - Full control permissions on the company file folder for the correct QBDataServiceUser

.EXAMPLE
    .\Configure-ReckonFirewall.ps1

.NOTES
    Author: Raymond Slater
    Requires: Admin rights
#>


# Define all supported Reckon versions with their respective:
# - Listening port
# - Program folder name
# - QuickBooks service user (used for folder permissions)
$versions = @{
    "2013" = @{ Year = "2013"; Port = "10176"; Folder = "Reckon Accounts 2013"; DataUser = "QBDataServiceUser22" }
    "2014" = @{ Year = "2014"; Port = "10177"; Folder = "Reckon Accounts 2014"; DataUser = "QBDataServiceUser23" }
    "2015" = @{ Year = "2015"; Port = "10178"; Folder = "Reckon Accounts 2015"; DataUser = "QBDataServiceUser24" }
    "2016" = @{ Year = "2016"; Port = "10179"; Folder = "Reckon Accounts 2016"; DataUser = "QBDataServiceUser25" }
    "2017" = @{ Year = "2017"; Port = "10180"; Folder = "Reckon Accounts 2017"; DataUser = "QBDataServiceUser26" }
    "2018" = @{ Year = "2018"; Port = "10181"; Folder = "Reckon Accounts 2018"; DataUser = "QBDataServiceUser27" }
    "2019" = @{ Year = "2019"; Port = "10182"; Folder = "Reckon Accounts 2019"; DataUser = "QBDataServiceUser28" }
    "2020" = @{ Year = "2020"; Port = "10183"; Folder = "Reckon Accounts 2020"; DataUser = "QBDataServiceUser29" }
    "2021" = @{ Year = "2021"; Port = "10184"; Folder = "Reckon Accounts 2021"; DataUser = "QBDataServiceUser30" }
    "2022" = @{ Year = "2022"; Port = "10185"; Folder = "Reckon Accounts 2022"; DataUser = "QBDataServiceUser31" }
    "2023" = @{ Year = "2023"; Port = "10186"; Folder = "Reckon Accounts 2023"; DataUser = "QBDataServiceUser32" }
    "2024" = @{ Year = "2024"; Port = "10187"; Folder = "Reckon Accounts 2024"; DataUser = "QBDataServiceUser33" }
}

# Display a menu of supported versions
function Show-Menu {
    Write-Host "`n*** Reckon Accounts Firewall & Folder Permissions Utility ***`n"
    $versions.Keys | Sort-Object | ForEach-Object {
        Write-Host "$_ - Reckon Accounts $_"
    }
    Write-Host ""
}

# Prompt the user to select a version year
function Get-UserChoice {
    do {
        $choice = Read-Host "Enter the 4-digit year for the Reckon Accounts version you want to configure"
    } while (-not $versions.ContainsKey($choice))  # Keep asking until a valid year is entered
    return $choice
}

# Add a firewall rule for either a program path or a port (or both)
function Add-FirewallRule {
    param (
        [string]$name,
        [string]$program = $null,
        [string]$port = $null
    )

    if ($program) {
        Write-Host "Adding firewall rule: $name"
        netsh advfirewall firewall add rule name="$name" program="$program" action=allow enable=yes dir=in profile=any
    }

    if ($port) {
        Write-Host "Adding port rule: $name - Port $port"
        netsh advfirewall firewall add rule name="$name - Port" dir=in action=allow protocol=TCP localport=$port enable=yes
    }
}

# Grant folder access permissions to a specific user
function Set-FolderPermissions {
    param (
        [string]$folder,
        [string]$user
    )

    if (Test-Path $folder) {
        Write-Host "Granting Full Control to $user on $folder"
        icacls $folder /grant "${user}:(OI)(CI)F" /T /C  # OI/CI = object/container inherit
    } else {
        Write-Host "`n❌ ERROR: Folder $folder does not exist. Skipping permissions." -ForegroundColor Red
    }
}

# Prompt for the Reckon company file folder path and validate it
function Get-CompanyFileLocation {
    do {
        $path = Read-Host "Enter the full path to your Reckon Accounts company file folder (e.g., C:\ReckonData)"
        if (-not (Test-Path $path)) {
            Write-Host "`n❌ ERROR: Folder does not exist. Please enter a valid path." -ForegroundColor Red
        }
    } while (-not (Test-Path $path))  # Loop until a valid path is entered
    return $path
}

# Main script logic
function Main {
    cls
    Show-Menu  # Display version options
    $selectedYear = Get-UserChoice
    $selectedVersion = $versions[$selectedYear]

    # Determine install path based on OS architecture
    $installPath = if ([Environment]::Is64BitOperatingSystem) {
        "${env:ProgramFiles(x86)}\Intuit\$($selectedVersion.Folder)"
    } else {
        "${env:ProgramFiles}\Intuit\$($selectedVersion.Folder)"
    }

    # Common files location used across versions
    $commonPath = "${env:ProgramFiles(x86)}\Common Files\Intuit\QuickBooks"

    # Ask for the folder where the Reckon company file(s) are stored
    $companyFileLocation = Get-CompanyFileLocation

    # Prompt for action
    Write-Host "`n1. Add $selectedYear Exceptions"
    Write-Host "2. Delete $selectedYear Exceptions`n"
    $actionChoice = Read-Host "Select an Action (1 = Add, 2 = Delete)"

    switch ($actionChoice) {
        "1" {
            Write-Host "`n*** Adding Firewall Exceptions ***`n"

            # Add per-executable rules
            Add-FirewallRule -name "Reckon Accounts $selectedYear - FileManagement" -program "$installPath\FileManagement.exe"
            Add-FirewallRule -name "Reckon Accounts $selectedYear - QBDBMgr" -program "$installPath\QBDBMgr.exe"
            Add-FirewallRule -name "Reckon Accounts $selectedYear - QBDBMgrN" -program "$installPath\QBDBMgrN.exe"
            Add-FirewallRule -name "Reckon Accounts $selectedYear - QBGDSPlugin" -program "$installPath\QBGDSPlugin.exe"
            Add-FirewallRule -name "Reckon Accounts $selectedYear - QBW32" -program "$installPath\QBW32.exe"

            # Add shared/common executables
            Add-FirewallRule -name "Reckon Common - QBCFMonitorService" -program "$commonPath\QBCFMonitorService.exe"
            Add-FirewallRule -name "Reckon Common - QBUpdate" -program "$commonPath\QBUpdate.exe"

            # Add port rule
            Add-FirewallRule -name "Reckon Accounts $selectedYear - Port" -port $selectedVersion.Port

            # Set folder permissions for the correct QB service user
            Set-FolderPermissions -folder $companyFileLocation -user $selectedVersion.DataUser
            break
        }

        "2" {
            Write-Host "`n*** Removing Firewall Exceptions ***`n"

            # Remove only specific rule names — adjust as needed
            netsh advfirewall firewall delete rule name="Reckon Accounts $selectedYear - FileManagement"
            netsh advfirewall firewall delete rule name="Reckon Accounts $selectedYear - QBDBMgr"
            netsh advfirewall firewall delete rule name="Reckon Accounts $selectedYear - QBDBMgrN"
            netsh advfirewall firewall delete rule name="Reckon Accounts $selectedYear - Port"
            break
        }

        default {
            Write-Host "Invalid action. Exiting..." -ForegroundColor Yellow
        }
    }
}

# Entry point
Main
