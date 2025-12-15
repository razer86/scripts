<#
.SYNOPSIS
    Runs a network speed test using the Ookla Speedtest CLI.

.DESCRIPTION
    This script automatically downloads, caches, and runs the latest Ookla Speedtest CLI.
    It intelligently manages the CLI binary by:
    - Checking for a cached copy in ProgramData (or LocalAppData if non-admin)
    - Downloading the latest version if missing or outdated
    - Passing through any additional command-line arguments to speedtest.exe
    - Automatically accepting license agreements
    
    The script scrapes the official speedtest.net website to obtain the latest download URL
    and caches the binary to avoid repeated downloads.

.PARAMETER AdditionalArgs
    Optional arguments to pass directly to speedtest.exe.
    Examples: --server-id=12345, --format=json, --selection-details

.PARAMETER ForceUpdate
    Forces a re-download of the Speedtest CLI even if a cached version exists.

.PARAMETER SkipVersionCheck
    Skips checking if a newer version is available (faster execution).

.EXAMPLE
    .\Run-Speedtest.ps1
    Runs a standard speed test with default settings.

.EXAMPLE
    .\Run-Speedtest.ps1 -AdditionalArgs '--format=json'
    Runs a speed test and outputs results in JSON format.

.EXAMPLE
    .\Run-Speedtest.ps1 -ForceUpdate
    Forces a fresh download of the latest Speedtest CLI before running.

.EXAMPLE
    irm https://ps.cqts.com.au/speedtest | iex
    Remote execution via short URL (parameters not supported in this mode).

.NOTES
    File Name      : Run-Speedtest.ps1
    Author         : Raymond Slater
    Prerequisite   : PowerShell 5.1 or later
    Version        : 2.0
    URL            : https://ps.cqts.com.au/speedtest
    
    Exit Codes:
    0 = Success
    1 = Download/extraction failure
    2 = Speedtest execution failure
    3 = Regex parsing failure

.LINK
    https://www.speedtest.net/apps/cli
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AdditionalArgs,
    
    [Parameter()]
    [switch]$ForceUpdate,
    
    [Parameter()]
    [switch]$SkipVersionCheck
)

#Region Configuration
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Determine installation path based on elevation
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    $installPath = "$env:ProgramData\SpeedtestCLI"
} else {
    $installPath = "$env:LOCALAPPDATA\SpeedtestCLI"
    Write-Verbose "Running without admin privileges - using user-local cache"
}

$exePath = Join-Path $installPath "speedtest.exe"
$versionFile = Join-Path $installPath "version.txt"
$tempZip = Join-Path $env:TEMP "speedtest-cli-$(Get-Random).zip"
$tempExtract = Join-Path $env:TEMP "speedtest-cli-$(Get-Random)"

# Script-level variable to store detected version
$script:LatestVersion = $null
#EndRegion Configuration

#Region Functions
function Write-ColorOutput {
    <#
    .SYNOPSIS
        Writes colored output to the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,
        
        [Parameter()]
        [ConsoleColor]$ForegroundColor = 'White'
    )
    
    Write-Host $Message -ForegroundColor $ForegroundColor
}

function Get-LatestDownloadURL {
    <#
    .SYNOPSIS
        Scrapes the Speedtest CLI download page for the latest Windows 64-bit version.
    
    .OUTPUTS
        System.String - The download URL for the latest version
    #>
    [CmdletBinding()]
    param()
    
    try {
        Write-Verbose "Fetching latest download information from speedtest.net"
        $response = Invoke-WebRequest -Uri "https://www.speedtest.net/apps/cli" -UseBasicParsing -TimeoutSec 30
        
        # Regex pattern to match the Windows 64-bit download link and capture version
        $pattern = 'href="(https://install\.speedtest\.net/app/cli/ookla-speedtest-([\d\.]+)-win64\.zip)"'
        
        if ($response.Content -match $pattern) {
            $script:LatestVersion = $matches[2]
            $downloadUrl = $matches[1]
            
            Write-Verbose "Found Speedtest CLI v$script:LatestVersion"
            return $downloadUrl
        } else {
            throw "Could not parse Speedtest CLI download link from webpage. The page structure may have changed."
        }
    }
    catch {
        Write-Error "Failed to retrieve download URL: $_"
        exit 3
    }
}

function Get-InstalledVersion {
    <#
    .SYNOPSIS
        Retrieves the version of the currently installed Speedtest CLI.
    
    .OUTPUTS
        System.String - The installed version number, or $null if not found
    #>
    [CmdletBinding()]
    param()
    
    if (Test-Path $versionFile) {
        try {
            $version = Get-Content $versionFile -Raw -ErrorAction Stop
            return $version.Trim()
        }
        catch {
            Write-Verbose "Could not read version file: $_"
        }
    }
    
    # Fallback: Try to get version from executable
    if (Test-Path $exePath) {
        try {
            $output = & $exePath --version 2>&1
            if ($output -match '[\d\.]+') {
                return $matches[0]
            }
        }
        catch {
            Write-Verbose "Could not retrieve version from executable: $_"
        }
    }
    
    return $null
}

