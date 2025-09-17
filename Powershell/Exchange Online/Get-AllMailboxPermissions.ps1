<#
# =========================================
# ===   Generate User-Centric Mailbox Delegation Report   ===
# =========================================
.SYNOPSIS
    Generate a user-centric delegated permissions report for all Exchange Online mailboxes.

.DESCRIPTION
    Enumerates Full Access (Get-MailboxPermission), Send As (Get-RecipientPermission),
    and Send on Behalf (GrantSendOnBehalfTo) across all mailboxes, then pivots results
    so each row is: DelegateUser -> Mailbox with boolean flags for each permission type.

.OUTPUTS
    CSV: .\MailboxDelegates_ByUser.csv

.AUTHOR
    Raymond Slater

.VERSION
    1.1 - 2025-09-18
        - Initial user-centric pivot version.

.NOTES
    - Requires Exchange Online PowerShell module (Connect-ExchangeOnline).
    - Excludes inherited entries and NT AUTHORITY\SELF.
    - Leaves group vs user trustees as-is (string); optionally resolve to UPN if desired.
#>

# =========================================
# ===   Parameters   ===
# =========================================
param(
    [string]$OutputPath = ".\MailboxDelegates_ByUser.csv",
    [switch]$ResolveTrusteesToUPN  # When set, tries to resolve trustees to PrimarySmtpAddress/UPN (extra lookups)
)

# =========================================
# ===   Connect to Exchange Online   ===
# =========================================
try {
    if (-not (Get-Module -Name ExchangeOnlineManagement -ListAvailable)) {
        Write-Host "ExchangeOnlineManagement module not found. Install-Module ExchangeOnlineManagement -Scope AllUsers" -ForegroundColor Yellow
    }
    if (-not (Get-ConnectionInformation)) {
        Connect-ExchangeOnline -ShowProgress $false
    }
} catch {
    Write-Host "Failed to connect to Exchange Online: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# =========================================
# ===   Collect Mailboxes   ===
# =========================================
Write-Host "Collecting mailboxes..." -ForegroundColor Cyan
$mailboxes = Get-Mailbox -ResultSize Unlimited

# To reduce duplicate lookups when resolving trustees
$recipientCache = @{}
function Resolve-Trustee {
    param([string]$Trustee)
    if (-not $ResolveTrusteesToUPN) { return $Trustee }

    if ([string]::IsNullOrWhiteSpace($Trustee)) { return $Trustee }
    if ($recipientCache.ContainsKey($Trustee)) { return $recipientCache[$Trustee] }

    try {
        # Try both user/group/mailbox types
        $r = Get-Recipient -Identity $Trustee -ErrorAction Stop
        $resolved = if ($r.PrimarySmtpAddress) { $r.PrimarySmtpAddress.ToString() } else { $r.Name }
        $recipientCache[$Trustee] = $resolved
        return $resolved
    } catch {
        # Fallback to raw string if not resolvable
        $recipientCache[$Trustee] = $Trustee
        return $Trustee
    }
}

# =========================================
# ===   Build raw permission tuples   ===
# =========================================
# Each item: @{ Delegate='user/group'; Mailbox='Mailbox Name'; Type='FullAccess|SendAs|SendOnBehalf' }
$tuples = New-Object System.Collections.Generic.List[object]

# --- FULL ACCESS ---
Write-Host "Enumerating Full Access..." -ForegroundColor Cyan
foreach ($mbx in $mailboxes) {
    try {
        $fa = Get-MailboxPermission -Identity $mbx.Identity -ErrorAction Stop |
            Where-Object {
                -not $_.IsInherited -and
                -not $_.Deny -and
                $_.AccessRights -contains 'FullAccess' -and
                $_.User -ne 'NT AUTHORITY\SELF'
            }
        foreach ($p in $fa) {
            $tuples.Add([PSCustomObject]@{
                Delegate = (Resolve-Trustee -Trustee $p.User.ToString())
                Mailbox  = $mbx.DisplayName
                MailboxUPN = $mbx.UserPrincipalName
                Type     = 'FullAccess'
            })
        }
    } catch {
        Write-Host "FullAccess query failed for $($mbx.DisplayName): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- SEND AS ---
Write-Host "Enumerating Send As..." -ForegroundColor Cyan
foreach ($mbx in $mailboxes) {
    try {
        $sa = Get-RecipientPermission -Identity $mbx.Identity -ErrorAction Stop |
            Where-Object {
                -not $_.Deny -and
                ($_.AccessRights -contains 'SendAs') -and
                $_.Trustee -ne 'NT AUTHORITY\SELF'
            }
        foreach ($p in $sa) {
            $tuples.Add([PSCustomObject]@{
                Delegate = (Resolve-Trustee -Trustee $p.Trustee.ToString())
                Mailbox  = $mbx.DisplayName
                MailboxUPN = $mbx.UserPrincipalName
                Type     = 'SendAs'
            })
        }
    } catch {
        Write-Host "SendAs query failed for $($mbx.DisplayName): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- SEND ON BEHALF ---
Write-Host "Enumerating Send on Behalf..." -ForegroundColor Cyan
foreach ($mbx in $mailboxes) {
    if ($mbx.GrantSendOnBehalfTo) {
        foreach ($trustee in $mbx.GrantSendOnBehalfTo) {
            $tuples.Add([PSCustomObject]@{
                Delegate = (Resolve-Trustee -Trustee $trustee.Name)
                Mailbox  = $mbx.DisplayName
                MailboxUPN = $mbx.UserPrincipalName
                Type     = 'SendOnBehalf'
            })
        }
    }
}

# =========================================
# ===   Pivot to User-Centric Rows   ===
# =========================================
Write-Host "Pivoting to user-centric view..." -ForegroundColor Cyan

# Key: "$Delegate||$MailboxUPN"
$pivot = @{}

foreach ($t in $tuples) {
    $key = "$($t.Delegate)||$($t.MailboxUPN)"
    if (-not $pivot.ContainsKey($key)) {
        $pivot[$key] = [PSCustomObject]@{
            DelegateUser   = $t.Delegate
            Mailbox        = $t.Mailbox
            MailboxUPN     = $t.MailboxUPN
            FullAccess     = $false
            SendAs         = $false
            SendOnBehalf   = $false
        }
    }
    switch ($t.Type) {
        'FullAccess'   { $pivot[$key].FullAccess   = $true }
        'SendAs'       { $pivot[$key].SendAs       = $true }
        'SendOnBehalf' { $pivot[$key].SendOnBehalf = $true }
    }
}

$byUser = $pivot.Values |
    Sort-Object DelegateUser, Mailbox

# =========================================
# ===   Output   ===
# =========================================
if ($byUser.Count -eq 0) {
    Write-Host "No delegated permissions found." -ForegroundColor Yellow
} else {
    $byUser | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Report generated: $OutputPath" -ForegroundColor Green

    # Also show a quick on-screen table (top 50)
    $byUser | Select-Object DelegateUser, Mailbox, MailboxUPN, FullAccess, SendAs, SendOnBehalf |
        Format-Table -AutoSize | Out-Host
}
