<#
.SYNOPSIS
    Migrates "Hudu M365 Integration" passwords to the "Hudu-M365 Integration" asset layout.

.DESCRIPTION
    Searches all Hudu passwords named "Hudu M365 Integration", parses the stored notes
    for Application ID, Tenant ID, and Secret Expiry, then creates or updates the
    matching "Hudu-M365 Integration" asset for each company with the structured fields:

        Application ID  (text)
        Tenant ID       (text)
        Secret Key      (password)
        Secret Expiry   (date)

    Passwords whose notes cannot be parsed are flagged for manual review.
    Source passwords can be archived after successful migration with -Archive.

.PARAMETER HuduBaseUrl
    Base URL of your Hudu instance (e.g. 'https://hudu.yourcompany.com').
    Falls back to config.psd1, then prompts if still unset.

.PARAMETER HuduApiKey
    Hudu API key. Falls back to config.psd1, then prompts if still unset.

.PARAMETER AssetLayoutName
    Name of the target asset layout in Hudu. Default: 'Hudu-M365 Integration'.

.PARAMETER AssetLayoutId
    Numeric asset layout ID — skips the name search when provided.
    Also falls back to HuduM365AssetLayoutId in config.psd1.

.PARAMETER AssetNamePrefix
    Prefix used when naming created/updated assets.
    Asset name becomes "<AssetNamePrefix> - <Company Name>".
    Default: 'Hudu-M365 Integration'.
    Also falls back to HuduM365AssetName in config.psd1.

.PARAMETER PasswordName
    Exact name of the source Hudu password records to migrate.
    Default: 'Hudu M365 Integration'.

.PARAMETER PasswordId
    Migrate a single password by its Hudu numeric ID instead of scanning all
    passwords named 'Hudu M365 Integration'. Useful for retrying a record that
    appeared in the Needs Review list.

.PARAMETER Archive
    Archive each source password after it has been successfully migrated.

.PARAMETER WhatIf
    Show what would be done without making any changes.

.EXAMPLE
    .\Migrate-HuduM365Passwords.ps1

    Migrates all matching passwords. Prompts for any missing Hudu credentials.

.EXAMPLE
    .\Migrate-HuduM365Passwords.ps1 -PasswordId 9231

    Migrates a single password by ID — useful for manual retries.

.EXAMPLE
    .\Migrate-HuduM365Passwords.ps1 -Archive

    Migrates and archives the source passwords on success.

.EXAMPLE
    .\Migrate-HuduM365Passwords.ps1 -WhatIf

    Preview mode — no Hudu records are created or modified.

.NOTES
    Author  : Raymond Slater
    Version : 1.0.0

.LINK
    https://github.com/razer86/scripts
#>

#Requires -Version 7.2

[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$HuduBaseUrl,
    [string]$HuduApiKey,
    [string]$AssetLayoutName   = 'Hudu-M365 Integration',
    [int]   $AssetLayoutId     = 0,
    [string]$AssetNamePrefix,
    [string]$PasswordName      = 'Hudu M365 Integration',
    [int]   $PasswordId        = 0,
    [switch]$Archive
)

$ErrorActionPreference = 'Stop'


# ── Config loading ─────────────────────────────────────────────────────────────

$_configPath = Join-Path $PSScriptRoot 'config.psd1'
if (Test-Path $_configPath) {
    try {
        $_cfg = Import-PowerShellDataFile -Path $_configPath
        if (-not $HuduApiKey       -and $_cfg.HuduApiKey)              { $HuduApiKey        = $_cfg.HuduApiKey }
        if (-not $HuduBaseUrl      -and $_cfg.HuduBaseUrl)             { $HuduBaseUrl        = $_cfg.HuduBaseUrl }
        if ($AssetLayoutId -eq 0   -and $_cfg.HuduM365AssetLayoutId)   { $AssetLayoutId      = $_cfg.HuduM365AssetLayoutId }
        if (-not $AssetNamePrefix  -and $_cfg.HuduM365AssetName)       { $AssetNamePrefix    = $_cfg.HuduM365AssetName }
    }
    catch { Write-Warning "Could not load config.psd1: $_" }
}

if (-not $AssetNamePrefix) { $AssetNamePrefix = 'Hudu-M365 Integration' }

if (-not $HuduBaseUrl) { $HuduBaseUrl = Read-Host 'Hudu base URL (e.g. https://hudu.yourcompany.com)' }
$HuduBaseUrl = $HuduBaseUrl.TrimEnd('/')

if (-not $HuduApiKey) { $HuduApiKey = Read-Host 'Hudu API key' }

