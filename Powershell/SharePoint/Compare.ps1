<#
===============================================================================
 Script:        Compare-Inventories.ps1
 Purpose:       Compare Local vs SharePoint inventories and emit three CSVs.
 Author:        Raymond Slater
 Version:       1.0.0
 Change Log:    1.0.0 - Initial release
===============================================================================
#>

[CmdletBinding()]
param(
    # Optional: explicit CSVs. If omitted, the script picks the newest in ReportFolder.
    [string]$LocalCsv,
    [string]$SharePointCsv,
    [string]$ConfigPath
)

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "config.json" }
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config file not found: $ConfigPath. Copy config.json.sample and fill it in."
}

$Config       = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$ReportFolder = $Config.ReportFolder
if (-not $ReportFolder) { throw "Missing 'ReportFolder' in $ConfigPath." }

# Timestamp tolerance (seconds) to ignore tiny clock skews
$toleranceSecs = if ($Config.TimestampToleranceSeconds) { [int]$Config.TimestampToleranceSeconds } else { 2 }
$tolerance     = [TimeSpan]::FromSeconds($toleranceSecs)

# Pick newest CSVs if not provided
function Get-NewestCsvMatch {
    param([string]$Pattern)
    Get-ChildItem -LiteralPath $ReportFolder -Filter $Pattern | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
}

if (-not $LocalCsv) {
    $file = Get-NewestCsvMatch -Pattern "Local_*.csv"
    if (-not $file) { throw "No Local_*.csv found in $ReportFolder. Run Export-LocalInventory first." }
    $LocalCsv = $file.FullName
}
if (-not $SharePointCsv) {
    $file = Get-NewestCsvMatch -Pattern "SharePoint_*.csv"
    if (-not $file) { throw "No SharePoint_*.csv found in $ReportFolder. Run Export-SharePointInventory first." }
    $SharePointCsv = $file.FullName
}

Write-Host "Local CSV:      $LocalCsv" -ForegroundColor Cyan
Write-Host "SharePoint CSV: $SharePointCsv" -ForegroundColor Cyan

$local = Import-Csv -LiteralPath $LocalCsv
$cloud = Import-Csv -LiteralPath $SharePointCsv

# Index by RelativePath
$localIdx = $local | Group-Object RelativePath -AsHashTable -AsString
$cloudIdx = $cloud | Group-Object RelativePath -AsHashTable -AsString

# Cloud-only (stale in SharePoint)
$cloudOnly = foreach ($c in $cloud) {
    if (-not $localIdx.ContainsKey($c.RelativePath)) { $c }
}

# Local-only (not yet migrated)
$localOnly = foreach ($l in $local) {
    if (-not $cloudIdx.ContainsKey($l.RelativePath)) { $l }
}

# Mismatched on size or timestamp
$mismatched = @()
foreach ($c in $cloud) {
    if ($localIdx.ContainsKey($c.RelativePath)) {
        $l = $localIdx[$c.RelativePath]
        # cast to correct types
        $lLen = [int64]$l.Length
        $cLen = [int64]$c.Length
        # Parse timestamps (works with local CSVs). If you switched exporters to ISO 8601, see alt block below.
        $culture = [System.Globalization.CultureInfo]::CurrentCulture

        try   { $lUtc = [datetime]::Parse($l.LastWriteTimeUtc, $culture) }
        catch { $lUtc = [datetime]::MinValue }

        try   { $cUtc = [datetime]::Parse($c.LastWriteTimeUtc, $culture) }
        catch { $cUtc = [datetime]::MinValue }

        $sizeDiff = ([int64]$l.Length -ne [int64]$c.Length)
        $delta    = ($lUtc - $cUtc).Duration()
        $timeDiff = ($delta -gt $tolerance)

        if ($sizeDiff -or $timeDiff) {
            $mismatched += [PSCustomObject]@{
                RelativePath         = $c.RelativePath
                Local_Length         = $lLen
                Cloud_Length         = $cLen
                Local_LastWriteUtc   = $lUtc
                Cloud_LastWriteUtc   = $cUtc
                SizeDifferent        = $sizeDiff
                TimestampDifferent   = $timeDiff
            }
        }
    }
}

$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$cloudOnlyCsv  = Join-Path $ReportFolder "CloudOnly_Stale_$ts.csv"
$localOnlyCsv  = Join-Path $ReportFolder "LocalOnly_NotYetMigrated_$ts.csv"
$mismatchCsv   = Join-Path $ReportFolder "Mismatched_SizeOrTimestamp_$ts.csv"

$cloudOnly  | Sort-Object RelativePath | Export-Csv $cloudOnlyCsv -NoTypeInformation
$localOnly  | Sort-Object RelativePath | Export-Csv $localOnlyCsv -NoTypeInformation
$mismatched | Sort-Object RelativePath | Export-Csv $mismatchCsv  -NoTypeInformation

[PSCustomObject]@{
    LocalFiles                 = $local.Count
    SharePointFiles            = $cloud.Count
    CloudOnly_Stale            = $cloudOnly.Count
    LocalOnly_NotYetMigrated   = $localOnly.Count
    Mismatched_SizeOrTimestamp = $mismatched.Count
    TimestampToleranceSeconds  = $toleranceSecs
    OutputFolder               = $ReportFolder
} | Format-List