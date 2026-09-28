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
    - Queries each resolver directly over a raw UDP socket rather than via Resolve-DnsName. This
      avoids the Windows DNS client entirely, so there's no local cache to skew results, no need
      to run elevated, and no dependency on a cmdlet that has been observed to take 9-13 seconds
      per query under an elevated token on some systems (vs single-digit milliseconds unelevated)
    - Times resolution of a set of common domains against those resolvers and several well-known
      public resolvers (Cloudflare, Google, Quad9, OpenDNS by default)
    - Runs multiple queries per domain to get an average, min/max, and jitter (standard deviation)
    - Enforces a hard per-query timeout via the socket itself and quickly probes each resolver
      first, so a completely unreachable/firewalled resolver (common on carrier-NAT mobile
      broadband) fails fast instead of dragging out the full domain x query-count matrix
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
    Hard timeout applied to every individual DNS query's socket. A query that doesn't get a
    response within this window is counted as a failure. Default is 2 seconds.

.PARAMETER ExcludeCurrentDns
    Skips auto-detecting and testing the currently configured system DNS server(s). By default the
    current resolver(s) on every active adapter are always included first so they can be compared
    against the public resolvers.

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
    Prerequisite   : PowerShell 5.1 or later. Does not require an elevated session - DNS queries
                     are sent directly over raw UDP sockets rather than through the OS resolver.

    Exit Codes:
    0 = Success
    2 = Invalid parameters (e.g. malformed -Resolvers entry)

.LINK
    https://learn.microsoft.com/windows-server/networking/dns/dns-top
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

$timeoutMs = $TimeoutSeconds * 1000
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

function New-DnsQueryPacket {
    <#
    .SYNOPSIS
        Builds a raw DNS query packet (A record, class IN) for the given domain and transaction ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Domain,

        [Parameter(Mandatory)]
        [int]$TransactionId
    )

    $header = [byte[]](
        [byte](($TransactionId -shr 8) -band 0xFF), [byte]($TransactionId -band 0xFF),
        0x01, 0x00,  # flags: standard query, recursion desired
        0x00, 0x01,  # QDCOUNT = 1
        0x00, 0x00,  # ANCOUNT = 0
        0x00, 0x00,  # NSCOUNT = 0
        0x00, 0x00   # ARCOUNT = 0
    )

    $qname = [System.Collections.Generic.List[byte]]::new()
    foreach ($label in $Domain.Split('.')) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($label)
        $qname.Add([byte]$bytes.Length)
        $qname.AddRange($bytes)
    }
    $qname.Add(0)  # root terminator

    $qtypeAndClass = [byte[]](0x00, 0x01, 0x00, 0x01)  # QTYPE=A, QCLASS=IN

    return $header + $qname.ToArray() + $qtypeAndClass
}

function Invoke-RawDnsQuery {
    <#
    .SYNOPSIS
        Sends a DNS A-record query directly to a resolver over UDP and times the response.

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

    $transactionId = Get-Random -Minimum 0 -Maximum 65535
    $packet = New-DnsQueryPacket -Domain $Domain -TransactionId $transactionId

    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Client.SendTimeout = $TimeoutMs
        $udp.Connect($ServerIP, 53)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [void]$udp.Send($packet, $packet.Length)

        $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref]$remoteEP)
        $sw.Stop()

        if ($response.Length -lt 4) {
            Write-Verbose "Query for $Domain via $ServerIP got a malformed (too short) response"
            return $null
        }

        # PowerShell's -shl/-shr preserve the operand's own type, so shifting a [byte] element
        # from the response array overflows/truncates silently (e.g. 154 -shl 8 wraps to 0
        # instead of promoting to int) - cast to [int] first or the high byte is lost.
        $responseId = ([int]$response[0] -shl 8) -bor $response[1]
        if ($responseId -ne $transactionId) {
            Write-Verbose "Query for $Domain via $ServerIP got a response with a mismatched transaction ID"
            return $null
        }

        $flags = ([int]$response[2] -shl 8) -bor $response[3]
        $isResponse = ($flags -shr 15) -band 0x1
        if ($isResponse -ne 1) {
            Write-Verbose "Query for $Domain via $ServerIP got a non-response packet"
            return $null
        }

        # Any well-formed response (including NXDOMAIN) shows the resolver is up and answering -
        # that's what this test cares about, not whether the domain itself resolves successfully.
        return $sw.Elapsed.TotalMilliseconds
    }
    catch [System.Net.Sockets.SocketException] {
        Write-Verbose "Query for $Domain via $ServerIP timed out or failed: $($_.Exception.Message)"
        return $null
    }
    catch {
        Write-Verbose "Query for $Domain via $ServerIP failed: $_"
        return $null
    }
    finally {
        if ($udp) { $udp.Close() }
    }
}

function Test-ResolverReachable {
    <#
    .SYNOPSIS
        Quickly probes a resolver with up to two lookups before committing to the full test matrix,
        so a dead/firewalled resolver (e.g. an internal carrier-NAT address on a mobile broadband
        adapter) is skipped in seconds instead of dragging out the full domain x query-count matrix.
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
        $ms = Invoke-RawDnsQuery -Domain $domain -ServerIP $ServerIP -TimeoutMs $TimeoutMs
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
            $ms = Invoke-RawDnsQuery -Domain $domain -ServerIP $ServerIP -TimeoutMs $TimeoutMs
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
    Write-ColorOutput "Queries per domain: $QueryCount | Timeout: ${TimeoutSeconds}s" -ForegroundColor Gray
    Write-Host ""

    $allDetailResults = [System.Collections.Generic.List[object]]::new()
    $summary = [System.Collections.Generic.List[object]]::new()

    foreach ($name in $resolverMap.Keys) {
        $ip = $resolverMap[$name].ServerIP
        $iface = $resolverMap[$name].InterfaceAlias
        Write-ColorOutput "Testing $name ($ip)$(if ($iface) { " via $iface" })..." -ForegroundColor Yellow

        $detail = @(Test-DnsResolver -ResolverName $name -ServerIP $ip -DomainList $Domains -Count $QueryCount -TimeoutMs $timeoutMs)
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
}
#EndRegion Main Execution