$script:BaseUrl = $HuduBaseUrl
$script:Headers = @{ 'x-api-key' = $HuduApiKey; 'Content-Type' = 'application/json' }


# ── Helpers ────────────────────────────────────────────────────────────────────

function Invoke-HuduApi {
    param (
        [string]   $Path,
        [hashtable]$Query  = @{},
        [string]   $Method = 'Get',
        [string]   $Body
    )
    $uri = "$($script:BaseUrl)/api/v1/$Path"
    if ($Query.Count) {
        $qs  = ($Query.GetEnumerator() |
                ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString("$($_.Value)"))" }) -join '&'
        $uri = "${uri}?${qs}"
    }
    $params = @{
        Uri     = $uri
        Headers = $script:Headers
        Method  = $Method
    }
    if ($Body) { $params.Body = $Body }
    Invoke-RestMethod @params
}

function Write-Section {
    param ([string]$Title)
    Write-Host "`n$('─' * 66)" -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "$('─' * 66)" -ForegroundColor DarkGray
}

function Write-Field {
    param ([string]$Label, [string]$Value, [string]$Color = 'White')
    Write-Host ("  {0,-26} {1}" -f "${Label}:", $Value) -ForegroundColor $Color
}

# Strip HTML tags and normalise whitespace so regexes work on plain text.
function Remove-HtmlTags {
    param ([string]$Html)
    $Html -replace '<br\s*/?>', "`n" `
          -replace '<[^>]+>',   ' '  `
          -replace '&nbsp;',    ' '  `
          -replace '&amp;',     '&'  `
          -replace '&lt;',      '<'  `
          -replace '&gt;',      '>'  `
          -replace '\s+',       ' '
}

# Parse Application ID, Tenant ID, and Secret Expiry from the notes text.
function ConvertFrom-HuduNotes {
    param ([string]$Notes)

    $plain  = Remove-HtmlTags -Html $Notes
    $result = @{}

    # Application ID / Tenant ID — both are GUIDs
    if ($plain -match 'Application\s+ID\s*[:\-=]\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $result.ApplicationId = $Matches[1]
    }
    if ($plain -match 'Tenant\s+ID\s*[:\-=]\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        $result.TenantId = $Matches[1]
    }
    # Secret Expiry — yyyy-MM-dd HH:mm:ss or yyyy-MM-dd
    if ($plain -match 'Secret\s+Expires?\s*[:\-=]\s*(\d{4}-\d{2}-\d{2}(?:\s+\d{2}:\d{2}:\d{2})?)') {
        $result.SecretExpiry = ($Matches[1].Trim() -replace ' .*', '')  # keep date portion only
    }

    return $result
}

# Fetch all pages of passwords matching the given name.
function Get-AllMatchingPasswords {
    param ([string]$Name)

    $results  = [System.Collections.Generic.List[object]]::new()
    $page     = 1
    $pageSize = 100

    do {
        $response = Invoke-HuduApi -Path 'asset_passwords' -Query @{
            search    = $Name
            page      = $page
            page_size = $pageSize
        }
        $batch = @($response.asset_passwords | Where-Object { $_.name -eq $Name })
        $results.AddRange($batch)
        $page++
    } while ($batch.Count -eq $pageSize)

    return $results
}

# Fetch the decrypted password value for a single password record.
function Get-PasswordValue {
    param ([int]$Id)
    $record = Invoke-HuduApi -Path "asset_passwords/$Id"
    return $record.asset_password.password
}


# ── Step 1: Connectivity ───────────────────────────────────────────────────────

Write-Section 'Step 1 — API connectivity'

try {
    Invoke-HuduApi -Path 'companies' -Query @{ page_size = '1' } | Out-Null
    Write-Field 'Status'   'Connected'   'Green'
    Write-Field 'Base URL' $HuduBaseUrl
}
catch {
    Write-Host "`n  ERROR: Could not connect to Hudu API." -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Red
    exit 1
}


# ── Step 2: Resolve asset layout ──────────────────────────────────────────────

Write-Section "Step 2 — Asset layout ($AssetLayoutName)"

if ($AssetLayoutId -eq 0) {
    try {
        $encoded  = [uri]::EscapeDataString($AssetLayoutName)
        $layouts  = @((Invoke-HuduApi -Path 'asset_layouts' -Query @{
            search    = $encoded
            page_size = '25'
        }).asset_layouts)

        $layout   = $layouts | Where-Object { $_.name -eq $AssetLayoutName } | Select-Object -First 1

        if (-not $layout) {
            Write-Host "  ERROR: No asset layout found named '$AssetLayoutName'." -ForegroundColor Red
            Write-Host "  Create the layout in Hudu first, or pass -AssetLayoutId <id>." -ForegroundColor DarkGray
            exit 1
        }

        $AssetLayoutId = $layout.id
    }
    catch {
        Write-Host "  ERROR: Could not query asset layouts: $_" -ForegroundColor Red
        exit 1
    }
}

