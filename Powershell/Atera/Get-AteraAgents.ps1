<#
.SYNOPSIS
    Exports a list of all Atera agents with key device information.

.DESCRIPTION
    Connects to the Atera RMM API and retrieves all agents across all customers.
    Outputs device details including customer name, hostname, last seen date,
    IP addresses, OS, online status, and more.

    Results are exported to a CSV file and optionally displayed in the console.
    Optionally removes stale agents (not seen in 90+ days) from Atera.

.PARAMETER ShowOutput
    Display results in the console as a formatted table.

.PARAMETER RemoveStale
    Delete agents that have not been seen in 90+ days.
    Supports -WhatIf to preview deletions without making changes.

.EXAMPLE
    .\Get-AteraAgents.ps1

.EXAMPLE
    .\Get-AteraAgents.ps1 -ShowOutput

.EXAMPLE
    .\Get-AteraAgents.ps1 -RemoveStale -WhatIf

.EXAMPLE
    .\Get-AteraAgents.ps1 -RemoveStale -Confirm

.EXAMPLE
    .\Get-AteraAgents.ps1 -RemoveStale -ListOnly

.NOTES
    Author: Raymond Slater
    Repository: https://github.com/razer86/scripts
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [switch]$ShowOutput,

    [Parameter()]
    [switch]$RemoveStale,

    [Parameter()]
    [switch]$ListOnly
)

# =========================================
# ===   LOAD CONFIGURATION             ===
# =========================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Config = Import-PowerShellDataFile -Path (Join-Path $ScriptDir "config.psd1")

$ApiKey       = $Config.ApiKey
$BaseUrl      = $Config.BaseUrl
$ItemsPerPage = $Config.ItemsPerPage
$OutputFile   = Join-Path $ScriptDir $Config.OutputFile

# =========================================
# ===   VALIDATE CONFIGURATION         ===
# =========================================

if (-not $ApiKey -or $ApiKey -eq "your-api-key-here") {
    Write-Error "API key is not configured. Update ApiKey in config.psd1. Aborting."
    exit 1
}

$Headers = @{
    "X-API-KEY" = $ApiKey
    "Accept"    = "application/json"
}

# =========================================
# ===   RETRIEVE AGENTS                ===
# =========================================

Write-Host "Fetching agents from Atera..." -ForegroundColor Cyan

$AllAgents = [System.Collections.Generic.List[object]]::new()
$Page = 1

do {
    $Uri = "{0}/agents?page={1}&itemsInPage={2}" -f $BaseUrl, $Page, $ItemsPerPage

    try {
        $Response = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
    }
    catch {
        Write-Error "API request failed on page ${Page}: $_"
        exit 1
    }

    if ($Page -eq 1) {
        Write-Host "  Total agents: $($Response.totalItemCount)" -ForegroundColor Gray
    }

    foreach ($Agent in $Response.items) {
        $AllAgents.Add([PSCustomObject]@{
            CustomerName     = $Agent.CustomerName
            MachineName      = $Agent.MachineName
            DomainName       = $Agent.DomainName
            Online           = $Agent.Online
            LastSeen         = $Agent.LastSeen
            Stale            = if ($Agent.LastSeen) { ([datetime]$Agent.LastSeen) -lt (Get-Date).AddDays(-90) } else { $true }
            IPAddressLan     = if ($Agent.IPAddresses -is [array]) { $Agent.IPAddresses -join "; " } else { $Agent.IPAddresses }
            IPAddressWan     = $Agent.ReportedFromIP
            OS               = $Agent.OS
            OSType           = $Agent.OSType
            CurrentUser      = $Agent.CurrentLoggedUsers
            LastReboot       = $Agent.LastRebootTime
            AgentVersion     = $Agent.AgentVersion
            Processor        = $Agent.Processor
            MemoryGB         = if ($Agent.Memory) { [math]::Round($Agent.Memory / 1MB, 1) } else { $null }
            AgentID          = $Agent.AgentID
        })
    }

    Write-Host "  Page $Page of $($Response.totalPages)..." -ForegroundColor Gray
    $Page++
} while ($Response.nextLink -and $Response.nextLink -ne "")

# =========================================
# ===   OUTPUT                          ===
# =========================================

$StaleCount = ($AllAgents | Where-Object { $_.Stale }).Count

Write-Host "`nRetrieved $($AllAgents.Count) agents. Stale (90+ days): $StaleCount" -ForegroundColor Green

$AllAgents | Sort-Object CustomerName, MachineName |
    Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "Exported to: $OutputFile" -ForegroundColor Green

if ($StaleCount -gt 0) {
    Write-Host "`nStale agents (not seen in 90+ days):" -ForegroundColor Yellow
    $AllAgents | Where-Object { $_.Stale } | Sort-Object LastSeen |
        Format-Table CustomerName, MachineName, LastSeen, OS -AutoSize
}

# =========================================
# ===   REMOVE STALE AGENTS            ===
# =========================================

if ($RemoveStale -and $StaleCount -gt 0) {
    $StaleAgents = $AllAgents | Where-Object { $_.Stale } | Sort-Object LastSeen

    if ($ListOnly) {
        $StaleFile = Join-Path $ScriptDir "AteraAgents_Stale.csv"
        $StaleAgents | Export-Csv -Path $StaleFile -NoTypeInformation -Encoding UTF8
        Write-Host "`nExported $StaleCount stale agents to: $StaleFile" -ForegroundColor Yellow
    }
    else {
    $Deleted = 0
    $Failed  = 0

    foreach ($Agent in $StaleAgents) {
        $Description = "'{0}' ({1}) — last seen {2}" -f $Agent.MachineName, $Agent.CustomerName, $Agent.LastSeen
        if ($PSCmdlet.ShouldProcess($Description, "Delete agent")) {
            try {
                $Uri = "{0}/agents/{1}" -f $BaseUrl, $Agent.AgentID
                Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Delete -ErrorAction Stop | Out-Null
                Write-Host "  Deleted: $Description" -ForegroundColor Red
                $Deleted++
            }
            catch {
                Write-Warning "  Failed to delete $Description : $_"
                $Failed++
            }
        }
    }

    Write-Host "`nRemoval complete. Deleted: $Deleted, Failed: $Failed" -ForegroundColor Cyan
    }
}
elseif ($RemoveStale -and $StaleCount -eq 0) {
    Write-Host "`nNo stale agents to remove." -ForegroundColor Green
}

if ($ShowOutput) {
    $AllAgents | Sort-Object CustomerName, MachineName |
        Format-Table CustomerName, MachineName, Online, Stale, LastSeen, IPAddressLan, IPAddressWan, OS -AutoSize
}
