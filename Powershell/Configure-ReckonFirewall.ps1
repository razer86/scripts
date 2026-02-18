<#
.SYNOPSIS
    Adds or removes firewall rules and folder permissions for Reckon Accounts (2013–2025).

.DESCRIPTION
    Allows you to select a Reckon Accounts version, then add or remove:
    - Windows Firewall rules for executables and ports
    - Full control permissions on the company file folder for the correct QBDataServiceUser

    Based on official Reckon documentation:
    https://help.reckon.com/article/q2s978a9fo-kba-220-configuring-my-firewallantivirus-to-work-with-accounts-business-in-a-multi-user-environment

.EXAMPLE
    .\Configure-ReckonFirewall.ps1

.NOTES
    Author: Raymond Slater
    Requires: Run as Administrator
    Version: 2.0
    Last Updated: 2025-12-16
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param()

# Define all supported Reckon versions with their respective:
# - Listening port (starts at 10176 for 2013, increments by 1 each year)
# - Program folder name
# - QuickBooks service user (Version number = Year + 11, e.g., 2013 is v23)
$versions = @{
    "2013" = @{ Year = "2013"; Port = "10176"; Folder = "Reckon Accounts 2013"; DataUser = "QBDataServiceUser23" }
    "2014" = @{ Year = "2014"; Port = "10177"; Folder = "Reckon Accounts 2014"; DataUser = "QBDataServiceUser24" }
    "2015" = @{ Year = "2015"; Port = "10178"; Folder = "Reckon Accounts 2015"; DataUser = "QBDataServiceUser25" }
    "2016" = @{ Year = "2016"; Port = "10179"; Folder = "Reckon Accounts 2016"; DataUser = "QBDataServiceUser26" }
    "2017" = @{ Year = "2017"; Port = "10180"; Folder = "Reckon Accounts 2017"; DataUser = "QBDataServiceUser27" }
    "2018" = @{ Year = "2018"; Port = "10181"; Folder = "Reckon Accounts 2018"; DataUser = "QBDataServiceUser28" }
    "2019" = @{ Year = "2019"; Port = "10182"; Folder = "Reckon Accounts 2019"; DataUser = "QBDataServiceUser29" }
    "2020" = @{ Year = "2020"; Port = "10183"; Folder = "Reckon Accounts 2020"; DataUser = "QBDataServiceUser30" }
    "2021" = @{ Year = "2021"; Port = "10184"; Folder = "Reckon Accounts 2021"; DataUser = "QBDataServiceUser31" }
    "2022" = @{ Year = "2022"; Port = "10185"; Folder = "Reckon Accounts 2022"; DataUser = "QBDataServiceUser32" }
    "2023" = @{ Year = "2023"; Port = "10186"; Folder = "Reckon Accounts 2023"; DataUser = "QBDataServiceUser33" }
    "2024" = @{ Year = "2024"; Port = "10187"; Folder = "Reckon Accounts 2024"; DataUser = "QBDataServiceUser34" }
    "2025" = @{ Year = "2025"; Port = "10188"; Folder = "Reckon Accounts 2025"; DataUser = "QBDataServiceUser35" }
}

# Display a menu of supported versions
function Show-Menu {
    Write-Host "`n*** Reckon Accounts Firewall & Folder Permissions Utility ***`n" -ForegroundColor Cyan
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
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Program,

        [string]$Port
    )

    if ($Program) {
        Write-Host "Adding firewall rule: $Name" -ForegroundColor Green
        $result = netsh advfirewall firewall add rule name="$Name" program="$Program" action=allow enable=yes dir=in profile=any 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to add firewall rule for $Name. Error: $result"
        }
    }

    if ($Port) {
        Write-Host "Adding port rule: $Name - Port $Port" -ForegroundColor Green
        $result = netsh advfirewall firewall add rule name="$Name - Port" dir=in action=allow protocol=TCP localport=$Port enable=yes 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to add port rule for $Name. Error: $result"
        }
    }
}

# Grant folder access permissions to a specific user
function Set-FolderPermissions {
    param (
        [Parameter(Mandatory)]
        [string]$Folder,

        [Parameter(Mandatory)]
        [string]$User
    )

    if (Test-Path -Path $Folder -PathType Container) {
        Write-Host "Granting Full Control to $User on $Folder" -ForegroundColor Green
        $result = icacls $Folder /grant "${User}:(OI)(CI)F" /T /C 2>&1  # OI/CI = object/container inherit
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to set permissions for $User on $Folder. Error: $result"
        } else {
            Write-Host "Successfully granted permissions to $User" -ForegroundColor Green
        }
    } else {
        Write-Host "`nERROR: Folder $Folder does not exist. Skipping permissions." -ForegroundColor Red
    }
}