Write-Field 'Layout name' $AssetLayoutName
Write-Field 'Layout ID'   $AssetLayoutId


# ── Step 3: Find source passwords ─────────────────────────────────────────────

if ($PasswordId -gt 0) {
    Write-Section "Step 3 — Single password (id: $PasswordId)"

    try {
        $record    = Invoke-HuduApi -Path "asset_passwords/$PasswordId"
        $passwords = @($record.asset_password)
        Write-Field 'Found' "1 password (id: $PasswordId)" 'Green'
    }
    catch {
        Write-Host "  ERROR: Could not retrieve password id ${PasswordId}: $_" -ForegroundColor Red
        exit 1
    }
}
else {
    Write-Section "Step 3 — Source passwords ('$PasswordName')"

    $passwords = Get-AllMatchingPasswords -Name $PasswordName

    if ($passwords.Count -eq 0) {
        Write-Host "  No passwords found with name '$PasswordName'." -ForegroundColor Yellow
        exit 0
    }

    Write-Field 'Found' "$($passwords.Count) password(s)" 'Green'
}


# ── Step 4: Migrate ───────────────────────────────────────────────────────────

Write-Section 'Step 4 — Migration'

$results = @{
    Success      = [System.Collections.Generic.List[string]]::new()
    NeedsReview  = [System.Collections.Generic.List[string]]::new()
    Failed       = [System.Collections.Generic.List[string]]::new()
}

