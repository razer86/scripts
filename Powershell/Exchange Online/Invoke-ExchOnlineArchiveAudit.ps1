#Requires -Modules ExchangeOnlineManagement

<#
.SYNOPSIS
    Reports mailbox size and in-place archive status; optionally enables archiving for
    mailboxes below a configurable free-space threshold.

.DESCRIPTION
    Connects to Exchange Online and enumerates user mailboxes to report:
      - Current mailbox used size, quota, and percentage of free space
      - In-place archive status, used size, and quota (when active)

    When -EnableArchive is specified, archiving is enabled on any mailbox whose free
    space falls below -FreeSpaceThresholdPercent. Without -EnableArchive the script
    is strictly read-only (report/audit mode).

    Supports -WhatIf to preview which mailboxes would have archiving enabled without
    making any changes.

.PARAMETER FreeSpaceThresholdPercent
    Mailboxes with less than this percentage of free space will be flagged (and
    archived when -EnableArchive is also specified). Must be between 1 and 99.
    Default: 25.

.PARAMETER EnableArchive
    When specified, enables in-place archiving on qualifying mailboxes.
    Omit for a report-only run that makes no changes to the tenant.

.PARAMETER UserPrincipalName
    Scope the operation to a single mailbox by UPN. Omit to process all user
    mailboxes in the tenant.

.PARAMETER OutputPath
    Full path for the exported CSV report. Defaults to a timestamped file in the
    current user's Documents folder.

.PARAMETER SkipConnect
    Skip the Connect-ExchangeOnline call. Use when an Exchange Online session is
    already active in the current PowerShell window.

.EXAMPLE
    .\Invoke-ExchOnlineArchiveAudit.ps1

    Report-only mode for all mailboxes. No changes are made.

.EXAMPLE
    .\Invoke-ExchOnlineArchiveAudit.ps1 -EnableArchive -FreeSpaceThresholdPercent 30

    Enable in-place archive for any mailbox with less than 30% free space.

.EXAMPLE
    .\Invoke-ExchOnlineArchiveAudit.ps1 -EnableArchive -WhatIf

    Preview which mailboxes would have archiving enabled without making any changes.

.EXAMPLE
    .\Invoke-ExchOnlineArchiveAudit.ps1 -UserPrincipalName jdoe@contoso.com

    Report the archive status and size for a single mailbox.

.NOTES
    Version : 2.0
    Requires: ExchangeOnlineManagement module (Install-Module ExchangeOnlineManagement)
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter()]
    [ValidateRange(1, 99)]
    [int]$FreeSpaceThresholdPercent = 25,

    [Parameter()]
    [switch]$EnableArchive,

    [Parameter()]
    [string]$UserPrincipalName,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$SkipConnect
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helper Functions -------------------------------------------------------

function Get-SizeBytes {
    <#
    .SYNOPSIS
        Extracts a byte count from an Exchange ByteQuantifiedSize or quota object.
        Returns $null when the value is Unlimited or cannot be parsed.
    #>
    [OutputType([long])]
    param ([object]$Size)

    if ($null -eq $Size) { return $null }

    $str = $Size.ToString()
    if ($str -eq 'Unlimited') { return $null }

    # ByteQuantifiedSize exposes .Value with a ToBytes() method
    try { return [long]$Size.Value.ToBytes() } catch { }

    # Fallback: parse the "(N bytes)" substring present in most quota strings
    if ($str -match '([\d,]+)\s+bytes') {
        return [long]($Matches[1] -replace ',', '')
    }

    return $null
}

function Format-Bytes {
    <#
    .SYNOPSIS
        Returns a human-readable size string for a given byte count.
    #>
    [OutputType([string])]
    param ([long]$Bytes)

    switch ($Bytes) {
        { $_ -ge 1TB } { return '{0:N2} TB' -f ($_ / 1TB) }
        { $_ -ge 1GB } { return '{0:N2} GB' -f ($_ / 1GB) }
        { $_ -ge 1MB } { return '{0:N2} MB' -f ($_ / 1MB) }
        { $_ -ge 1KB } { return '{0:N2} KB' -f ($_ / 1KB) }
        default        { return "$_ B" }
    }
}

#endregion

#region Connection -------------------------------------------------------------

if (-not $SkipConnect) {
    Write-Verbose 'Connecting to Exchange Online...'
    Connect-ExchangeOnline -ShowBanner:$false
}

#endregion

#region Mailbox Enumeration ----------------------------------------------------

if ($UserPrincipalName) {
    Write-Verbose "Retrieving mailbox: $UserPrincipalName"
    $mailboxes = @(Get-Mailbox -Identity $UserPrincipalName -RecipientTypeDetails UserMailbox -ErrorAction Stop)
}
else {
    Write-Verbose 'Retrieving all user mailboxes...'
    $mailboxes = @(Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails UserMailbox)
}

$total   = $mailboxes.Count
$current = 0
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

Write-Host "Processing $total mailbox(es). Threshold: < $FreeSpaceThresholdPercent% free." -ForegroundColor Cyan

#endregion

#region Main Processing Loop ---------------------------------------------------

