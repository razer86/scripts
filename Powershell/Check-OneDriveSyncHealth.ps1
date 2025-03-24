<#
.SYNOPSIS
    Checks OneDrive's synced document libraries and reports if the file count exceeds a health threshold.

.DESCRIPTION
    This script scans OneDrive for Business configuration files stored in the user's local profile
    and parses `ItemCount`, `SiteTitle`, and `DavUrlNamespace` to get a list of synced SharePoint sites.

    If the total number of synced items exceeds 280,000, it reports as unhealthy and outputs details.

.EXAMPLE
    .\Check-OneDriveSyncHealth.ps1

.NOTES
    Author: Raymond Slater
    Requirements: Windows with OneDrive for Business installed
#>

# Path to OneDrive for Business client policy INI files
$iniPath = Join-Path $env:LOCALAPPDATA "Microsoft\OneDrive\settings\Business1"
$iniFiles = Get-ChildItem -Path $iniPath -Filter 'ClientPolicy*' -ErrorAction SilentlyContinue

# Exit if no INI files are found
if (-not $iniFiles) {
    Write-Host "No OneDrive configuration files found. Stopping script." -ForegroundColor Red
    exit 1
}

# Parse each INI file and extract sync info
$SyncedLibraries = foreach ($file in $iniFiles) {
    $content = Get-Content $file.FullName -Encoding Unicode

    # Clean BOM if present
    if ($content[0] -match '^\uFEFF') {
        $content[0] = $content[0] -replace '^\uFEFF', ''
    }

    $itemCount = ($content | Where-Object { $_ -like 'ItemCount*' }) -split '= ' | Select-Object -Last 1
    $siteName  = ($content | Where-Object { $_ -like 'SiteTitle*' }) -split '= ' | Select-Object -Last 1
    $siteUrl   = ($content | Where-Object { $_ -like 'DavUrlNamespace*' }) -split '= ' | Select-Object -Last 1

    [PSCustomObject]@{
        'Site Name'  = $siteName
        'Site URL'   = $siteUrl
        'Item Count' = [int]$itemCount
    }
}

# Total number of synced items
$totalItemCount = ($SyncedLibraries.'Item Count' | Measure-Object -Sum).Sum

# Output per-site summary
Write-Host "`n📁 Synced Libraries:" -ForegroundColor Cyan
$SyncedLibraries | ForEach-Object {
    Write-Host ("- {0} - {1}" -f $_.'Site Name', $_.'Site URL')
}

# Final health check
if ($totalItemCount -gt 280000) {
    Write-Host "`n❌ Unhealthy: Currently syncing $totalItemCount files (over 280,000)." -ForegroundColor Red
    $SyncedLibraries | Format-Table
} else {
    Write-Host "`n✅ Healthy: Syncing $totalItemCount files (under 280,000)." -ForegroundColor Green
}
