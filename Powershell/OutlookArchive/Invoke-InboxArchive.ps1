#Requires -Version 5.1
<#
.SYNOPSIS
    Moves Inbox emails older than $ArchiveAfterDays to their mapped folder
    based on sender domain, using InboxRouting.xlsx as the rule source.

.PARAMETER WhatIf
    Show what would be moved without moving anything.

.PARAMETER Confirm
    Prompt before each move.

.EXAMPLE
    # Dry run — see what would move
    .\Invoke-InboxArchive.ps1 -WhatIf

    # Live run
    .\Invoke-InboxArchive.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param()

# ── CONFIG ────────────────────────────────────────────────────────────────────

$MailboxMatch    = 'ray.slater@capconnect'
$WorkbookPath    = Join-Path $PSScriptRoot 'InboxRouting.xlsx'
$ArchiveAfterDays = 14

# ── END CONFIG ────────────────────────────────────────────────────────────────

function Get-MailboxStore {
    param([object]$Namespace, [string]$MatchString)
    $store = $Namespace.Folders | Where-Object { $_.Name -like "*$MatchString*" } | Select-Object -First 1
    if (-not $store) {
        $available = ($Namespace.Folders | Select-Object -ExpandProperty Name) -join ', '
        throw "No store matching '$MatchString'. Available: $available"
    }
    return $store
}

function Get-SmtpDomain {
    param([object]$MailItem)
    try {
        $email = $null

        if ($MailItem.SenderEmailType -eq 'EX') {
            # Try Exchange user object first
            try {
                $exchUser = $MailItem.Sender.GetExchangeUser()
                if ($exchUser) { $email = $exchUser.PrimarySmtpAddress }
            } catch { }

            # Fallback: PropertyAccessor reads PR_SENDER_SMTP_ADDRESS directly from MAPI.
            # Works for internal Exchange accounts where GetExchangeUser() fails or returns null.
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

        if ($email -and $email -like '*@*') {
            return $email.ToLower().Trim()
        }
    } catch { }
    return $null
}

function Get-RecipientSmtpAddress {
    param([object]$Recipient)
    try {
        $addr = $Recipient.Address

        if ($addr -like '/O=*') {
            # Exchange internal DN — resolve via AddressEntry
            $email = $null
            try {
                $exchUser = $Recipient.AddressEntry.GetExchangeUser()
                if ($exchUser) { $email = $exchUser.PrimarySmtpAddress }
            } catch { }

            # Fallback: PR_SMTP_ADDRESS on the recipient object
            if (-not $email) {
                try {
                    $email = $Recipient.PropertyAccessor.GetProperty(
                        'http://schemas.microsoft.com/mapi/proptag/0x39FE001E'
                    )
                } catch { }
            }
            $addr = $email
        }

        if ($addr -and $addr -like '*@*') {
            return $addr.ToLower().Trim()
        }
    } catch { }
    return $null
}

function Resolve-FolderPath {
    <# Navigates a backslash-delimited path from a base Outlook folder. #>
    param([object]$BaseFolder, [string]$Path)
    $current = $BaseFolder
    foreach ($part in ($Path -split '\\')) {
        $current = $current.Folders | Where-Object { $_.Name.Trim() -eq $part.Trim() }
        if (-not $current) { return $null }
    }
    return $current
}

function Read-DomainMappings {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Workbook not found: $Path"
    }

    $excel = New-Object -ComObject Excel.Application
    $excel.Visible       = $false
    $excel.DisplayAlerts = $false
    $mappings            = @{}

    try {
        $wb = $excel.Workbooks.Open($Path)

        $table = $null
        foreach ($sheet in $wb.Sheets) {
            $found = $sheet.ListObjects | Where-Object { $_.Name -eq 'DomainMappings' }
            if ($found) { $table = $found; break }
        }
        if (-not $table) { throw "Table 'DomainMappings' not found in $Path" }

        # Read column positions from header row
        $headers = @{}
        $colCount = $table.HeaderRowRange.Columns.Count
        for ($c = 1; $c -le $colCount; $c++) {
            $headers[$table.HeaderRowRange.Cells.Item(1, $c).Value2] = $c
        }

        foreach ($row in $table.DataBodyRange.Rows) {
            $active = $row.Cells.Item(1, $headers['Active']).Value2
            if ($active -ne 'Yes') { continue }

            $domain     = $row.Cells.Item(1, $headers['Domain']).Value2
            $folderName = $row.Cells.Item(1, $headers['FolderName']).Value2
            $category   = $row.Cells.Item(1, $headers['Category']).Value2
            $parentPath = if ($headers.ContainsKey('ParentPath')) {
                              $row.Cells.Item(1, $headers['ParentPath']).Value2
                          } else { $null }

            if ($domain -and $folderName) {
                $mappings[$domain.ToLower().Trim()] = [PSCustomObject]@{
                    FolderName = $folderName
                    Category   = $category
                    ParentPath = $parentPath
                }
            }
        }

    } finally {
        if ($wb) { $wb.Close($false) }
        $excel.Quit()
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
        [System.GC]::Collect()
    }

    return $mappings
}

# ── MAIN ──────────────────────────────────────────────────────────────────────

# Load mappings
Write-Host "`nReading domain mappings from workbook..." -ForegroundColor Cyan
$domainMap = Read-DomainMappings -Path $WorkbookPath
Write-Host "  $($domainMap.Count) active mappings loaded."

