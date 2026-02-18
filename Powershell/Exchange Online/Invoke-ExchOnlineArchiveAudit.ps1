<#
.SYNOPSIS
    Enable in-place archive for mailboxes with less then 25% free

.DESCRIPTION
    Prompt for connection credentials for customer's 365 tenant.
    Scan for all mailboxes and grab quota/used space
    If free space is less than 25%, enable archive

.PARAMETER ParameterName
    Description of a parameter (repeat this for each parameter).

.NOTES
    Additional notes, author name, version, etc.

.LINK
    Related resources or URLs.

#>

# Connect to Exchange Online
Connect-ExchangeOnline

# Function to convert quota/usage string (e.g., "4.3 GB") to bytes for math operations
function ConvertTo-Bytes {
    param (
        [string]$sizeString
    )

    # Use regex to extract the number and the unit (B, KB, MB, GB, TB)
    if ($sizeString -match "([\d\.]+)\s*(B|KB|MB|GB|TB)") {
        $value = [float]$matches[1]
        $unit = $matches[2].ToUpper()

        # Convert based on unit
        switch ($unit) {
            "B"  { return $value }
            "KB" { return $value * 1KB }
            "MB" { return $value * 1MB }
            "GB" { return $value * 1GB }
            "TB" { return $value * 1TB }
        }
    }

    # Return 0 if input can't be parsed
    return 0
}

# Initialize an array to hold log entries for each mailbox
$log = @()

# Get all user mailboxes (UserMailbox type only)
$mailboxes = Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox

# Loop through each mailbox
foreach ($mbx in $mailboxes) {
    $user = $mbx.UserPrincipalName

    # Get mailbox statistics (size, etc.)
    $stats = Get-MailboxStatistics -Identity $user

    # Get mailbox configuration (including quota)
    $mbxDetails = Get-Mailbox -Identity $user

    # Extract size strings (e.g., "3.5 GB")
    $quotaStr = $mbxDetails.ProhibitSendQuota.ToString()
    $usedStr = $stats.TotalItemSize.ToString()

    # Convert to bytes for calculation
    $quotaBytes = ConvertTo-Bytes $quotaStr
    $usedBytes = ConvertTo-Bytes $usedStr

    # If quota couldn't be parsed, log and skip
    if ($quotaBytes -eq 0) {
        $log += [pscustomobject]@{
            User             = $user
            Used             = $usedStr
            Quota            = $quotaStr
            FreePercent      = "N/A"
            ArchiveStatus    = $mbx.ArchiveStatus
            ActionTaken      = "Skipped - Unable to read quota"
        }
        continue
    }

    # Calculate % free space
    $freePercent = (($quotaBytes - $usedBytes) / $quotaBytes) * 100

    # Check if archive is already enabled
    $hasArchive = $mbx.ArchiveStatus -eq "Active"

    # Default action value
    $action = "None"

    # Take action based on free space and archive status
    if ($freePercent -lt 25 -and -not $hasArchive) {
        # If low free space and archive not enabled, enable it
        Enable-Mailbox -Identity $user -Archive
        $action = "Archive Enabled"
    }
    elseif ($hasArchive) {
        # Archive already active
        $action = "Archive Already Enabled"
    }
    else {
        # Enough space, no action needed
        $action = "No Action Needed"
    }

    # Log the results for this mailbox
    $log += [pscustomobject]@{
        User             = $user
        Used             = $usedStr
        Quota            = $quotaStr
        FreePercent      = [math]::Round($freePercent, 2)
        ArchiveStatus    = $mbx.ArchiveStatus
        ActionTaken      = $action
    }
}

# Generate timestamped filename for the CSV log
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = "$env:USERPROFILE\Documents\Mailbox_Archive_Log_$timestamp.csv"

# Export the log to CSV
$log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

# Inform user where the log is saved
Write-Host "Log exported to: $logPath"

# Cleanly disconnect session from Exchange Online
Disconnect-ExchangeOnline -Confirm:$false