foreach ($pwd in $passwords) {
    # company_name is not always returned by the list endpoint — fall back to company_id
    $companyLabel = if ($pwd.company_name) { $pwd.company_name } else { "company_id:$($pwd.company_id)" }
    $label = "$companyLabel (password id: $($pwd.id))"
    Write-Host ''
    Write-Host "  Processing: $label" -ForegroundColor Cyan

    # ── Parse notes ──────────────────────────────────────────────────────────
    # Hudu asset_passwords API returns the notes field as 'description'
    $parsed = ConvertFrom-HuduNotes -Notes "$($pwd.description)"

    if (-not $parsed.ApplicationId) {
        Write-Host "    WARNING: Could not extract Application ID from notes." -ForegroundColor Yellow
        $results.NeedsReview.Add($label)
        continue
    }
    if (-not $parsed.TenantId) {
        Write-Host "    WARNING: Could not extract Tenant ID from notes." -ForegroundColor Yellow
        $results.NeedsReview.Add($label)
        continue
    }

    Write-Host ("    Application ID : {0}" -f $parsed.ApplicationId) -ForegroundColor DarkCyan
    Write-Host ("    Tenant ID      : {0}" -f $parsed.TenantId)      -ForegroundColor DarkCyan

    if ($parsed.SecretExpiry) {
        Write-Host ("    Secret Expiry  : {0}" -f $parsed.SecretExpiry) -ForegroundColor DarkCyan
    } else {
        Write-Host    "    Secret Expiry  : (not found in notes — field will be left blank)" -ForegroundColor DarkGray
    }

    # ── Fetch decrypted secret ───────────────────────────────────────────────
    try {
        $secretKey = Get-PasswordValue -Id $pwd.id
        if (-not $secretKey) {
            Write-Host "    WARNING: Password value is empty." -ForegroundColor Yellow
            $results.NeedsReview.Add($label)
            continue
        }
        Write-Host "    Secret Key     : (retrieved)" -ForegroundColor DarkCyan
    }
    catch {
        Write-Host "    ERROR: Could not retrieve password value: $_" -ForegroundColor Red
        $results.Failed.Add($label)
        continue
    }

    # ── Build asset payload ──────────────────────────────────────────────────
    $companyId   = $pwd.company_id
    $companyName = $pwd.company_name
    if (-not $companyName) {
        try {
            $companyName = (Invoke-HuduApi -Path "companies/$companyId").company.name
        }
        catch {
            Write-Host "    WARNING: Could not resolve company name for id ${companyId}: $_" -ForegroundColor Yellow
            $companyName = "company_id:$companyId"
        }
    }
    $assetName   = "$AssetNamePrefix - $companyName"

    $customFields = @(
        @{ application_id = $parsed.ApplicationId }
        @{ tenant_id      = $parsed.TenantId }
        @{ secret_key     = $secretKey }
    )
    if ($parsed.SecretExpiry) {
        # Hudu date fields accept yyyy/MM/dd
        $expiry       = [datetime]::ParseExact($parsed.SecretExpiry, 'yyyy-MM-dd', $null)
        $customFields += @{ secret_expiry = $expiry.ToString('yyyy/MM/dd') }
    }

    $body = @{
        name            = $assetName
        asset_layout_id = $AssetLayoutId
        custom_fields   = $customFields
    } | ConvertTo-Json -Depth 5

    # ── Find existing asset ──────────────────────────────────────────────────
    try {
        $existing = @((Invoke-HuduApi -Path 'assets' -Query @{
            company_id      = "$companyId"
            asset_layout_id = "$AssetLayoutId"
            archived        = 'false'
            page_size       = '10'
        }).assets) | Select-Object -First 1
    }
    catch {
        Write-Host "    ERROR: Could not query existing assets: $_" -ForegroundColor Red
        $results.Failed.Add($label)
        continue
    }

    # ── Push to Hudu ─────────────────────────────────────────────────────────
    if ($WhatIfPreference) {
        if ($existing) {
            Write-Host "    [WHATIF] Would update asset '$($existing.name)' (id: $($existing.id))" -ForegroundColor DarkYellow
        } else {
            Write-Host "    [WHATIF] Would create asset '$assetName' in company '$companyName' (id: $companyId)" -ForegroundColor DarkYellow
        }
        $results.Success.Add($label)
        continue
    }

    try {
        if ($existing) {
            Write-Verbose "    PUT assets/$($existing.id)"
            try {
                Invoke-HuduApi -Path "assets/$($existing.id)" -Method Put -Body $body | Out-Null
                Write-Host "    Updated asset: $($existing.name) (id: $($existing.id))" -ForegroundColor Green
            }
            catch [Microsoft.PowerShell.Commands.HttpResponseException] {
                if ($_.Exception.Response.StatusCode.value__ -eq 404) {
                    Write-Host "    WARNING: PUT returned 404 — asset may be stale. Falling back to POST." -ForegroundColor Yellow
                    $created = Invoke-HuduApi -Path "companies/$companyId/assets" -Method Post -Body $body
                    Write-Host "    Created asset: $($created.asset.name) (id: $($created.asset.id))" -ForegroundColor Green
                }
                else { throw }
            }
        } else {
            Write-Verbose "    POST companies/$companyId/assets"
            $created = Invoke-HuduApi -Path "companies/$companyId/assets" -Method Post -Body $body
            Write-Host "    Created asset: $($created.asset.name) (id: $($created.asset.id))" -ForegroundColor Green
        }
    }
    catch {
        $op = if ($existing) { "PUT assets/$($existing.id)" } else { "POST companies/$companyId/assets" }
        Write-Host "    ERROR: Asset push failed [$op]: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "    $($_.ErrorDetails.Message)" -ForegroundColor DarkRed
        $results.Failed.Add($label)
        continue
    }

    $results.Success.Add($label)

    # ── Archive source password ──────────────────────────────────────────────
    if ($Archive) {
        try {
            Invoke-HuduApi -Path "asset_passwords/$($pwd.id)/archive" -Method Put | Out-Null
            Write-Host "    Archived source password (id: $($pwd.id))" -ForegroundColor DarkGray
        }
        catch {
            Write-Host "    WARNING: Could not archive source password: $_" -ForegroundColor Yellow
        }
    }
}


# ── Summary ────────────────────────────────────────────────────────────────────

Write-Section 'Summary'

Write-Host ''
Write-Host ("  {0,-20} {1}" -f 'Migrated:', $results.Success.Count)     -ForegroundColor Green
Write-Host ("  {0,-20} {1}" -f 'Needs review:', $results.NeedsReview.Count) -ForegroundColor $(if ($results.NeedsReview.Count) { 'Yellow' } else { 'Gray' })
Write-Host ("  {0,-20} {1}" -f 'Failed:', $results.Failed.Count)        -ForegroundColor $(if ($results.Failed.Count) { 'Red' } else { 'Gray' })

if ($results.NeedsReview.Count) {
    Write-Host ''
    Write-Host '  The following passwords could not be parsed — migrate manually:' -ForegroundColor Yellow
    $results.NeedsReview | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
}

if ($results.Failed.Count) {
    Write-Host ''
    Write-Host '  The following passwords encountered errors:' -ForegroundColor Red
    $results.Failed | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}

if (-not $Archive -and $results.Success.Count -gt 0 -and -not $WhatIfPreference) {
    Write-Host ''
    Write-Host '  Source passwords have NOT been archived. Re-run with -Archive once you' -ForegroundColor DarkGray
    Write-Host '  have verified the migrated assets in Hudu.' -ForegroundColor DarkGray
}
