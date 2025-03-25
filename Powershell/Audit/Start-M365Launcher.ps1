param (
    [switch]$Azure,
    [switch]$Exchange,
    [switch]$SharePoint,
    [switch]$Teams
)

Write-Host "`n=== M365 Audit Launcher ===`n"

# Updated base URL for hosted scripts
$baseUrl = "https://ps.cqts.com.au/365Audit"

if ($Azure) {
    Write-Host "Running Azure audit..." -ForegroundColor Cyan
    irm "$baseUrl/Invoke-AzureAudit.ps1" | iex
}

if ($Exchange) {
    Write-Host "Running Exchange audit..." -ForegroundColor Cyan
    irm "$baseUrl/Invoke-ExchangeAudit.ps1" | iex
}

if ($SharePoint) {
    Write-Host "Running SharePoint audit..." -ForegroundColor Cyan
    irm "$baseUrl/Invoke-SharePointAudit.ps1" | iex
}

if ($Teams) {
    Write-Host "Running Teams audit..." -ForegroundColor Cyan
    irm "$baseUrl/Invoke-TeamsAudit.ps1" | iex
}

if (-not ($Azure -or $Exchange -or $SharePoint -or $Teams)) {
    Write-Host "No modules selected. Use one or more of the following flags:"
    Write-Host "  -Azure -Exchange -SharePoint -Teams" -ForegroundColor Yellow
}
