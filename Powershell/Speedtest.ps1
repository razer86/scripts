<#
.SYNOPSIS
    Runs an internet speed test using the latest version of Ookla Speedtest CLI.

.DESCRIPTION
    This script checks for the Speedtest CLI in ProgramData. If it's not installed,
    it dynamically detects the latest version from Ookla's official download page,
    downloads it, and installs it. Then, it runs the speed test.

.EXAMPLE
    irm https://scripts.cqts.com.au/speedtest.ps1 | iex

.NOTES
    Author: razer86
    Source: https://github.com/razer86/scripts
    Requirements: PowerShell 5.1+, Internet access
#>

$ErrorActionPreference = 'Stop'

$installPath = "$env:ProgramData\SpeedtestCLI"
$exePath = Join-Path $installPath "speedtest.exe"

function Get-LatestSpeedtestURL {
    $html = Invoke-WebRequest -Uri "https://install.speedtest.net/app/cli/" -UseBasicParsing
    $match = $html.Links | Where-Object { $_.href -match "win64.zip$" } | Select-Object -First 1

    if ($match -and $match.href -match "^https?://") {
        $url = $match.href

        # Extract version string from the URL (e.g., "1.2.0" from "...speedtest-1.2.0-win64.zip")
        if ($url -match "speedtest-([0-9\.]+)-win64\.zip") {
            $script:SpeedtestVersion = $Matches[1]
        } else {
            $script:SpeedtestVersion = "unknown"
        }

        return $url
    } else {
        throw "Could not determine latest Speedtest CLI download URL."
    }
}

function Install-SpeedtestCLI {
    $downloadUrl = Get-LatestSpeedtestURL
    $zipPath = "$env:TEMP\speedtest.zip"
    $extractPath = "$env:TEMP\speedtest"

    Write-Host "Downloading Speedtest CLI v$SpeedtestVersion from:`n$downloadUrl" -ForegroundColor Yellow
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath

    Write-Host "Extracting CLI..."
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    if (-not (Test-Path $installPath)) {
        New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    }

    Copy-Item -Path "$extractPath\speedtest.exe" -Destination $exePath -Force
    Write-Host "Speedtest CLI installed to $installPath" -ForegroundColor Green
}

function Run-Speedtest {
    Write-Host "`nRunning speed test..." -ForegroundColor Cyan
    & $exePath --accept-license --accept-gdpr
}

# Main logic
if (-not (Test-Path $exePath)) {
    Install-SpeedtestCLI
}

Run-Speedtest
