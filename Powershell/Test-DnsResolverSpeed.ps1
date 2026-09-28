<#
.SYNOPSIS
    Benchmarks DNS resolution speed against the customer's current resolver(s) and a set of public resolvers.

.DESCRIPTION
    Raw bandwidth speed tests (Run-Speedtest.ps1) don't catch one of the most common causes of a
    customer saying "the internet feels slow": slow or flaky DNS resolution. Every new site, image
    host, or CDN endpoint has to be resolved before the browser can even open a connection, so a
    sluggish or unreliable resolver can make a fast connection feel slow.

    This script:
    - Detects the DNS server(s) currently configured on every active network adapter, and labels
      each one with the interface it belongs to (Ethernet / Wi-Fi / Cellular) - useful on devices
      with multiple simultaneously-active connections (e.g. Wi-Fi + a 5G/mobile broadband adapter)
    - Times resolution of a set of common domains against those resolvers and several well-known
      public resolvers (Cloudflare, Google, Quad9, OpenDNS by default)
    - Runs multiple queries per domain to get an average, min/max, and jitter (standard deviation)
    - Enforces a hard per-query timeout and quickly probes each resolver first, so a completely
      unreachable/firewalled resolver (common on carrier-NAT mobile broadband) fails fast instead
      of hanging for minutes waiting out the OS resolver's own retry/timeout behaviour
    - Reports failure/timeout rates per resolver
    - Flags whether each current resolver looks meaningfully slower or less reliable than the
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

.PARAMETER TimeoutSeconds
    Hard timeout applied to every individual DNS query. A query that doesn't complete within this
    window is counted as a failure and abandoned rather than waiting on the OS resolver's own
    (much longer) internal retry/timeout behaviour. Default is 2 seconds.

.PARAMETER ExcludeCurrentDns
    Skips auto-detecting and testing the currently configured system DNS server(s). By default the
    current resolver(s) on every active adapter are always included first so they can be compared
    against the public resolvers.

.PARAMETER SkipCacheBust
    Skips clearing the local DNS client cache between queries. Cache-busting requires an elevated
    session; without it, repeat queries for the same name may return near-instantly from the local
    cache regardless of which resolver actually answered, understating real-world latency.

.PARAMETER ExportCsvPath
    Optional path to export the detailed per-domain, per-resolver results as CSV.

.EXAMPLE
    .\Test-DnsResolverSpeed.ps1
    Detects the current DNS server(s) per active interface, tests them plus the default public
    resolvers against the default domain list, and prints a summary table with a verdict per interface.

.EXAMPLE
    .\Test-DnsResolverSpeed.ps1 -QueryCount 10 -TimeoutSeconds 3 -ExportCsvPath C:\Temp\dns-results.csv
    Runs a more thorough test (10 queries per domain, 3s timeout) and exports the raw results to CSV.

.EXAMPLE
    .\Test-DnsResolverSpeed.ps1 -Resolvers "ISP=203.0.113.10","Router=192.168.1.1"
    Tests only the specified resolvers (plus the detected current resolver(s)) instead of the
    public resolver defaults.

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
    [ValidateRange(1, 30)]
    [int]$TimeoutSeconds = 2,

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
$timeoutMs = $TimeoutSeconds * 1000

if (-not $isAdmin -and -not $SkipCacheBust) {
    Write-Warning "Not running elevated - local DNS cache cannot be cleared between queries. Repeat lookups of the same name may read from cache and understate real latency. Run as Administrator for the most accurate results."
}

# Shared runspace pool used to enforce a hard timeout per DNS query (Resolve-DnsName has no
# reliable built-in timeout - an unreachable/firewalled resolver can otherwise hang for the OS
# resolver's own internal retry window, which is what made this test appear to "get stuck").
$script:DnsRunspacePool = [runspacefactory]::CreateRunspacePool(1, 5)
$script:DnsRunspacePool.Open()
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

