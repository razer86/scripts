<#
.SYNOPSIS
    Benchmarks DNS resolution speed against the customer's current resolver and a set of public resolvers.

.DESCRIPTION
    Raw bandwidth speed tests (Run-Speedtest.ps1) don't catch one of the most common causes of a
    customer saying "the internet feels slow": slow or flaky DNS resolution. Every new site, image
    host, or CDN endpoint has to be resolved before the browser can even open a connection, so a
    sluggish or unreliable resolver can make a fast connection feel slow.

    This script:
    - Detects the DNS server(s) currently configured on the active network adapter
    - Times resolution of a set of common domains against that resolver and several well-known
      public resolvers (Cloudflare, Google, Quad9, OpenDNS by default)
    - Runs multiple queries per domain to get an average, min/max, and jitter (standard deviation)
    - Reports failure/timeout rates per resolver
    - Flags whether the current resolver looks meaningfully slower or less reliable than the
      public alternatives, which is useful evidence when raw bandwidth speed tests come back clean

.PARAMETER Resolvers
    Optional list of resolvers to test, each in "Name=IPAddress" format (e.g. "Work-DC=10.0.0.5").
    If omitted, a default set of public resolvers is used (Cloudflare, Google, Quad9, OpenDNS).

.PARAMETER Domains
    Optional list of domains to resolve. Defaults to a mix of popular, high-traffic domains that a
    typical customer will hit constantly during normal browsing.

.PARAMETER QueryCount
    Number of queries to run per domain per resolver. Higher counts give a more reliable average
    at the cost of a longer test. Default is 5.

.PARAMETER ExcludeCurrentDns
    Skips auto-detecting and testing the currently configured system DNS server(s). By default the
    current resolver is always included first so it can be compared against the public resolvers.

.PARAMETER SkipCacheBust
    Skips clearing the local DNS client cache between queries. Cache-busting requires an elevated
    session; without it, repeat queries for the same name may return near-instantly from the local
    cache regardless of which resolver actually answered, understating real-world latency.

.PARAMETER ExportCsvPath
    Optional path to export the detailed per-domain, per-resolver results as CSV.

.EXAMPLE
    .\Test-DnsResolverSpeed.ps1
    Detects the current DNS server, tests it plus the default public resolvers against the default
    domain list, and prints a summary table with a verdict.

.EXAMPLE
    .\Test-DnsResolverSpeed.ps1 -QueryCount 10 -ExportCsvPath C:\Temp\dns-results.csv
    Runs a more thorough test (10 queries per domain) and exports the raw results to CSV.

.EXAMPLE
    .\Test-DnsResolverSpeed.ps1 -Resolvers "ISP=203.0.113.10","Router=192.168.1.1"
    Tests only the specified resolvers (plus the detected current resolver) instead of the public
    resolver defaults.

.NOTES
    File Name      : Test-DnsResolverSpeed.ps1
    Author         : Raymond Slater
    Prerequisite   : PowerShell 5.1 or later, DnsClient module (built into Windows 8/Server 2012+)

    Exit Codes:
    0 = Success
    1 = Required module unavailable
    2 = Invalid parameters (e.g. malformed -Resolvers entry)

.LINK
    https://learn.microsoft.com/powershell/module/dnsclient/resolve-dnsname
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Resolvers,

    [Parameter()]
    [string[]]$Domains = @(
        'google.com', 'cloudflare.com', 'microsoft.com', 'amazon.com',
        'facebook.com', 'youtube.com', 'wikipedia.org', 'apple.com',
        'netflix.com', 'office.com'
    ),

    [Parameter()]
    [ValidateRange(1, 50)]
    [int]$QueryCount = 5,

    [Parameter()]
    [switch]$ExcludeCurrentDns,

    [Parameter()]
    [switch]$SkipCacheBust,

    [Parameter()]
    [string]$ExportCsvPath
)

#Region Configuration
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$defaultPublicResolvers = [ordered]@{
    'Cloudflare' = '1.1.1.1'
    'Google'     = '8.8.8.8'
    'Quad9'      = '9.9.9.9'
    'OpenDNS'    = '208.67.222.222'
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$canBustCache = $isAdmin -and -not $SkipCacheBust

if (-not $isAdmin -and -not $SkipCacheBust) {
    Write-Warning "Not running elevated - local DNS cache cannot be cleared between queries. Repeat lookups of the same name may read from cache and understate real latency. Run as Administrator for the most accurate results."
}
#EndRegion Configuration

#Region Functions
function Write-ColorOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [Parameter()]
        [ConsoleColor]$ForegroundColor = 'White'
    )

    Write-Host $Message -ForegroundColor $ForegroundColor
}

