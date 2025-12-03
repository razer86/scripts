<# =========================================
# ===   Install-ScreenConnect.ps1        ===
# =========================================
.SYNOPSIS
Downloads and installs the ScreenConnect client using configured metadata.

.DESCRIPTION
Defines a reusable Install-ScreenConnect function which:
- Builds the ScreenConnect client URL with the specified metadata fields.
- Downloads the installer to the local TEMP folder.
- Executes the installer (quietly by default).

Intended usage pattern (bootstrap):
    irm 'https://ps.cqts.com.au/Install-ScreenConnect.ps1' | iex
    Install-ScreenConnect -CompanyName 'NQBE' -Site 'Townsville' -Department 'IT' -Type 'Desktop'

.AUTHOR
Raymond Slater

.VERSION
1.0.0 - 2025-11-25
- Initial version.

#>

function Install-ScreenConnect {
    [CmdletBinding()]
    param(
        # ScreenConnect base URL (change if you move tenants or host)
        [Parameter()]
        [string]$BaseUrl = 'https://nqbe.screenconnect.com/Bin/ScreenConnect.ClientSetup.exe',

        # Device name field (ScreenConnect "t" parameter). Defaults to local computer name.
        [Parameter()]
        [string]$DeviceName = $env:COMPUTERNAME,

        # Custom fields mapped to ScreenConnect &c= parameters in order.
        [Parameter(Mandatory = $true)]
        [string]$CompanyName,

        [Parameter()]
        [string]$Site,

        [Parameter()]
        [string]$Department,

        [Parameter()]
        [string]$Type,

        # Where to save the EXE (defaults to %TEMP%\ScreenConnect.ClientSetup.exe)
        [Parameter()]
        [string]$OutputPath = (Join-Path $env:TEMP 'ScreenConnect.ClientSetup.exe'),

        # Extra arguments to pass to the installer (defaults to /quiet).
        [Parameter()]
        [string]$InstallerArguments = '/quiet'
    )

    Write-Host "==== Install-ScreenConnect ====" -ForegroundColor Cyan

    # Ensure TLS 1.2+ for older PowerShell
    try {
        if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        }
    }
    catch {
        Write-Host "Warning: Unable to set SecurityProtocol (TLS). Continuing anyway." -ForegroundColor Yellow
    }

    # Encode values for URL
    $encDevice     = [uri]::EscapeDataString($DeviceName)
    $encCompany    = if ($CompanyName) { [uri]::EscapeDataString($CompanyName) } else { '' }
    $encSite       = if ($Site)        { [uri]::EscapeDataString($Site)        } else { '' }
    $encDepartment = if ($Department)  { [uri]::EscapeDataString($Department)  } else { '' }
    $encType       = if ($Type)        { [uri]::EscapeDataString($Type)        } else { '' }

    # Build full URL
    # t = Device name
    # c fields map to your ScreenConnect custom fields (Company, Site, Dept, Type, etc.)
    $Url = "$BaseUrl?e=Access&y=Guest" +
           "&t=$encDevice"

    $cValues = @(
        $encCompany,     # Field 2 - Company
        $encSite,        # Field 3 - Site
        $encDepartment,  # Field 4 - Department
        $encType,        # Field 5 - Type
        '', '', '', ''   # Remaining &c= fields left blank
    )

    foreach ($val in $cValues) {
        $Url += "&c=$val"
    }

    Write-Host "Download URL:" -ForegroundColor Cyan
    Write-Host "  $Url" -ForegroundColor Yellow
    Write-Host ""

    # Ensure output folder exists
    $outDir = Split-Path -Path $OutputPath -Parent
    if (-not (Test-Path -Path $outDir)) {
        Write-Host "Creating output directory: $outDir" -ForegroundColor Cyan
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }

    # Download the installer
    Write-Host "Downloading ScreenConnect client to:" -ForegroundColor Cyan
    Write-Host "  $OutputPath" -ForegroundColor Yellow

    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing
    }
    catch {
        Write-Host "ERROR: Failed to download ScreenConnect client." -ForegroundColor Red
        Write-Host "       $_" -ForegroundColor Red
        return
    }

    if (-not (Test-Path -Path $OutputPath)) {
        Write-Host "ERROR: Download reported success but file not found at:" -ForegroundColor Red
        Write-Host "       $OutputPath" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "Running installer..." -ForegroundColor Cyan
    Write-Host "  Path: $OutputPath" -ForegroundColor Yellow
    Write-Host "  Args: $InstallerArguments" -ForegroundColor Yellow

    try {
        $proc = Start-Process -FilePath $OutputPath -ArgumentList $InstallerArguments -PassThru
        $proc.WaitForExit()
    }
    catch {
        Write-Host "ERROR: Failed to start ScreenConnect installer." -ForegroundColor Red
        Write-Host "       $_" -ForegroundColor Red
        return
    }

    Write-Host ""
    Write-Host "ScreenConnect installation completed with exit code: $($proc.ExitCode)" -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Cyan
}