function Get-InterfaceTypeLabel {
    <#
    .SYNOPSIS
        Classifies a network adapter as Ethernet / Wi-Fi / Cellular based on its media type and description.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$InterfaceIndex)

    $adapter = Get-NetAdapter -InterfaceIndex $InterfaceIndex -ErrorAction SilentlyContinue
    if (-not $adapter) { return 'Unknown' }

    if ($adapter.InterfaceDescription -match 'Mobile Broadband|WWAN|Cellular|Snapdragon|Wireless WAN|\bLTE\b|\b5G\b') {
        return 'Cellular'
    }

    switch -Regex ($adapter.MediaType) {
        '802\.3'  { return 'Ethernet' }
        '802\.11' { return 'Wi-Fi' }
        default   { return $adapter.Name }
    }
}

function Get-CurrentDnsServers {
    <#
    .SYNOPSIS
        Returns the IPv4 DNS servers configured on adapters that are actually up and not virtual/loopback,
        each labelled with the interface (and interface type) it was found on.
    #>
    [CmdletBinding()]
    param()

    $found = [System.Collections.Generic.List[object]]::new()

    try {
        $entries = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.ServerAddresses.Count -gt 0 }

        foreach ($entry in $entries) {
            $adapter = Get-NetAdapter -InterfaceIndex $entry.InterfaceIndex -ErrorAction SilentlyContinue
            if (-not $adapter -or $adapter.Status -ne 'Up') { continue }

            $typeLabel = Get-InterfaceTypeLabel -InterfaceIndex $entry.InterfaceIndex

            foreach ($ip in $entry.ServerAddresses) {
                if ($ip -match '^127\.' -or $ip -match '^169\.254\.') { continue }

                $found.Add([PSCustomObject]@{
                    ServerIP        = $ip
                    InterfaceAlias  = $entry.InterfaceAlias
                    InterfaceType   = $typeLabel
                })
            }
        }
    }
    catch {
        Write-Verbose "Could not enumerate current DNS servers: $_"
    }

    return @($found | Sort-Object -Property ServerIP, InterfaceAlias -Unique)
}

function Invoke-DnsQueryWithTimeout {
    <#
    .SYNOPSIS
        Runs Resolve-DnsName on a pooled runspace with a hard wall-clock timeout.

    .OUTPUTS
        System.Double milliseconds elapsed on success, or $null on failure/timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Domain,

        [Parameter(Mandatory)]
        [string]$ServerIP,

        [Parameter(Mandatory)]
        [int]$TimeoutMs
    )

    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:DnsRunspacePool
    [void]$ps.AddScript({
        param($Domain, $ServerIP)
        Resolve-DnsName -Name $Domain -Server $ServerIP -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
    }).AddArgument($Domain).AddArgument($ServerIP)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $asyncResult = $ps.BeginInvoke()
    $completed = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs)
    $sw.Stop()

    try {
        if (-not $completed) {
            Write-Verbose "Query for $Domain via $ServerIP timed out after ${TimeoutMs}ms"
            try { $ps.Stop() } catch { Write-Verbose "Failed to stop timed-out runspace: $_" }
            return $null
        }

        $null = $ps.EndInvoke($asyncResult)
        if ($ps.HadErrors) {
            $errMsg = ($ps.Streams.Error | Select-Object -First 1).ToString()
            Write-Verbose "Query for $Domain via $ServerIP failed: $errMsg"
            return $null
        }

        return $sw.Elapsed.TotalMilliseconds
    }
    catch {
        Write-Verbose "Query for $Domain via $ServerIP failed: $_"
        return $null
    }
    finally {
        $ps.Dispose()
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
        [bool]$BustCache,

        [Parameter(Mandatory)]
        [int]$TimeoutMs
    )

    if ($BustCache) {
        try { Clear-DnsClientCache -ErrorAction Stop } catch { Write-Verbose "Cache clear failed: $_" }
    }

    return Invoke-DnsQueryWithTimeout -Domain $Domain -ServerIP $ServerIP -TimeoutMs $TimeoutMs
}