function Get-CurrentDnsServers {
    <#
    .SYNOPSIS
        Returns the IPv4 DNS servers configured on adapters that are actually up and not virtual/loopback.
    #>
    [CmdletBinding()]
    param()

    try {
        $servers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object {
                $_.ServerAddresses.Count -gt 0 -and
                (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Status -eq 'Up'
            } |
            Select-Object -ExpandProperty ServerAddresses -Unique |
            Where-Object { $_ -notmatch '^127\.' -and $_ -notmatch '^169\.254\.' }

        return @($servers)
    }
    catch {
        Write-Verbose "Could not enumerate current DNS servers: $_"
        return @()
    }
}

function Measure-DnsQuery {
    <#
    .SYNOPSIS
        Times a single DNS resolution against a specific server. Returns elapsed milliseconds, or $null on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Domain,

        [Parameter(Mandatory)]
        [string]$ServerIP,

        [Parameter()]
        [bool]$BustCache
    )

    if ($BustCache) {
        try { Clear-DnsClientCache -ErrorAction Stop } catch { Write-Verbose "Cache clear failed: $_" }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $null = Resolve-DnsName -Name $Domain -Server $ServerIP -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
        $sw.Stop()
        return $sw.Elapsed.TotalMilliseconds
    }
    catch {
        $sw.Stop()
        Write-Verbose "Query for $Domain via $ServerIP failed: $($_.Exception.Message)"
        return $null
    }
}

function Test-DnsResolver {
    <#
    .SYNOPSIS
        Runs the full domain/query-count matrix against a single resolver and returns per-domain results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ResolverName,

        [Parameter(Mandatory)]
        [string]$ServerIP,

        [Parameter(Mandatory)]
        [string[]]$DomainList,

        [Parameter(Mandatory)]
        [int]$Count,

        [Parameter(Mandatory)]
        [bool]$BustCache
    )

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($domain in $DomainList) {
        $samples = [System.Collections.Generic.List[double]]::new()
        $failures = 0

        for ($i = 0; $i -lt $Count; $i++) {
            $ms = Measure-DnsQuery -Domain $domain -ServerIP $ServerIP -BustCache $BustCache
            if ($null -ne $ms) {
                $samples.Add($ms)
            } else {
                $failures++
            }
        }

        $results.Add([PSCustomObject]@{
            Resolver    = $ResolverName
            ServerIP    = $ServerIP
            Domain      = $domain
            Samples     = $samples.Count
            Failures    = $failures
            AvgMs       = if ($samples.Count -gt 0) { [math]::Round(($samples | Measure-Object -Average).Average, 1) } else { $null }
            MinMs       = if ($samples.Count -gt 0) { [math]::Round(($samples | Measure-Object -Minimum).Minimum, 1) } else { $null }
            MaxMs       = if ($samples.Count -gt 0) { [math]::Round(($samples | Measure-Object -Maximum).Maximum, 1) } else { $null }
        })
    }

    return $results
}

function Get-StdDev {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double[]]$Values)

    if ($Values.Count -lt 2) { return 0 }
    $mean = ($Values | Measure-Object -Average).Average
    $sumSq = ($Values | ForEach-Object { [math]::Pow($_ - $mean, 2) } | Measure-Object -Sum).Sum
    return [math]::Sqrt($sumSq / ($Values.Count - 1))
}
#EndRegion Functions

