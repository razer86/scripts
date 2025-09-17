<# 
===============================================================================
 Script:        Export-SharePointInventory.ps1
 Purpose:       Connect to SharePoint Online (PnP) using values from config.json
                and export a file inventory CSV for comparison with on-prem data.
 Author:        Raymond Slater
===============================================================================
#>

[CmdletBinding()]
param(
    # Optional override for config path. Defaults to "<script folder>\config.json"
    [string]$ConfigPath
)

# === Resolve config path ===
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "config.json" }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath. Copy config.json.sample and fill it in."
}

# === Load config ===
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$AppId        = $Config.AppId
$Tenant       = $Config.Tenant
$SiteUrl      = $Config.SiteUrl
$LibraryTitle = $Config.LibraryTitle
$ReportFolder = $Config.ReportFolder

# === Validate required settings ===
$missing = @()
if (-not $AppId)        { $missing += 'AppId' }
if (-not $Tenant)       { $missing += 'Tenant' }
if (-not $SiteUrl)      { $missing += 'SiteUrl' }
if (-not $LibraryTitle) { $missing += 'LibraryTitle' }
if (-not $ReportFolder) { $missing += 'ReportFolder' }
if ($missing.Count -gt 0) {
    throw "Missing required config keys: $($missing -join ', '). Please update $ConfigPath."
}

# === Connect (interactive MFA against YOUR app) ===
Write-Host "Connecting to $SiteUrl as app $AppId (tenant $Tenant)..." -ForegroundColor Cyan
Connect-PnPOnline -Url $SiteUrl -ClientId $AppId -Tenant $Tenant -Interactive

# === Prep output ===
New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null
$ts = Get-Date -Format "yyyyMMdd-HHmmss"

# === Inventory: library root and files only ===
Write-Host "Enumerating library '$LibraryTitle'..." -ForegroundColor Cyan
$list    = Get-PnPList -Identity $LibraryTitle
$libRoot = $list.RootFolder.ServerRelativeUrl

$items = Get-PnPListItem -List $LibraryTitle -PageSize 2000 -Fields FileRef,File_x0020_Size,Modified,FSObjType |
    Where-Object { $_.FieldValues.FSObjType -eq 0 } |   # files only
    ForEach-Object {
        $ref      = $_.FieldValues.FileRef
        $decoded  = [System.Web.HttpUtility]::UrlDecode($ref)
        $relative = $decoded.Substring($libRoot.Length).TrimStart('/','\').Replace('/','\')
        [PSCustomObject]@{
            RelativePath      = $relative
            ServerRelativeUrl = $decoded
            Length            = [int64]$_.FieldValues.'File_x0020_Size'
            LastWriteTimeUtc  = [datetime]$_.FieldValues.Modified
        }
    }

# === Export CSV ===
$outCsv = Join-Path $ReportFolder ("SharePoint_{0}_{1}.csv" -f ($LibraryTitle -replace '\s','_'), $ts)
$items | Sort-Object RelativePath | Export-Csv $outCsv -NoTypeInformation

# === Summary ===
Write-Host "Files enumerated: $($items.Count)" -ForegroundColor Green
Write-Host "CSV written to:   $outCsv" -ForegroundColor Green
