<#
.SYNOPSIS
    Checks all mailboxes to see where the specified user has delegated access.
.AUTHOR
    Raymond Slater
.VERSION
    1.0 - 2025-06-27
.LINK
    https://github.com/razer86/scripts
#>

param (
    [Parameter(Mandatory)]
    [string]$UPN
)

# Connect to Exchange Online if not already connected
if (-not (Get-PSSession | Where-Object { $_.ComputerName -like '*outlook.office365.com*' })) {
    Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan
    Connect-ExchangeOnline -ErrorAction Stop
}

$results = @()

# Get all mailboxes
$mailboxes = Get-Mailbox -ResultSize Unlimited

# === Full Access ===
foreach ($mbx in $mailboxes) {
    $perms = Get-MailboxPermission -Identity $mbx.Identity -ErrorAction SilentlyContinue | Where-Object {
        $_.User -eq $UPN -and $_.IsInherited -eq $false -and $_.AccessRights -contains 'FullAccess'
    }
    foreach ($p in $perms) {
        $results += [pscustomobject]@{
            Mailbox      = $mbx.PrimarySmtpAddress
            AccessType   = "FullAccess"
        }
    }
}

# === Send As ===
foreach ($mbx in $mailboxes) {
    $sendAs = Get-RecipientPermission -Identity $mbx.Identity -ErrorAction SilentlyContinue | Where-Object {
        $_.Trustee -eq $UPN -and $_.AccessRights -contains 'SendAs'
    }
    foreach ($s in $sendAs) {
        $results += [pscustomobject]@{
            Mailbox    = $mbx.PrimarySmtpAddress
            AccessType = "SendAs"
        }
    }
}

# === Send on Behalf ===
foreach ($mbx in $mailboxes) {
    if ($mbx.GrantSendOnBehalfTo -contains $UPN) {
        $results += [pscustomobject]@{
            Mailbox    = $mbx.PrimarySmtpAddress
            AccessType = "SendOnBehalf"
        }
    }
}

# Output results
if ($results.Count -eq 0) {
    Write-Host "No mailbox access found for $UPN" -ForegroundColor Yellow
} else {
    $results | Sort-Object Mailbox, AccessType | Format-Table -AutoSize
}
