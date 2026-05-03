#Requires -Version 5.1
<#
.SYNOPSIS
    Moves emails in the rc@neconnect.com.au Inbox to their mapped
    Inbox\<Branch>\<Company> folder based on the rc+<tag> recipient address,
    using RCMappings.csv as the rule source.

.PARAMETER WhatIf
    Show what would be moved without moving anything.

.PARAMETER Confirm
    Prompt before each move.

.EXAMPLE
    .\Invoke-RCInboxArchive.ps1 -WhatIf
    .\Invoke-RCInboxArchive.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
param()

# ── CONFIG ────────────────────────────────────────────────────────────────────

$MailboxMatch        = 'rc@neconnect.com.au'
$RCDomain            = 'neconnect.com.au'
$MappingsPath        = Join-Path $PSScriptRoot 'RCMappings.csv'
$ArchiveAfterDays    = 14

# Emails addressed to this many or more rc+ addresses are treated as broadcasts.
# RingCentral product updates go to every account at once.
$BroadcastThreshold  = 10
$BroadcastFolder     = '_RC'   # relative to Inbox — created if missing

# Set to $true for the initial backlog cleanup when the shared mailbox is not
# fully cached locally. Iterates every item individually (slower but complete).
# Leave $false for normal scheduled runs — Restrict() is fast enough once the
# backlog is cleared.
$FullScan            = $false

# ── END CONFIG ────────────────────────────────────────────────────────────────

function Resolve-FolderPath {
    param([object]$BaseFolder, [string]$Path)
    $current = $BaseFolder
    foreach ($part in ($Path -split '\\')) {
        $current = $current.Folders | Where-Object { $_.Name.Trim() -eq $part.Trim() }
        if (-not $current) { return $null }
    }
    return $current
}

function New-OutlookFolderPath {
    <# Walks the path and creates any missing folders along the way. #>
    param([object]$BaseFolder, [string]$Path)
    $current = $BaseFolder
    foreach ($part in ($Path -split '\\')) {
        $existing = $current.Folders | Where-Object { $_.Name.Trim() -eq $part.Trim() }
        $current  = if ($existing) { $existing } else { $current.Folders.Add($part.Trim()) }
    }
    return $current
}