function Test-ResolverReachable {
    <#
    .SYNOPSIS
        Quickly probes a resolver with up to two lookups before committing to the full test matrix,
        so a dead/firewalled resolver (e.g. an internal carrier-NAT address on a mobile broadband
        adapter) is skipped in seconds instead of hanging through the full domain x query-count matrix.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerIP,

        [Parameter(Mandatory)]
        [string[]]$ProbeDomains,

        [Parameter(Mandatory)]
        [int]$TimeoutMs
    )

    foreach ($domain in $ProbeDomains) {
        $ms = Invoke-DnsQueryWithTimeout -Domain $domain -ServerIP $ServerIP -TimeoutMs $TimeoutMs
        if ($null -ne $ms) { return $true }
    }

    return $false
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
        [bool]$BustCache,

        [Parameter(Mandatory)]
        [int]$TimeoutMs
    )

    $results = [System.Collections.Generic.List[object]]::new()

    $probeDomains = @($DomainList | Select-Object -First 2)
    if (-not (Test-ResolverReachable -ServerIP $ServerIP -ProbeDomains $probeDomains -TimeoutMs $TimeoutMs)) {
        Write-ColorOutput "  -> $ResolverName ($ServerIP) did not respond to a quick probe - marking unreachable and skipping the full test." -ForegroundColor Red

        foreach ($domain in $DomainList) {
            $results.Add([PSCustomObject]@{
                Resolver = $ResolverName
                ServerIP = $ServerIP
                Domain   = $domain
                Samples  = 0
                Failures = $Count
                AvgMs    = $null
                MinMs    = $null
                MaxMs    = $null
            })
        }

        return $results
    }

    foreach ($domain in $DomainList) {
        $samples = [System.Collections.Generic.List[double]]::new()
        $failures = 0

        for ($i = 0; $i -lt $Count; $i++) {
            $ms = Measure-DnsQuery -Domain $domain -ServerIP $ServerIP -BustCache $BustCache -TimeoutMs $TimeoutMs
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

    # Build the ordered list of resolvers to test: Name -> { IP, Interface }
    $resolverMap = [ordered]@{}

    if (-not $ExcludeCurrentDns) {
        $currentServers = Get-CurrentDnsServers
        if ($currentServers.Count -eq 0) {
            Write-Warning "Could not detect the current system DNS server(s) - skipping that comparison."
        } else {
            $typeCounts = @{}
            foreach ($server in $currentServers) {
                if ($typeCounts.ContainsKey($server.InterfaceType)) { $typeCounts[$server.InterfaceType]++ }
                else { $typeCounts[$server.InterfaceType] = 1 }
            }

            $typeSeen = @{}
            foreach ($server in $currentServers) {
                $type = $server.InterfaceType
                if ($typeCounts[$type] -gt 1) {
                    if ($typeSeen.ContainsKey($type)) { $typeSeen[$type]++ } else { $typeSeen[$type] = 1 }
                    $label = "Current ($type)-$($typeSeen[$type])"
                } else {
                    $label = "Current ($type)"
                }
                $resolverMap[$label] = [PSCustomObject]@{ ServerIP = $server.ServerIP; InterfaceAlias = $server.InterfaceAlias }
            }
        }
    }

    if ($Resolvers) {
        foreach ($entry in $Resolvers) {
            if ($entry -notmatch '^(?<name>[^=]+)=(?<ip>.+)$') {
                Write-Error "Invalid -Resolvers entry '$entry'. Expected format: Name=IPAddress"
                exit 2
            }
            $resolverMap[$Matches['name']] = [PSCustomObject]@{ ServerIP = $Matches['ip']; InterfaceAlias = $null }
        }
    } else {
        foreach ($key in $defaultPublicResolvers.Keys) {
            $resolverMap[$key] = [PSCustomObject]@{ ServerIP = $defaultPublicResolvers[$key]; InterfaceAlias = $null }
        }
    }

    Write-ColorOutput "DNS Resolver Speed Test" -ForegroundColor Cyan
    Write-ColorOutput "Resolvers under test: $(($resolverMap.Keys | ForEach-Object { "$_ ($($resolverMap[$_].ServerIP))" }) -join ', ')" -ForegroundColor Gray
    Write-ColorOutput "Domains: $($Domains -join ', ')" -ForegroundColor Gray
    Write-ColorOutput "Queries per domain: $QueryCount | Timeout: ${TimeoutSeconds}s | Cache-busting: $(if ($canBustCache) { 'enabled' } else { 'disabled' })" -ForegroundColor Gray
    Write-Host ""

    $allDetailResults = [System.Collections.Generic.List[object]]::new()
    $summary = [System.Collections.Generic.List[object]]::new()

    foreach ($name in $resolverMap.Keys) {
        $ip = $resolverMap[$name].ServerIP
        $iface = $resolverMap[$name].InterfaceAlias
        Write-ColorOutput "Testing $name ($ip)$(if ($iface) { " via $iface" })..." -ForegroundColor Yellow

        $detail = @(Test-DnsResolver -ResolverName $name -ServerIP $ip -DomainList $Domains -Count $QueryCount -BustCache $canBustCache -TimeoutMs $timeoutMs)
        $allDetailResults.AddRange($detail)

        $validAverages = $detail | Where-Object { $null -ne $_.AvgMs } | Select-Object -ExpandProperty AvgMs
        $totalSamples = ($detail | Measure-Object -Property Samples -Sum).Sum
        $totalFailures = ($detail | Measure-Object -Property Failures -Sum).Sum
        $totalQueries = $totalSamples + $totalFailures

        $summary.Add([PSCustomObject]@{
            Resolver     = $name
            ServerIP     = $ip
            Interface    = $iface
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
    $sortedSummary | Format-Table -Property Resolver, ServerIP, Interface,
        @{Label = 'Avg (ms)'; Expression = { $_.AvgMs } },
        @{Label = 'Jitter (ms)'; Expression = { $_.JitterMs } },
        @{Label = 'Min (ms)'; Expression = { $_.MinMs } },
        @{Label = 'Max (ms)'; Expression = { $_.MaxMs } },
        @{Label = 'Failure %'; Expression = { $_.FailureRate } } -AutoSize | Out-Host

    # Verdict: compare each current-interface resolver against the fastest healthy public alternative
    $currentResolvers = $summary | Where-Object { $_.Resolver -like 'Current*' }
    $bestAlternative = $summary | Where-Object { $_.Resolver -notlike 'Current*' -and $null -ne $_.AvgMs -and $_.FailureRate -lt 20 } |
        Sort-Object -Property AvgMs | Select-Object -First 1

    Write-Host ""
    if ($currentResolvers.Count -eq 0) {
        Write-ColorOutput "No current system resolver was tested (skipped or undetectable) - no comparison available." -ForegroundColor Gray
    } else {
        foreach ($current in $currentResolvers) {
            if ($null -eq $current.AvgMs -or $current.FailureRate -ge 20) {
                Write-ColorOutput "VERDICT [$($current.Resolver)]: $($current.ServerIP) is failing or timing out on a significant share of queries ($($current.FailureRate)%). This is a strong candidate for the 'slow internet' complaint even if raw bandwidth is fine." -ForegroundColor Red
            }
            elseif ($bestAlternative -and $current.AvgMs -gt ([math]::Max(40, $bestAlternative.AvgMs * 1.5))) {
                Write-ColorOutput "VERDICT [$($current.Resolver)]: $($current.ServerIP) (avg $($current.AvgMs)ms) is notably slower than $($bestAlternative.Resolver) (avg $($bestAlternative.AvgMs)ms). DNS resolution is a plausible cause of the perceived slowness on this interface - consider switching to a faster public resolver or checking the router/ISP DNS." -ForegroundColor Yellow
            }
            else {
                Write-ColorOutput "VERDICT [$($current.Resolver)]: $($current.ServerIP) (avg $($current.AvgMs)ms) performs comparably to the public resolvers tested. DNS resolution speed is unlikely to explain a 'slow internet' complaint on this interface - look elsewhere (Wi-Fi signal, device, application-level issues)." -ForegroundColor Green
            }
        }
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
    if ($script:DnsRunspacePool) {
        $script:DnsRunspacePool.Close()
        $script:DnsRunspacePool.Dispose()
    }
}
#EndRegion Main Execution
