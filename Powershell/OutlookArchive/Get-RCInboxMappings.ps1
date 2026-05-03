#Requires -Version 5.1
<#
.SYNOPSIS
    Scans the rc@neconnect.com.au mailbox Inbox\<Branch>\<Company> folder
    structure and discovers which rc+<tag>@neconnect.com.au address maps
    to each company folder by inspecting existing email recipients.

.OUTPUTS
    <ScriptRoot>\RCMappings.csv
        ToAddress  — the rc+tag address to match on
        Branch     — top-level grouping folder
        Company    — destination subfolder
        ItemCount  — emails currently in that folder
        Confidence — how many sampled emails confirmed this address
#>

# ── CONFIG ────────────────────────────────────────────────────────────────────

$MailboxMatch   = 'rc@neconnect.com.au'
$RCDomain       = 'neconnect.com.au'       # domain to look for in recipients
$SamplePerFolder = 10                       # emails to inspect per company folder

# ── END CONFIG ────────────────────────────────────────────────────────────────

function Get-RCRecipientAddress {
    <#
        Finds the rc+* recipient address in a mail item's recipient list.
        Returns the first matching SMTP address, or $null if none found.
    #>
    param([object]$MailItem, [string]$Domain)

    foreach ($recipient in $MailItem.Recipients) {
        try {
            $addr = $recipient.Address

            # Resolve Exchange internal DN if needed
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
                return $addr.ToLower().Trim()
            }
        } catch { }
    }
    return $null
}

# ── CONNECT ───────────────────────────────────────────────────────────────────

Write-Host "`nConnecting to Outlook..." -ForegroundColor Cyan
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

# ── SCAN ──────────────────────────────────────────────────────────────────────

$results    = [System.Collections.Generic.List[PSCustomObject]]::new()
$branches   = $inbox.Folders
$branchTotal = $branches.Count
$branchIndex = 0

foreach ($branch in $branches) {
    $branchIndex++
    $branchName  = $branch.Name
    $companyTotal = $branch.Folders.Count
    $companyIndex = 0

    foreach ($company in $branch.Folders) {
        $companyIndex++
        $companyName = $company.Name
        $itemCount   = $company.Items.Count

        Write-Progress -Activity "Scanning mailbox folders" `
            -Status "[$branchIndex/$branchTotal] $branchName — $companyName ($itemCount items)" `
            -PercentComplete (($branchIndex / $branchTotal) * 100)

        # Sample emails to discover the rc+ address
        $addressVotes = @{}
        $limit  = [Math]::Min($SamplePerFolder, $itemCount)

        for ($i = 1; $i -le $limit; $i++) {
            $item = $company.Items.Item($i)
            if ($item.Class -ne 43) { continue }

            $rcAddr = Get-RCRecipientAddress -MailItem $item -Domain $RCDomain
            if ($rcAddr) {
                if ($addressVotes.ContainsKey($rcAddr)) { $addressVotes[$rcAddr]++ }
                else                                    { $addressVotes[$rcAddr] = 1 }
            }
        }

        # Pick the most frequently seen address as the canonical mapping
        $topAddress = $addressVotes.GetEnumerator() |
            Sort-Object Value -Descending |
            Select-Object -First 1

        $results.Add([PSCustomObject]@{
            ToAddress  = if ($topAddress) { $topAddress.Key } else { '' }
            Branch     = $branchName
            Company    = $companyName
            ItemCount  = $itemCount
            Confidence = if ($topAddress) { "$($topAddress.Value)/$limit" } else { '0/0' }
        })
    }
}

Write-Progress -Activity "Scanning mailbox folders" -Completed

# ── EXPORT ────────────────────────────────────────────────────────────────────

$outputPath = Join-Path $PSScriptRoot 'RCMappings.csv'

$results |
    Sort-Object Branch, Company |
    Export-Csv -Path $outputPath -NoTypeInformation -Encoding UTF8

Write-Host "`n── Summary ───────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "  Folders scanned  : $($results.Count)"
Write-Host "  Address found    : $(($results | Where-Object { $_.ToAddress }).Count)"
Write-Host "  No address found : $(($results | Where-Object { -not $_.ToAddress }).Count)"
Write-Host "  Output           : $outputPath"
Write-Host ""
Write-Host "Review RCMappings.csv — check Confidence column for low scores" -ForegroundColor Yellow
Write-Host "and fill in any missing ToAddress values manually." -ForegroundColor Yellow
Write-Host ""