# Connect to Outlook
Write-Host "Connecting to Outlook..." -ForegroundColor Cyan
$outlook   = New-Object -ComObject Outlook.Application
$namespace = $outlook.GetNamespace('MAPI')
$namespace.Logon()

$store = Get-MailboxStore -Namespace $namespace -MatchString $MailboxMatch
Write-Host "  Using mailbox : $($store.Name)"

$inbox = $store.Folders | Where-Object { $_.Name -eq 'Inbox' }
if (-not $inbox) { throw "Inbox not found in store '$($store.Name)'" }

# Pre-build folder cache: "ParentPath|FolderName" -> Outlook Folder object
$folderCache    = @{}
$uniqueFolders  = $domainMap.Values |
    Select-Object FolderName, Category, ParentPath |
    Sort-Object { "$($_.ParentPath)$($_.Category)|$($_.FolderName)" } -Unique
$folderTotal    = $uniqueFolders.Count
$folderIndex    = 0

foreach ($entry in $uniqueFolders) {
    $folderIndex++

    # Resolve the effective parent path:
    # ParentPath column takes precedence; fall back to _Category for existing rows.
    $effectivePath = if ($entry.ParentPath) { $entry.ParentPath } else { "_$($entry.Category)" }
    $cacheKey      = "$effectivePath|$($entry.FolderName)"

    Write-Progress -Activity 'Building folder cache' `
        -Status "$folderIndex of $folderTotal — $($entry.FolderName)" `
        -PercentComplete (($folderIndex / $folderTotal) * 100)

    if ($folderCache.ContainsKey($cacheKey)) { continue }

    $parentFolder = Resolve-FolderPath -BaseFolder $inbox -Path $effectivePath

    if (-not $parentFolder) {
        Write-Warning "Folder path not found: Inbox\$effectivePath — skipping '$($entry.FolderName)'."
        continue
    }

    $targetFolder = $parentFolder.Folders | Where-Object { $_.Name -eq $entry.FolderName }
    if (-not $targetFolder) {
        Write-Warning "Subfolder not found: Inbox\$effectivePath\$($entry.FolderName) — skipping."
        continue
    }

    $folderCache[$cacheKey] = $targetFolder
}

Write-Progress -Activity 'Building folder cache' -Completed
Write-Host "Folder cache    : $($folderCache.Count) folders" -ForegroundColor Cyan

# Restrict inbox to emails older than threshold
$cutoff    = (Get-Date).AddDays(-$ArchiveAfterDays)
$cutoffStr = $cutoff.ToString('g', [System.Globalization.CultureInfo]::CurrentCulture)
$filter    = "[MessageClass] = 'IPM.Note' AND [ReceivedTime] <= '$cutoffStr'"
$restricted = $inbox.Items.Restrict($filter)

Write-Host "`nInbox items older than $ArchiveAfterDays days: $($restricted.Count)" -ForegroundColor Cyan

# Collect items first — modifying a live collection while iterating causes skips
$mailItems = [System.Collections.Generic.List[object]]::new()
$total     = $restricted.Count
for ($i = 1; $i -le $total; $i++) {
    $item = $restricted.Item($i)
    if ($item.Class -eq 43) { $mailItems.Add($item) }
}
Write-Host "Mail items to evaluate: $($mailItems.Count)"

# Process
$moved      = 0
$skipped    = 0
$noMatch    = 0
$emailTotal = $mailItems.Count
$emailIndex = 0

foreach ($item in $mailItems) {
    $emailIndex++
    Write-Progress -Activity 'Archiving inbox' `
        -Status "Moved: $moved  |  No match: $noMatch  |  Item $emailIndex of $emailTotal" `
        -PercentComplete (($emailIndex / $emailTotal) * 100)

    $email  = Get-SmtpDomain -MailItem $item

    if (-not $email) {
        $skipped++
        continue
    }

    $domain  = $email.Split('@')[1]
    $mapping = $domainMap[$email] ?? $domainMap[$domain]

    # No sender match — check CC recipients
    if (-not $mapping) {
        foreach ($recipient in $item.Recipients) {
            if ($recipient.Type -ne 2) { continue }  # 2 = olCC
            $ccEmail = Get-RecipientSmtpAddress -Recipient $recipient
            if (-not $ccEmail) { continue }
            $ccDomain = $ccEmail.Split('@')[1]
            $mapping  = $domainMap[$ccEmail] ?? $domainMap[$ccDomain]
            if ($mapping) { $email = $ccEmail; break }
        }
    }

    if (-not $mapping) {
        $noMatch++
        continue
    }

    $effectivePath = if ($mapping.ParentPath) { $mapping.ParentPath } else { "_$($mapping.Category)" }
    $cacheKey      = "$effectivePath|$($mapping.FolderName)"
    $targetFolder  = $folderCache[$cacheKey]

    if (-not $targetFolder) {
        Write-Warning "No cached folder for key '$cacheKey' — skipping '$($item.Subject)'"
        $skipped++
        continue
    }

    $action = "Move to $effectivePath\$($mapping.FolderName)"
    $target = "'$($item.Subject)' [from: $email]"

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        $item.Move($targetFolder) | Out-Null
        $moved++
    }
}

Write-Progress -Activity 'Archiving inbox' -Completed

# Summary
Write-Host "`n── Summary ───────────────────────────────────────────" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "  *** DRY RUN — nothing was moved ***" -ForegroundColor Yellow
}
Write-Host "  Moved           : $moved"
Write-Host "  No match (left) : $noMatch"
Write-Host "  Skipped (error) : $skipped"
Write-Host "  Evaluated       : $($mailItems.Count)"
Write-Host ""