foreach ($mbx in $mailboxes) {
    $current++
    $upn = $mbx.UserPrincipalName

    Write-Progress -Activity 'Analyzing Mailboxes' `
                   -Status "$upn  ($current / $total)" `
                   -PercentComplete (($current / $total) * 100)

    # Build the result row with defaults; filled in below
    $entry = [ordered]@{
        DisplayName        = $mbx.DisplayName
        UserPrincipalName  = $upn
        MailboxUsed        = 'Error'
        MailboxQuota       = 'Error'
        MailboxFreePercent = 'Error'
        ArchiveStatus      = $mbx.ArchiveStatus
        ArchiveUsed        = 'N/A'
        ArchiveQuota       = 'N/A'
        ActionTaken        = 'None'
    }

    try {
        #--- Primary mailbox statistics ---
        $stats = Get-MailboxStatistics -Identity $upn -ErrorAction Stop

        $usedBytes = Get-SizeBytes $stats.TotalItemSize

        # ProhibitSendReceiveQuota is the hard ceiling; fall back to ProhibitSendQuota
        $quotaBytes = Get-SizeBytes $mbx.ProhibitSendReceiveQuota
        if ($null -eq $quotaBytes) {
            $quotaBytes = Get-SizeBytes $mbx.ProhibitSendQuota
        }

        $entry.MailboxUsed  = if ($null -ne $usedBytes)  { Format-Bytes $usedBytes }  else { 'Unknown' }
        $entry.MailboxQuota = if ($null -ne $quotaBytes) { Format-Bytes $quotaBytes } else { 'Unlimited' }

        if ($null -ne $usedBytes -and $null -ne $quotaBytes -and $quotaBytes -gt 0) {
            $freePercent               = (($quotaBytes - $usedBytes) / $quotaBytes) * 100
            $entry.MailboxFreePercent  = [math]::Round($freePercent, 1)
        }
        else {
            $entry.MailboxFreePercent = 'N/A'
        }

        #--- Archive statistics (only when archive is already active) ---
        $archiveActive = $mbx.ArchiveStatus -eq 'Active'
        if ($archiveActive) {
            $archStats = Get-MailboxStatistics -Identity $upn -Archive -ErrorAction SilentlyContinue
            if ($archStats) {
                $archUsedBytes  = Get-SizeBytes $archStats.TotalItemSize
                $archQuotaBytes = Get-SizeBytes $mbx.ArchiveQuota
                $entry.ArchiveUsed  = if ($null -ne $archUsedBytes)  { Format-Bytes $archUsedBytes }  else { 'Unknown' }
                $entry.ArchiveQuota = if ($null -ne $archQuotaBytes) { Format-Bytes $archQuotaBytes } else { 'Unlimited' }
            }
        }

        #--- Determine and take action ---
        if ($archiveActive) {
            $entry.ActionTaken = 'Already Enabled'
        }
        elseif ($entry.MailboxFreePercent -ne 'N/A' -and $entry.MailboxFreePercent -lt $FreeSpaceThresholdPercent) {
            if ($EnableArchive) {
                if ($PSCmdlet.ShouldProcess($upn, 'Enable In-Place Archive')) {
                    Enable-Mailbox -Identity $upn -Archive -ErrorAction Stop
                    $entry.ActionTaken  = 'Archive Enabled'
                    $entry.ArchiveStatus = 'Provisioning'
                    Write-Verbose "Archive enabled: $upn"
                }
                else {
                    # -WhatIf path
                    $entry.ActionTaken = 'Would Enable Archive'
                }
            }
            else {
                $entry.ActionTaken = "Action recommended (< $FreeSpaceThresholdPercent% free)"
            }
        }
        else {
            $entry.ActionTaken = 'No Action Needed'
        }
    }
    catch {
        Write-Warning "Error processing ${upn}: $_"
        $entry.ActionTaken = "Error: $_"
    }

    $results.Add([PSCustomObject]$entry)
}

Write-Progress -Activity 'Analyzing Mailboxes' -Completed

#endregion

#region Output -----------------------------------------------------------------

# Console table
$results | Format-Table DisplayName, MailboxUsed, MailboxQuota, MailboxFreePercent,
                         ArchiveStatus, ArchiveUsed, ArchiveQuota, ActionTaken -AutoSize

# Summary counts — @() ensures .Count is always valid even when Where-Object returns $null
$countEnabled     = @($results | Where-Object ActionTaken -eq 'Archive Enabled').Count
$countWouldEnable = @($results | Where-Object ActionTaken -eq 'Would Enable Archive').Count
$countRecommended   = @($results | Where-Object ActionTaken -like 'Action Recommended*').Count
$countActive      = @($results | Where-Object ActionTaken -eq 'Already Enabled').Count
$countNone        = @($results | Where-Object ActionTaken -eq 'No Action Needed').Count
$countError       = @($results | Where-Object ActionTaken -like 'Error:*').Count

Write-Host 'Summary' -ForegroundColor Cyan
Write-Host "  Total processed          : $total"
Write-Host "  Archive already active   : $countActive"
Write-Host "  No action needed         : $countNone"

if ($EnableArchive) {
    Write-Host "  Archive enabled this run : $countEnabled"
    if ($countWouldEnable -gt 0) {
        Write-Host "  Would enable (WhatIf)    : $countWouldEnable"
    }
}
else {
    Write-Host "  Recommended to enable archive      : $countRecommended  (re-run with -EnableArchive to apply)"
}

if ($countError -gt 0) {
    Write-Host "  Errors                   : $countError" -ForegroundColor Yellow
}

# CSV export
if (-not $OutputPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputPath = "$env:USERPROFILE\Documents\MailboxArchive_$timestamp.csv"
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8BOM
Write-Host "`nReport saved to: $OutputPath" -ForegroundColor Green

#endregion

#region Cleanup ----------------------------------------------------------------

Disconnect-ExchangeOnline -Confirm:$false
Write-Verbose 'Disconnected from Exchange Online.'

#endregion
