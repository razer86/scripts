#Requires -Version 5.1
<#
.SYNOPSIS
    Reads a filled-in UnmappedDomains.csv, creates any missing Outlook folders,
    and adds the new mappings to InboxRouting.xlsx.

.PARAMETER WhatIf
    Show what would be created/added without making any changes.

.EXAMPLE
    .\Add-DomainMappings.ps1 -WhatIf
    .\Add-DomainMappings.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param()

# ── CONFIG ────────────────────────────────────────────────────────────────────

$MailboxMatch = 'ray.slater@capconnect'
$WorkbookPath = Join-Path $PSScriptRoot 'InboxRouting.xlsx'
$CsvPath      = Join-Path $PSScriptRoot 'UnmappedDomains.csv'

# ── END CONFIG ────────────────────────────────────────────────────────────────

function Resolve-FolderPath {
    param([object]$BaseFolder, [string]$Path)
    $current = $BaseFolder
    foreach ($part in ($Path -split '\\')) {
        $current = $current.Folders | Where-Object { $_.Name -eq $part }
        if (-not $current) { return $null }
    }
    return $current
}

# ── LOAD CSV ──────────────────────────────────────────────────────────────────

if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }

$rows = Import-Csv $CsvPath | Where-Object {
    $_.FolderName -and $_.FolderName.Trim() -ne '' -and
    $_.Category   -and $_.Category.Trim()   -ne ''
}

if ($rows.Count -eq 0) {
    Write-Host "No rows with FolderName and Category filled in. Nothing to do." -ForegroundColor Yellow
    exit
}

Write-Host "`n$($rows.Count) rows to process." -ForegroundColor Cyan

# ── CONNECT OUTLOOK ───────────────────────────────────────────────────────────

Write-Host "Connecting to Outlook..." -ForegroundColor Cyan
$outlook   = New-Object -ComObject Outlook.Application
$namespace = $outlook.GetNamespace('MAPI')
$namespace.Logon()

$store = $namespace.Folders | Where-Object { $_.Name -like "*$MailboxMatch*" } | Select-Object -First 1
$inbox = $store.Folders | Where-Object { $_.Name -eq 'Inbox' }

# ── CONNECT EXCEL ─────────────────────────────────────────────────────────────

if (-not (Test-Path $WorkbookPath)) { throw "Workbook not found: $WorkbookPath" }

$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false; $excel.DisplayAlerts = $false

$foldersCreated = 0
$mappingsAdded  = 0
$skipped        = 0

try {
    $wb    = $excel.Workbooks.Open($WorkbookPath)
    $table = $null
    foreach ($sheet in $wb.Sheets) {
        $found = $sheet.ListObjects | Where-Object { $_.Name -eq 'DomainMappings' }
        if ($found) { $table = $found; break }
    }
    if (-not $table) { throw "Table 'DomainMappings' not found in workbook." }

    # Read header column positions
    $headers = @{}
    for ($c = 1; $c -le $table.HeaderRowRange.Columns.Count; $c++) {
        $headers[$table.HeaderRowRange.Cells.Item(1, $c).Value2] = $c
    }

    # Read existing mapped domains to avoid duplicates
    $existingDomains = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($row in $table.DataBodyRange.Rows) {
        $d = $row.Cells.Item(1, $headers['Domain']).Value2
        if ($d) { $existingDomains.Add($d.Trim()) | Out-Null }
    }

    foreach ($row in $rows) {
        $domain      = $row.Domain.Trim().ToLower()
        $folderName  = $row.FolderName.Trim()
        $category    = $row.Category.Trim()
        $parentPath  = if ($row.ParentPath -and $row.ParentPath.Trim() -ne '') {
                           $row.ParentPath.Trim()
                       } else { $null }
        $active      = if ($row.Active -and $row.Active.Trim() -ne '') { $row.Active.Trim() } else { 'Yes' }
        $effectivePath = if ($parentPath) { $parentPath } else { "_$category" }

        Write-Host "`n[$domain]" -ForegroundColor Yellow
        Write-Host "  Folder : Inbox\$effectivePath\$folderName"

        # ── Create folder if missing ──────────────────────────────────────────
        $parentFolder = Resolve-FolderPath -BaseFolder $inbox -Path $effectivePath

        if (-not $parentFolder) {
            Write-Warning "  Parent path not found: Inbox\$effectivePath — skipping."
            $skipped++
            continue
        }

        $targetFolder = $parentFolder.Folders | Where-Object { $_.Name -eq $folderName }

        if (-not $targetFolder) {
            if ($PSCmdlet.ShouldProcess("Inbox\$effectivePath\$folderName", 'Create folder')) {
                $targetFolder = $parentFolder.Folders.Add($folderName)
                Write-Host "  Created folder." -ForegroundColor Green
                $foldersCreated++
            }
        } else {
            Write-Host "  Folder already exists." -ForegroundColor DarkGray
        }

        # ── Add mapping to workbook ───────────────────────────────────────────
        if ($existingDomains.Contains($domain)) {
            Write-Host "  Mapping already exists in workbook — skipping." -ForegroundColor DarkGray
            continue
        }

        if ($PSCmdlet.ShouldProcess($domain, 'Add mapping to workbook')) {
            $newRow = $table.ListRows.Add()
            $newRow.Range.Cells.Item(1, $headers['Domain'])     = $domain
            $newRow.Range.Cells.Item(1, $headers['FolderName']) = $folderName
            $newRow.Range.Cells.Item(1, $headers['Category'])   = $category
            $newRow.Range.Cells.Item(1, $headers['Active'])     = $active

            if ($headers.ContainsKey('ParentPath') -and $parentPath) {
                $newRow.Range.Cells.Item(1, $headers['ParentPath']) = $parentPath
            }
            if ($headers.ContainsKey('EmailCount') -and $row.EmailCount) {
                $newRow.Range.Cells.Item(1, $headers['EmailCount']) = [int]$row.EmailCount
            }

            $existingDomains.Add($domain) | Out-Null
            Write-Host "  Mapping added." -ForegroundColor Green
            $mappingsAdded++
        }
    }

    if ($PSCmdlet.ShouldProcess($WorkbookPath, 'Save workbook')) {
        $wb.Save()
    }

} finally {
    if ($wb) { $wb.Close($false) }
    $excel.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
    [System.GC]::Collect()
}

Write-Host "`n── Summary ───────────────────────────────────────────" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "  *** DRY RUN — nothing was created or saved ***" -ForegroundColor Yellow
}
Write-Host "  Folders created  : $foldersCreated"
Write-Host "  Mappings added   : $mappingsAdded"
Write-Host "  Skipped          : $skipped"
Write-Host ""