# Prompt for the Reckon company file folder path and validate it
function Get-CompanyFileLocation {
    do {
        $path = Read-Host "Enter the full path to your Reckon Accounts company file folder (e.g., C:\ReckonData)"
        if (-not (Test-Path -Path $path -PathType Container)) {
            Write-Host "`nERROR: Folder does not exist. Please enter a valid path." -ForegroundColor Red
        }
    } while (-not (Test-Path -Path $path -PathType Container))  # Loop until a valid path is entered
    return $path
}

# Main script logic
function Main {
    Clear-Host
    Show-Menu  # Display version options
    $selectedYear = Get-UserChoice
    $selectedVersion = $versions[$selectedYear]

    # Determine install path based on OS architecture
    $installPath = if ([Environment]::Is64BitOperatingSystem) {
        Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "Intuit\$($selectedVersion.Folder)"
    } else {
        Join-Path -Path ${env:ProgramFiles} -ChildPath "Intuit\$($selectedVersion.Folder)"
    }

    # Common files location used across versions
    $commonPath = Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "Common Files\Intuit\QuickBooks"
    $qbUpdatePath = Join-Path -Path $commonPath -ChildPath "QBUpdate"

    # Verify installation path exists
    if (-not (Test-Path -Path $installPath)) {
        Write-Warning "Reckon Accounts $selectedYear installation not found at: $installPath"
        Write-Host "The firewall rules will still be created, but verify the installation path is correct." -ForegroundColor Yellow
    }

    # Ask for the folder where the Reckon company file(s) are stored
    $companyFileLocation = Get-CompanyFileLocation

    # Prompt for action
    Write-Host "`n1. Add $selectedYear Exceptions"
    Write-Host "2. Delete $selectedYear Exceptions`n"
    $actionChoice = Read-Host "Select an Action (1 = Add, 2 = Delete)"

    switch ($actionChoice) {
        "1" {
            Write-Host "`n*** Adding Firewall Exceptions ***`n" -ForegroundColor Cyan

            # Add per-executable rules
            Add-FirewallRule -Name "Reckon Accounts $selectedYear - FileManagement" -Program (Join-Path $installPath "FileManagement.exe")
            Add-FirewallRule -Name "Reckon Accounts $selectedYear - QBDBMgr" -Program (Join-Path $installPath "QBDBMgr.exe")
            Add-FirewallRule -Name "Reckon Accounts $selectedYear - QBDBMgrN" -Program (Join-Path $installPath "QBDBMgrN.exe")
            Add-FirewallRule -Name "Reckon Accounts $selectedYear - QBGDSPlugin" -Program (Join-Path $installPath "QBGDSPlugin.exe")
            Add-FirewallRule -Name "Reckon Accounts $selectedYear - QBW32" -Program (Join-Path $installPath "QBW32.exe")

            # Add shared/common executables
            Add-FirewallRule -Name "Reckon Common - QBCFMonitorService" -Program (Join-Path $commonPath "QBCFMonitorService.exe")
            Add-FirewallRule -Name "Reckon Common - QBUpdate" -Program (Join-Path $qbUpdatePath "QBUpdate.exe")

            # Add port rule
            Add-FirewallRule -Name "Reckon Accounts $selectedYear" -Port $selectedVersion.Port

            # Set folder permissions for the correct QB service user
            Set-FolderPermissions -Folder $companyFileLocation -User $selectedVersion.DataUser

            Write-Host "`nConfiguration completed successfully!" -ForegroundColor Green
            break
        }

        "2" {
            Write-Host "`n*** Removing Firewall Exceptions ***`n" -ForegroundColor Cyan

            # Remove specific rule names
            Write-Host "Removing firewall rules..." -ForegroundColor Yellow

            $rulesToRemove = @(
                "Reckon Accounts $selectedYear - FileManagement",
                "Reckon Accounts $selectedYear - QBDBMgr",
                "Reckon Accounts $selectedYear - QBDBMgrN",
                "Reckon Accounts $selectedYear - QBGDSPlugin",
                "Reckon Accounts $selectedYear - QBW32",
                "Reckon Accounts $selectedYear - Port"
            )

            foreach ($rule in $rulesToRemove) {
                netsh advfirewall firewall delete rule name="$rule" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Removed: $rule" -ForegroundColor Green
                } else {
                    Write-Host "  Not found: $rule" -ForegroundColor Gray
                }
            }

            Write-Host "`nFirewall rules removal completed!" -ForegroundColor Green
            Write-Host "`nNote: Folder permissions were not modified. Manually remove permissions for $($selectedVersion.DataUser) if needed." -ForegroundColor Yellow
            break
        }

        default {
            Write-Host "Invalid action. Exiting..." -ForegroundColor Red
            exit 1
        }
    }
}

# Entry point
Main
