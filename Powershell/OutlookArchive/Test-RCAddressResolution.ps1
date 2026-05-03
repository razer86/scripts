#Requires -Version 5.1
<#
.SYNOPSIS
    Scans the first 100 Inbox emails in the RC mailbox and reports what
    rc+ addresses (if any) are resolved for each, and which method found them.
#>

$MailboxMatch = 'rc@neconnect.com.au'
$RCDomain     = 'neconnect.com.au'
$SampleSize   = 100

# ── CONNECT ───────────────────────────────────────────────────────────────────

$outlook   = New-Object -ComObject Outlook.Application
$namespace = $outlook.GetNamespace('MAPI')
$namespace.Logon()

$store = $namespace.Folders | Where-Object { $_.Name -like "*$MailboxMatch*" } | Select-Object -First 1
$inbox = $store.Folders | Where-Object { $_.Name -eq 'Inbox' }

# ── SCAN ──────────────────────────────────────────────────────────────────────

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$total   = [Math]::Min($SampleSize, $inbox.Items.Count)
$pattern = "rc\+[^@\s<>`"]+@$([regex]::Escape($RCDomain))"

for ($i = 1; $i -le $total; $i++) {
    $item = $inbox.Items.Item($i)
    if ($item.Class -ne 43) { continue }

    $foundVia    = 'None'
    $rcAddresses = @()

    # Try 1: Transport headers (ANSI tag 001E; Unicode 001F as fallback)
    try {
        $pa      = $item.PropertyAccessor
        $headers = $null
        try   { $headers = $pa.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x007D001E') } catch { }
        if (-not $headers) {
            try { $headers = $pa.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x007D001F') } catch { }
        }
        if ($headers) {
            $m = [regex]::Matches($headers, $pattern, 'IgnoreCase')
            if ($m.Count -gt 0) {
                $rcAddresses = @($m | ForEach-Object { $_.Value.ToLower() } | Select-Object -Unique)
                $foundVia    = 'Headers'
            }
        }
    } catch { }

    # Try 2: Recipients collection
    if ($rcAddresses.Count -eq 0) {
        foreach ($recipient in $item.Recipients) {
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
                if ($addr -and $addr -like "*+*@$RCDomain") {
                    $rcAddresses += $addr.ToLower().Trim()
                    $foundVia     = 'Recipients'
                }
            } catch { }
        }
    }

    $results.Add([PSCustomObject]@{
        Item       = $i
        FoundVia   = $foundVia
        RCAddress  = $rcAddresses -join ' | '
        Subject    = $item.Subject.Substring(0, [Math]::Min(50, $item.Subject.Length))
    })
}

# ── REPORT ────────────────────────────────────────────────────────────────────

Write-Host "`n── Method Breakdown ──────────────────────────────────" -ForegroundColor Cyan
$results | Group-Object FoundVia | Sort-Object Count -Descending |
    Select-Object Name, Count | Format-Table -AutoSize

Write-Host "── Sample — None (first 10) ──────────────────────────" -ForegroundColor Yellow
$results | Where-Object { $_.FoundVia -eq 'None' } | Select-Object -First 10 |
    Select-Object Item, Subject | Format-Table -AutoSize

Write-Host "── Sample — Found (first 10) ─────────────────────────" -ForegroundColor Green
$results | Where-Object { $_.FoundVia -ne 'None' } | Select-Object -First 10 |
    Select-Object Item, FoundVia, RCAddress, Subject | Format-Table -AutoSize -Wrap
