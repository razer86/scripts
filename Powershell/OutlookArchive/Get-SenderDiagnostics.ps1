#Requires -Version 5.1
<#
.SYNOPSIS
    Samples skipped inbox items to diagnose why Get-SmtpDomain is failing.
    Run this to understand sender address patterns before fixing the archive script.
#>

# ── CONFIG ────────────────────────────────────────────────────────────────────

$MailboxMatch     = 'ray.slater@capconnect'
$ArchiveAfterDays = 30
$SampleSize       = 50   # how many skipped items to inspect

# ── END CONFIG ────────────────────────────────────────────────────────────────

$outlook   = New-Object -ComObject Outlook.Application
$namespace = $outlook.GetNamespace('MAPI')
$namespace.Logon()

$store = $namespace.Folders | Where-Object { $_.Name -like "*$MailboxMatch*" } | Select-Object -First 1
$inbox = $store.Folders | Where-Object { $_.Name -eq 'Inbox' }

$cutoff    = (Get-Date).AddDays(-$ArchiveAfterDays)
$filter    = "[MessageClass] = 'IPM.Note' AND [ReceivedTime] <= '" + $cutoff.ToString('MM/dd/yyyy HH:mm') + "'"
$restricted = $inbox.Items.Restrict($filter)

$results  = [System.Collections.Generic.List[PSCustomObject]]::new()
$sampled  = 0
$total    = $restricted.Count

for ($i = 1; $i -le $total -and $sampled -lt $SampleSize; $i++) {
    $item = $restricted.Item($i)
    if ($item.Class -ne 43) { continue }

    $senderType    = $item.SenderEmailType
    $senderAddress = $item.SenderEmailAddress
    $senderName    = $item.SenderName
    $exchUser      = $null
    $exchSmtp      = $null
    $exchError     = $null
    $propSmtp      = $null
    $propError     = $null

    # Try Exchange resolution
    if ($senderType -eq 'EX') {
        try {
            $exchUser = $item.Sender.GetExchangeUser()
            if ($exchUser) { $exchSmtp = $exchUser.PrimarySmtpAddress }
        } catch {
            $exchError = $_.Exception.Message
        }
    }

    # Try PropertyAccessor for PR_SENDER_SMTP_ADDRESS (works for all types)
    try {
        $propSmtp = $item.PropertyAccessor.GetProperty('http://schemas.microsoft.com/mapi/proptag/0x5D01001E')
    } catch {
        $propError = $_.Exception.Message
    }

    # Only capture rows where normal resolution would have returned null
    $wouldSkip = -not (
        ($senderType -ne 'EX' -and $senderAddress -like '*@*') -or
        ($senderType -eq 'EX' -and $exchSmtp)
    )

    if (-not $wouldSkip) { continue }

    $results.Add([PSCustomObject]@{
        SenderType    = $senderType
        SenderAddress = $senderAddress
        SenderName    = $senderName
        ExchSmtp      = $exchSmtp
        ExchError     = $exchError
        PropSmtp      = $propSmtp
        PropError     = $propError
        Subject       = $item.Subject.Substring(0, [Math]::Min(40, $item.Subject.Length))
    })

    $sampled++
}

Write-Host "`n── Sender Type Breakdown (sampled $sampled skipped items) ──" -ForegroundColor Cyan
$results | Group-Object SenderType | Sort-Object Count -Descending |
    Select-Object Name, Count | Format-Table -AutoSize

Write-Host "── PropertyAccessor SMTP resolution ──" -ForegroundColor Cyan
$results | Group-Object { if ($_.PropSmtp) { 'Resolved' } else { 'Failed' } } |
    Select-Object Name, Count | Format-Table -AutoSize

Write-Host "── Sample rows ──" -ForegroundColor Cyan
$results | Select-Object SenderType, SenderAddress, PropSmtp, ExchError, PropError, Subject |
    Format-Table -AutoSize -Wrap