function Get-RCRecipientAddresses {
    <#
        Finds rc+*@domain addresses by reading the raw SMTP transport headers
        (PR_TRANSPORT_MESSAGE_HEADERS). Exchange Online normalises plus-addressed
        recipients in the Recipients collection to the base mailbox, so the
        tagged address only survives reliably in the original headers.
        Falls back to walking Recipients if headers are unavailable.
        Wrap the call in @() to always get an array back.
    #>
    param([object]$MailItem, [string]$Domain)

    # Primary: parse raw transport headers.
    # Try ANSI tag (001E) first; fall back to Unicode (001F) for EXO tenants
    # that store the property as wide string.
    try {
        $pa      = $MailItem.PropertyAccessor
        $headers = $null
        try   { $headers = $pa.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x007D001E') } catch { }
        if (-not $headers) {
            try { $headers = $pa.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x007D001F') } catch { }
        }
        if ($headers) {
            $pattern  = "rc\+[^@\s<>`"]+@$([regex]::Escape($Domain))"
            $matches  = [regex]::Matches($headers, $pattern, 'IgnoreCase')
            if ($matches.Count -gt 0) {
                $matches | ForEach-Object { $_.Value.ToLower().Trim() } | Select-Object -Unique
                return
            }
        }
    } catch { }

    # Fallback: walk Recipients collection
    foreach ($recipient in $MailItem.Recipients) {
        try {
            $addr = $recipient.Address
            if ($addr -like '/O=*') {
                $email = $null
                try {
                    $exchUser = $recipient.AddressEntry.GetExchangeUser()
                    if ($exchUser) { $email = $exchUser.PrimarySmtpAddress }
                } catch { }
                if (-not $email) {
                    try {
                        $email = $recipient.PropertyAccessor.GetProperty(
                            'http://schemas.microsoft.com/mapi/proptag/0x39FE001E'
                        )
                    } catch { }
                }
                $addr = $email
            }
            if ($addr -and $addr -like "*+*@$Domain") {
                $addr.ToLower().Trim()
            }
        } catch { }
    }
}

# ── LOAD MAPPINGS ─────────────────────────────────────────────────────────────

if (-not (Test-Path $MappingsPath)) { throw "Mappings CSV not found: $MappingsPath" }

$csv       = Import-Csv $MappingsPath | Where-Object { $_.ToAddress -and $_.ToAddress.Trim() -ne '' }
$mappings  = @{}

foreach ($row in $csv) {
    $key  = $row.ToAddress.ToLower().Trim()
    $path = "$($row.Branch.Trim())\$($row.Company.Trim())"
    $mappings[$key] = $path
}

Write-Host "`n$($mappings.Count) active mappings loaded from CSV." -ForegroundColor Cyan

# ── CONNECT ───────────────────────────────────────────────────────────────────

Write-Host "Connecting to Outlook..." -ForegroundColor Cyan
$outlook   = New-Object -ComObject Outlook.Application
$namespace = $outlook.GetNamespace('MAPI')
$namespace.Logon()

$store = $namespace.Folders | Where-Object { $_.Name -like "*$MailboxMatch*" } | Select-Object -First 1
if (-not $store) {
    $available = ($namespace.Folders | Select-Object -ExpandProperty Name) -join ', '
    throw "No store matching '$MailboxMatch'. Available: $available"
}
Write-Host "  Using mailbox : $($store.Name)" -ForegroundColor Green

$inbox = $store.Folders | Where-Object { $_.Name -eq 'Inbox' }
if (-not $inbox) { throw "Inbox not found in store '$($store.Name)'" }

# ── BUILD FOLDER CACHE ────────────────────────────────────────────────────────

$folderCache  = @{}
$uniquePaths  = $mappings.Values | Select-Object -Unique | Sort-Object
$folderTotal  = $uniquePaths.Count
$folderIndex  = 0

foreach ($path in $uniquePaths) {
    $folderIndex++
    Write-Progress -Activity 'Building folder cache' `
        -Status "$folderIndex of $folderTotal — $path" `
        -PercentComplete (($folderIndex / $folderTotal) * 100)

    $folder = Resolve-FolderPath -BaseFolder $inbox -Path $path

    if (-not $folder) {
        if ($PSCmdlet.ShouldProcess("Inbox\$path", 'Create missing folder')) {
            $folder = New-OutlookFolderPath -BaseFolder $inbox -Path $path
            Write-Host "  Created : Inbox\$path" -ForegroundColor Green
        }
    }

    if ($folder) { $folderCache[$path] = $folder }
}

Write-Progress -Activity 'Building folder cache' -Completed
Write-Host "Folder cache    : $($folderCache.Count) folders" -ForegroundColor Cyan

# Resolve/create the broadcast holding folder
$rcBroadcastFolder = Resolve-FolderPath -BaseFolder $inbox -Path $BroadcastFolder
if (-not $rcBroadcastFolder) {
    if ($PSCmdlet.ShouldProcess("Inbox\$BroadcastFolder", 'Create broadcast folder')) {
        $rcBroadcastFolder = New-OutlookFolderPath -BaseFolder $inbox -Path $BroadcastFolder
        Write-Host "  Created : Inbox\$BroadcastFolder" -ForegroundColor Green
    }
}
Write-Host "Broadcast folder: Inbox\$BroadcastFolder" -ForegroundColor Cyan

# ── COLLECT INBOX ITEMS ───────────────────────────────────────────────────────
# Store EntryIDs (strings) rather than live COM objects so Exchange's open-item
# MAPI throttle is never hit. Items are fetched one at a time during processing
# and released immediately after, keeping only one item open at a time.

$cutoff    = (Get-Date).AddDays(-$ArchiveAfterDays)
$cutoffStr = $cutoff.ToString('g', [System.Globalization.CultureInfo]::CurrentCulture)
$storeID   = $store.StoreID

$entryIDs = [System.Collections.Generic.List[string]]::new()

if ($FullScan) {
    $allItems = $inbox.Items
    $totalAll = $allItems.Count
    Write-Host "`nFull scan — total inbox items: $totalAll" -ForegroundColor Cyan
    for ($i = 1; $i -le $totalAll; $i++) {
        if ($i % 200 -eq 0) {
            Write-Progress -Activity 'Loading inbox items' `
                -Status "Scanned $i of $totalAll — eligible: $($entryIDs.Count)" `
                -PercentComplete (($i / $totalAll) * 100)
        }
        $item = $allItems.Item($i)
        $keep = ($item.Class -eq 43 -and $item.ReceivedTime -le $cutoff)
        if ($keep) { $entryIDs.Add($item.EntryID) }
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($item) | Out-Null
    }
    Write-Progress -Activity 'Loading inbox items' -Completed
} else {
    $filter     = "[MessageClass] = 'IPM.Note' AND [ReceivedTime] <= '$cutoffStr'"
    $restricted = $inbox.Items.Restrict($filter)
    Write-Host "`nInbox items older than $ArchiveAfterDays days: $($restricted.Count)" -ForegroundColor Cyan
    $total = $restricted.Count
    for ($i = 1; $i -le $total; $i++) {
        $item = $restricted.Item($i)
        if ($item.Class -eq 43) { $entryIDs.Add($item.EntryID) }
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($item) | Out-Null
    }
}

Write-Host "Mail items to evaluate: $($entryIDs.Count)" -ForegroundColor Cyan

# ── PROCESS ───────────────────────────────────────────────────────────────────

$moved          = 0
$skipped        = 0
$noMatch        = 0
$broadcast      = 0
$emailTotal     = $entryIDs.Count
$emailIndex     = 0
$noRCLog        = [System.Collections.Generic.List[string]]::new()
$noMatchLog     = @{}

foreach ($entryID in $entryIDs) {
    $emailIndex++
    Write-Progress -Activity 'Archiving RC inbox' `
        -Status "Moved: $moved  |  Broadcast: $broadcast  |  Item $emailIndex of $emailTotal" `
        -PercentComplete (($emailIndex / $emailTotal) * 100)

    $item = $namespace.GetItemFromID($entryID, $storeID)

    $rcAddrs = @(Get-RCRecipientAddresses -MailItem $item -Domain $RCDomain)

    if ($rcAddrs.Count -eq 0) {
        $skipped++
        $noRCLog.Add($item.Subject)
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($item) | Out-Null
        continue
    }

    # More rc+ addresses than the threshold = broadcast — move to holding folder
    if ($rcAddrs.Count -ge $BroadcastThreshold) {
        if ($rcBroadcastFolder -and $PSCmdlet.ShouldProcess(
                "'$($item.Subject)' [$($rcAddrs.Count) rc+ recipients]",
                "Move to Inbox\$BroadcastFolder")) {
            $item.Move($rcBroadcastFolder) | Out-Null
        }
        $broadcast++
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($item) | Out-Null
        continue
    }

    $rcAddr     = $rcAddrs[0]
    $folderPath = $mappings[$rcAddr]
    if (-not $folderPath) {
        $noMatch++
        $noMatchLog[$rcAddr] = ($noMatchLog[$rcAddr] ?? 0) + 1
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($item) | Out-Null
        continue
    }

    $targetFolder = $folderCache[$folderPath]
    if (-not $targetFolder) {
        Write-Warning "No cached folder for '$folderPath' — skipping '$($item.Subject)'"
        $skipped++
        $noRCLog.Add("[$folderPath] $($item.Subject)")
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($item) | Out-Null
        continue
    }

    $action = "Move to Inbox\$folderPath"
    $target = "'$($item.Subject)' [to: $rcAddr]"

    if ($PSCmdlet.ShouldProcess($target, $action)) {
        $item.Move($targetFolder) | Out-Null
        $moved++
    }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($item) | Out-Null
}

Write-Progress -Activity 'Archiving RC inbox' -Completed

# ── SUMMARY ───────────────────────────────────────────────────────────────────

Write-Host "`n── Summary ───────────────────────────────────────────" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "  *** DRY RUN — nothing was moved ***" -ForegroundColor Yellow
}
Write-Host "  Moved           : $moved"
Write-Host "  Broadcast (left): $broadcast"
Write-Host "  No match (left) : $noMatch"
Write-Host "  Skipped         : $skipped"
Write-Host "  Evaluated       : $($entryIDs.Count)"

if ($noMatchLog.Count -gt 0) {
    Write-Host "`n── No match — rc+ addresses not in CSV ───────────────" -ForegroundColor Yellow
    $noMatchLog.GetEnumerator() | Sort-Object Value -Descending |
        ForEach-Object { Write-Host "  $($_.Value.ToString().PadLeft(4))x  $($_.Key)" }
}

if ($noRCLog.Count -gt 0) {
    Write-Host "`n── Skipped — no rc+ address found (first 20) ─────────" -ForegroundColor DarkYellow
    $noRCLog | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
    if ($noRCLog.Count -gt 20) {
        Write-Host "  ... and $($noRCLog.Count - 20) more"
    }
}

Write-Host ""
