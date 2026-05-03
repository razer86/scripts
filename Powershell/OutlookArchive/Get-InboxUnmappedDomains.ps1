#Requires -Version 5.1
<#
.SYNOPSIS
    Scans remaining Inbox emails and reports domains not yet in DomainMappings.
    Output CSV is designed to be filled in and passed to Add-DomainMappings.ps1.

.OUTPUTS
    <ScriptRoot>\UnmappedDomains.csv
#>

# ── CONFIG ────────────────────────────────────────────────────────────────────

$MailboxMatch = 'ray.slater@capconnect'
$WorkbookPath = Join-Path $PSScriptRoot 'InboxRouting.xlsx'

$ExcludeDomains = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
@(
    'capconnect.com.au'; 'neconnect.com.au'
    'gmail.com'; 'bigpond.com'; 'bigpond.net.au'
    'hotmail.com'; 'outlook.com'; 'outlook.com.au'
    'icloud.com'; 'yahoo.com.au'; 'yahoo.com'
    'me.com'; 'ozemail.com.au'; 'optusnet.com.au'
    'westnet.com.au'; 'eftel.net.au'; 'eftel.com.au'
    'dreamtilt.com.au'; 'nqbe.com.au'; 'widebayit.com.au'
    'microsoft.com'; 'messaging.microsoft.com'
    'ringcentral.com'; 'jotform.com'
    'localsearch.com.au'; 'netregistry.com.au'
    'team.telstra.com'; 'sophos.com'
) | ForEach-Object { $ExcludeDomains.Add($_) | Out-Null }

# ── END CONFIG ────────────────────────────────────────────────────────────────

function Get-SmtpAddress {
    param([object]$MailItem)
    try {
        $email = $null
        if ($MailItem.SenderEmailType -eq 'EX') {
            try {
                $exchUser = $MailItem.Sender.GetExchangeUser()
                if ($exchUser) { $email = $exchUser.PrimarySmtpAddress }
            } catch { }
            if (-not $email) {
                try {
                    $email = $MailItem.PropertyAccessor.GetProperty(
                        'http://schemas.microsoft.com/mapi/proptag/0x5D01001E'
                    )
                } catch { }
            }
        } else {
            $email = $MailItem.SenderEmailAddress
        }
        if ($email -and $email -like '*@*') { return $email.ToLower().Trim() }
    } catch { }
    return $null
}

# ── LOAD EXISTING MAPPINGS ────────────────────────────────────────────────────

Write-Host "`nReading existing mappings from workbook..." -ForegroundColor Cyan
$mappedDomains = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

if (Test-Path $WorkbookPath) {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false; $excel.DisplayAlerts = $false
    try {
        $wb    = $excel.Workbooks.Open($WorkbookPath)
        $table = $null
        foreach ($sheet in $wb.Sheets) {
            $found = $sheet.ListObjects | Where-Object { $_.Name -eq 'DomainMappings' }
            if ($found) { $table = $found; break }
        }
        if ($table) {
            $headers = @{}
            for ($c = 1; $c -le $table.HeaderRowRange.Columns.Count; $c++) {
                $headers[$table.HeaderRowRange.Cells.Item(1, $c).Value2] = $c
            }
            foreach ($row in $table.DataBodyRange.Rows) {
                $domain = $row.Cells.Item(1, $headers['Domain']).Value2
                if ($domain) { $mappedDomains.Add($domain.ToLower().Trim()) | Out-Null }
            }
        }
    } finally {
        if ($wb) { $wb.Close($false) }
        $excel.Quit()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
        [System.GC]::Collect()
    }
    Write-Host "  $($mappedDomains.Count) already-mapped domains loaded."
} else {
    Write-Warning "Workbook not found — all domains will be included."
}

# ── SCAN INBOX ────────────────────────────────────────────────────────────────

Write-Host "Connecting to Outlook..." -ForegroundColor Cyan
$outlook   = New-Object -ComObject Outlook.Application
$namespace = $outlook.GetNamespace('MAPI')
$namespace.Logon()

$store = $namespace.Folders | Where-Object { $_.Name -like "*$MailboxMatch*" } | Select-Object -First 1
$inbox = $store.Folders | Where-Object { $_.Name -eq 'Inbox' }

# Restrict to mail items only — no date filter, we want to see everything remaining
$filter     = "[MessageClass] = 'IPM.Note'"
$restricted = $inbox.Items.Restrict($filter)
$total      = $restricted.Count

Write-Host "Inbox items to scan: $total" -ForegroundColor Cyan

$domainCounts = @{}
for ($i = 1; $i -le $total; $i++) {
    Write-Progress -Activity 'Scanning Inbox' `
        -Status "Item $i of $total" `
        -PercentComplete (($i / $total) * 100)

    $item  = $restricted.Item($i)
    $email = Get-SmtpAddress -MailItem $item
    if (-not $email) { continue }

    $domain = $email.Split('@')[1]
    if ($ExcludeDomains.Contains($domain))  { continue }
    if ($mappedDomains.Contains($domain))    { continue }
    if ($mappedDomains.Contains($email))     { continue }

    if ($domainCounts.ContainsKey($domain)) { $domainCounts[$domain]++ }
    else                                    { $domainCounts[$domain] = 1 }
}

Write-Progress -Activity 'Scanning Inbox' -Completed

# ── EXPORT ────────────────────────────────────────────────────────────────────

$outputPath = Join-Path $PSScriptRoot 'UnmappedDomains.csv'

$domainCounts.GetEnumerator() |
    Sort-Object Value -Descending |
    ForEach-Object {
        [PSCustomObject]@{
            Domain     = $_.Key
            EmailCount = $_.Value
            FolderName = ''
            Category   = ''
            ParentPath = ''
            Active     = 'Yes'
        }
    } |
    Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8

Write-Host "`n── Summary ───────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Unmapped domains : $($domainCounts.Count)"
Write-Host "  Output           : $outputPath"
Write-Host ""
Write-Host "Fill in FolderName, Category and optionally ParentPath for domains" -ForegroundColor Yellow
Write-Host "you want to action, then run Add-DomainMappings.ps1." -ForegroundColor Yellow
Write-Host ""