function Test-SpeedtestUpToDate {
    <#
    .SYNOPSIS
        Checks if the installed Speedtest CLI is the latest version.
    
    .OUTPUTS
        System.Boolean - $true if up to date or check skipped, $false if update needed
    #>
    [CmdletBinding()]
    param()
    
    if ($SkipVersionCheck) {
        Write-Verbose "Version check skipped by parameter"
        return $true
    }
    
    if (-not (Test-Path $exePath)) {
        Write-Verbose "Speedtest CLI not found - installation required"
        return $false
    }
    
    $installedVersion = Get-InstalledVersion
    
    if (-not $installedVersion) {
        Write-Verbose "Could not determine installed version - assuming update needed"
        return $false
    }
    
    # Get latest version if not already retrieved
    if (-not $script:LatestVersion) {
        $null = Get-LatestDownloadURL
    }
    
    if ($installedVersion -ne $script:LatestVersion) {
        Write-ColorOutput "Update available: v$installedVersion → v$script:LatestVersion" -ForegroundColor Cyan
        return $false
    }
    
    Write-Verbose "Speedtest CLI v$installedVersion is up to date"
    return $true
}

function Install-SpeedtestCLI {
    <#
    .SYNOPSIS
        Downloads and installs the latest Speedtest CLI.
    #>
    [CmdletBinding()]
    param()
    
    try {
        # Get download URL and version
        $downloadUrl = Get-LatestDownloadURL
        
        Write-ColorOutput "Downloading Speedtest CLI v$script:LatestVersion..." -ForegroundColor Yellow
        
        # Download with progress indication for large files
        $webClient = New-Object System.Net.WebClient
        try {
            $webClient.DownloadFile($downloadUrl, $tempZip)
        }
        finally {
            $webClient.Dispose()
        }
        
        Write-Verbose "Download complete: $tempZip"
        
        # Extract archive
        Write-ColorOutput "Extracting CLI..." -ForegroundColor Yellow
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
        
        # Create installation directory if needed
        if (-not (Test-Path $installPath)) {
            Write-Verbose "Creating installation directory: $installPath"
            New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        }
        
        # Copy executable to installation path
        $sourceExe = Join-Path $tempExtract "speedtest.exe"
        if (-not (Test-Path $sourceExe)) {
            throw "speedtest.exe not found in extracted archive"
        }
        
        Copy-Item -Path $sourceExe -Destination $exePath -Force
        Write-Verbose "Copied executable to: $exePath"
        
        # Save version information
        Set-Content -Path $versionFile -Value $script:LatestVersion -NoNewline
        
        # Cleanup temporary files
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        
        Write-ColorOutput "✓ Speedtest CLI v$script:LatestVersion installed to $installPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Installation failed: $_"
        
        # Cleanup on failure
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        
        exit 1
    }
}

function Invoke-Speedtest {
    <#
    .SYNOPSIS
        Executes the Speedtest CLI with specified arguments.
    #>
    [CmdletBinding()]
    param()
    
    try {
        # Build argument list
        $arguments = @('--accept-license', '--accept-gdpr')
        
        if ($AdditionalArgs) {
            $arguments += $AdditionalArgs
        }
        
        Write-Verbose "Executing: $exePath $($arguments -join ' ')"
        Write-Host "" # Blank line for readability
        
        # Execute speedtest
        & $exePath @arguments
        
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Speedtest completed with exit code: $LASTEXITCODE"
            exit 2
        }
    }
    catch {
        Write-Error "Failed to execute Speedtest CLI: $_"
        exit 2
    }
}
#EndRegion Functions

#Region Main Execution
try {
    Write-Verbose "Starting Speedtest CLI execution"
    Write-Verbose "Installation path: $installPath"
    Write-Verbose "Executable path: $exePath"
    
    # Determine if installation/update is needed
    $needsInstall = $false
    
    if ($ForceUpdate) {
        Write-ColorOutput "Force update requested - downloading latest version..." -ForegroundColor Cyan
        $needsInstall = $true
    }
    elseif (-not (Test-Path $exePath)) {
        Write-ColorOutput "Speedtest CLI not found - installing..." -ForegroundColor Yellow
        $needsInstall = $true
    }
    elseif (-not (Test-SpeedtestUpToDate)) {
        Write-ColorOutput "Installing update..." -ForegroundColor Yellow
        $needsInstall = $true
    }
    
    # Install or update if needed
    if ($needsInstall) {
        Install-SpeedtestCLI
    }
    
    # Run speedtest
    Invoke-Speedtest
    
    Write-Verbose "Speedtest completed successfully"
}
catch {
    Write-Error "An unexpected error occurred: $_"
    exit 1
}
finally {
    # Restore preferences
    $ProgressPreference = 'Continue'
}
#EndRegion Main Execution