#Region Main Execution
try {
    if (-not (Get-Module -ListAvailable -Name DnsClient)) {
        Write-Error "The DnsClient module (Resolve-DnsName) is not available on this system. This script requires Windows 8/Server 2012 or later."
        exit 1
    }

    # Build the ordered list of resolvers to test: Name -> IP
    $resolverMap = [ordered]@{}

    if (-not $ExcludeCurrentDns) {
        $currentServers = Get-CurrentDnsServers
        if ($currentServers.Count -eq 0) {
            Write-Warning "Could not detect the current system DNS server(s) - skipping that comparison."
        } else {
            $idx = 1
            foreach ($ip in $currentServers) {
                $label = if ($currentServers.Count -gt 1) { "Current-$idx" } else { 'Current' }
                $resolverMap[$label] = $ip
                $idx++
            }
        }
    }

    if ($Resolvers) {
        foreach ($entry in $Resolvers) {
            if ($entry -notmatch '^(?<name>[^=]+)=(?<ip>.+)$') {
                Write-Error "Invalid -Resolvers entry '$entry'. Expected format: Name=IPAddress"
                exit 2
            }
            $resolverMap[$Matches['name']] = $Matches['ip']
        }
    } else {
        foreach ($key in $defaultPublicResolvers.Keys) {
            $resolverMap[$key] = $defaultPublicResolvers[$key]
        }
    }

    Write-ColorOutput "DNS Resolver Speed Test" -ForegroundColor Cyan
    Write-ColorOutput "Resolvers under test: $(($resolverMap.Keys | ForEach-Object { "$_ ($($resolverMap[$_]))" }) -join ', ')" -ForegroundColor Gray
    Write-ColorOutput "Domains: $($Domains -join ', ')" -ForegroundColor Gray
    Write-ColorOutput "Queries per domain: $QueryCount | Cache-busting: $(if ($canBustCache) { 'enabled' } else { 'disabled' })" -ForegroundColor Gray
    Write-Host ""

    $allDetailResults = [System.Collections.Generic.List[object]]::new()
    $summary = [System.Collections.Generic.List[object]]::new()

    foreach ($name in $resolverMap.Keys) {
        $ip = $resolverMap[$name]
        Write-ColorOutput "Testing $name ($ip)..." -ForegroundColor Yellow

        $detail = Test-DnsResolver -ResolverName $name -ServerIP $ip -DomainList $Domains -Count $QueryCount -BustCache $canBustCache
        $allDetailResults.AddRange($detail)

        $validAverages = $detail | Where-Object { $null -ne $_.AvgMs } | Select-Object -ExpandProperty AvgMs
        $totalSamples = ($detail | Measure-Object -Property Samples -Sum).Sum
        $totalFailures = ($detail | Measure-Object -Property Failures -Sum).Sum
        $totalQueries = $totalSamples + $totalFailures

        $summary.Add([PSCustomObject]@{
            Resolver     = $name
            ServerIP     = $ip
            AvgMs        = if ($validAverages) { [math]::Round(($validAverages | Measure-Object -Average).Average, 1) } else { $null }
            JitterMs     = if ($validAverages.Count -gt 1) { [math]::Round((Get-StdDev -Values $validAverages), 1) } else { 0 }
            MinMs        = if ($validAverages) { [math]::Round(($validAverages | Measure-Object -Minimum).Minimum, 1) } else { $null }
            MaxMs        = if ($validAverages) { [math]::Round(($validAverages | Measure-Object -Maximum).Maximum, 1) } else { $null }
            FailureRate  = if ($totalQueries -gt 0) { [math]::Round(($totalFailures / $totalQueries) * 100, 1) } else { 100 }
        })
    }

    Write-Host ""
    Write-ColorOutput "===== Summary (sorted fastest to slowest) =====" -ForegroundColor Cyan
    $sortedSummary = $summary | Sort-Object -Property @{ Expression = { if ($null -eq $_.AvgMs) { [double]::MaxValue } else { $_.AvgMs } } }
    $sortedSummary | Format-Table -Property Resolver, ServerIP,
        @{Label = 'Avg (ms)'; Expression = { $_.AvgMs } },
        @{Label = 'Jitter (ms)'; Expression = { $_.JitterMs } },
        @{Label = 'Min (ms)'; Expression = { $_.MinMs } },
        @{Label = 'Max (ms)'; Expression = { $_.MaxMs } },
        @{Label = 'Failure %'; Expression = { $_.FailureRate } } -AutoSize | Out-Host

    # Verdict: compare the current resolver against the fastest healthy alternative
    $current = $summary | Where-Object { $_.Resolver -like 'Current*' } | Select-Object -First 1
    $bestAlternative = $summary | Where-Object { $_.Resolver -notlike 'Current*' -and $null -ne $_.AvgMs -and $_.FailureRate -lt 20 } |
        Sort-Object -Property AvgMs | Select-Object -First 1

    Write-Host ""
    if (-not $current) {
        Write-ColorOutput "Current system resolver was not tested (skipped or undetectable) - no comparison available." -ForegroundColor Gray
    }
    elseif ($null -eq $current.AvgMs -or $current.FailureRate -ge 20) {
        Write-ColorOutput "VERDICT: The current DNS resolver ($($current.ServerIP)) is failing or timing out on a significant share of queries ($($current.FailureRate)%). This is a strong candidate for the 'slow internet' complaint even if raw bandwidth is fine." -ForegroundColor Red
    }
    elseif ($bestAlternative -and $current.AvgMs -gt ([math]::Max(40, $bestAlternative.AvgMs * 1.5))) {
        Write-ColorOutput "VERDICT: The current DNS resolver ($($current.ServerIP), avg $($current.AvgMs)ms) is notably slower than $($bestAlternative.Resolver) (avg $($bestAlternative.AvgMs)ms). DNS resolution is a plausible cause of the perceived slowness - consider switching the customer to a faster public resolver or checking the router/ISP DNS." -ForegroundColor Yellow
    }
    else {
        Write-ColorOutput "VERDICT: The current DNS resolver ($($current.ServerIP), avg $($current.AvgMs)ms) performs comparably to the public resolvers tested. DNS resolution speed is unlikely to explain a 'slow internet' complaint here - look elsewhere (Wi-Fi, device, application-level issues)." -ForegroundColor Green
    }

    if ($ExportCsvPath) {
        $allDetailResults | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host ""
        Write-ColorOutput "Detailed results exported to $ExportCsvPath" -ForegroundColor Gray
    }

    exit 0
}
catch {
    Write-Error "An unexpected error occurred: $_"
    exit 1
}
finally {
    $ProgressPreference = 'Continue'
}
#EndRegion Main Execution
