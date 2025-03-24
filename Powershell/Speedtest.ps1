<#
.SYNOPSIS
    Runs a speed test using the latest Ookla Speedtest CLI.

.DESCRIPTION
    This script checks for a cached copy of the Speedtest CLI in ProgramData.
    If missing, it scrapes the latest download link from speedtest.net,
    downloads it, extracts it, and caches the binary. Then it runs the speed test
    using any arguments passed in.

.EXAMPLE
    irm https://ps.cqts.com.au/speedtest.ps1 | iex

    irm https://ps.cqts.com.au/speedtest.ps1 | iex -- --format json

.NOTES
    Author: Raymond Slater
    URL: https://ps.cqts.com.au/speedtest.ps1
#>

param (
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$installPath = "$env:ProgramData\SpeedtestCLI"
$exePath = Join-Path $installPath "speedtest.exe"
$tempZip = "$env:TEMP\speedtest-cli.zip"
$tempExtract = "$env:TEMP\speedtest-cli"

function Get-LatestDownloadURL {
    $html = Invoke-WebRequest -Uri "https://www.speedtest.net/apps/cli" -UseBasicParsing
    if ($html.Content -match 'href="(https://install\.speedtest\.net/app/cli/ookla-speedtest-([\d\.]+)-win64\.zip)"') {
        $script:SpeedtestVersion = $matches[2]
        return $matches[1]
    } else {
        throw "Could not find Speedtest CLI download link for Windows 64-bit."
    }
}

function Install-SpeedtestCLI {
    $url = Get-LatestDownloadURL
    Write-Host "Downloading Speedtest CLI v$SpeedtestVersion..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $url -OutFile $tempZip -UseBasicParsing

    Write-Host "Extracting CLI..."
    Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

    if (-not (Test-Path $installPath)) {
        New-Item -ItemType Directory -Path $installPath -Force | Out-Null
    }

    Copy-Item -Path "$tempExtract\speedtest.exe" -Destination $exePath -Force
    Remove-Item $tempZip, $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "Speedtest CLI v$SpeedtestVersion installed to $installPath" -ForegroundColor Green
}

function Run-Speedtest {
    if (-not ($ScriptArgs -contains "--accept-license")) {
        $ScriptArgs += "--accept-license"
    }
    if (-not ($ScriptArgs -contains "--accept-gdpr")) {
        $ScriptArgs += "--accept-gdpr"
    }

    & $exePath @ScriptArgs
}

# Main logic
if (-not (Test-Path $exePath)) {
    Install-SpeedtestCLI
}

Run-Speedtest
