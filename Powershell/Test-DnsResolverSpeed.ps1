<#
.SYNOPSIS
    Benchmarks DNS resolution speed against the current system resolver(s) and a set of public resolvers.

.DESCRIPTION
    Bandwidth speed tests (Run-Speedtest.ps1) don't catch slow or flaky DNS, a common cause of
    "the internet feels slow" when raw throughput is fine: every new hostname has to resolve before
    a connection can even start.

    This script:
    - Detects the DNS server(s) on every active adapter and labels each by interface type
      (Ethernet / Wi-Fi / Cellular), so multi-homed devices (e.g. Wi-Fi + 5G) get a verdict per interface
    - Queries each resolver directly over raw UDP, bypassing the Windows DNS client. There's no local
      cache to skew results and no need to run elevated (Resolve-DnsName was also observed taking
      9-13s per query under an elevated token on some systems)
    - Probes each resolver first, so an unreachable one costs two timeouts instead of the full test
    - Reports average, min/max, jitter (standard deviation) and failure rate per resolver, then flags
      any current resolver that is failing or clearly slower than the best public alternative

.PARAMETER Resolvers
    Resolvers to test instead of the public defaults, each as "Name=IPAddress" (e.g. "Router=192.168.1.1").

.PARAMETER Domains
    Domains to resolve. Defaults to a set of popular, high-traffic domains.

.PARAMETER QueryCount
    Queries per domain per resolver. Default 5.

.PARAMETER TimeoutSeconds
    Per-query socket timeout; a query with no response in this window counts as a failure. Default 2.

.PARAMETER ExcludeCurrentDns
    Don't test the system's currently configured DNS server(s).

.PARAMETER ExportCsvPath
    Export per-domain, per-resolver results to this CSV path.

.EXAMPLE
    .\Test-DnsResolverSpeed.ps1
    Tests the current DNS server(s) against the default public resolvers and prints a verdict per interface.

.EXAMPLE
    .\Test-DnsResolverSpeed.ps1 -QueryCount 10 -TimeoutSeconds 3 -ExportCsvPath C:\Temp\dns-results.csv
    Runs a more thorough test and exports the raw results to CSV.

.EXAMPLE
    .\Test-DnsResolverSpeed.ps1 -Resolvers "ISP=203.0.113.10","Router=192.168.1.1"
    Tests the current DNS server(s) against the specified resolvers instead of the public defaults.

.EXAMPLE
    irm https://ps.cqts.com.au/dnsspeed | iex
    Remote execution via short URL (parameters not supported in this mode).

.NOTES
    File Name      : Test-DnsResolverSpeed.ps1
    Author         : Raymond Slater
    Prerequisite   : PowerShell 5.1 or later. Does not require elevation.
    URL            : https://ps.cqts.com.au/dnsspeed

    Must stay safe to run via "irm | iex", which executes in the caller's session: never call `exit`
    (it closes the caller's window), don't change preference variables such as $ErrorActionPreference,
    and don't put validation attributes on parameters without defaults (iex applies them to the empty
    variable and fails).
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
$defaultPublicResolvers = [ordered]@{
    'Cloudflare' = '1.1.1.1'
    'Google'     = '8.8.8.8'
    'Quad9'      = '9.9.9.9'
    'OpenDNS'    = '208.67.222.222'
}

# Verdict thresholds
$failingPct   = 20   # failure rate at or above this = resolver is failing
$slowFloorMs  = 40   # never call a resolver "slow" below this average
$slowFactor   = 1.5  # ...or unless it's this many times slower than the best public resolver
#EndRegion Configuration

#Region Functions
function Get-InterfaceType {
    param([Parameter(Mandatory)]$Adapter)

    if ($Adapter.InterfaceDescription -match 'Mobile Broadband|WWAN|Cellular|Snapdragon|Wireless WAN|\bLTE\b|\b5G\b') {
        return 'Cellular'
    }
    switch -Regex ($Adapter.MediaType) {
        '802\.3'  { return 'Ethernet' }
        '802\.11' { return 'Wi-Fi' }
        default   { return $Adapter.Name }
    }
}

function Get-CurrentDnsServers {
    <#
    .SYNOPSIS
        Returns the IPv4 DNS servers on adapters that are up, with the interface each one belongs to.
    #>
    $found = foreach ($entry in (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
        $adapter = Get-NetAdapter -InterfaceIndex $entry.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $adapter -or $adapter.Status -ne 'Up') { continue }

        $type = Get-InterfaceType -Adapter $adapter
        foreach ($ip in $entry.ServerAddresses) {
            if ($ip -match '^(127|169\.254)\.') { continue }
            [PSCustomObject]@{ ServerIP = $ip; Interface = $entry.InterfaceAlias; InterfaceType = $type }
        }
    }

    @($found | Sort-Object -Property ServerIP, Interface -Unique)
}

function New-DnsQueryPacket {
    <#
    .SYNOPSIS
        Builds a raw DNS query packet (A record, class IN) for a domain and transaction ID.
    #>
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][int]$TransactionId
    )

    $header = [byte[]](
        (($TransactionId -shr 8) -band 0xFF), ($TransactionId -band 0xFF),
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
    $qname.Add(0)

    return $header + $qname.ToArray() + [byte[]](0x00, 0x01, 0x00, 0x01)  # QTYPE=A, QCLASS=IN
}

function Invoke-RawDnsQuery {
    <#
    .SYNOPSIS
        Sends one DNS query to a resolver over UDP. Returns the round-trip in ms, or $null on failure/timeout.
    #>
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$ServerIP,
        [Parameter(Mandatory)][int]$TimeoutMs
    )

    $transactionId = Get-Random -Minimum 0 -Maximum 65536
    $packet = New-DnsQueryPacket -Domain $Domain -TransactionId $transactionId

    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Client.SendTimeout = $TimeoutMs
        $udp.Connect($ServerIP, 53)

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [void]$udp.Send($packet, $packet.Length)
        $remoteEP = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref]$remoteEP)
        $sw.Stop()

        # -shl keeps the operand's type, so a [byte] shifted left 8 silently becomes 0 - cast first.
        $responseId = ([int]$response[0] -shl 8) -bor $response[1]
        $isResponse = $response[2] -band 0x80
        if ($response.Length -lt 4 -or $responseId -ne $transactionId -or -not $isResponse) {
            Write-Verbose "Query for $Domain via $ServerIP got an invalid or mismatched response"
            return $null
        }

        # Any valid response (even NXDOMAIN) means the resolver answered, which is all we're timing.
        return $sw.Elapsed.TotalMilliseconds
    }
    catch {
        Write-Verbose "Query for $Domain via $ServerIP failed: $($_.Exception.Message)"
        return $null
    }
    finally {
        $udp.Close()
    }
}

function Get-SampleStats {
    param([double[]]$Samples)

    if (-not $Samples) {
        return [PSCustomObject]@{ AvgMs = $null; MinMs = $null; MaxMs = $null; JitterMs = $null }
    }

    $m = $Samples | Measure-Object -Average -Minimum -Maximum
    $sumSq = 0.0
    foreach ($s in $Samples) { $sumSq += [math]::Pow($s - $m.Average, 2) }
    $stdDev = if ($Samples.Count -gt 1) { [math]::Sqrt($sumSq / ($Samples.Count - 1)) } else { 0 }

    [PSCustomObject]@{
        AvgMs    = [math]::Round($m.Average, 1)
        MinMs    = [math]::Round($m.Minimum, 1)
        MaxMs    = [math]::Round($m.Maximum, 1)
        JitterMs = [math]::Round($stdDev, 1)
    }
}

function Test-DnsResolver {
    <#
    .SYNOPSIS
        Runs every domain QueryCount times against one resolver, after a quick reachability probe.
    #>
    param(
        [Parameter(Mandatory)][string]$ServerIP,
        [Parameter(Mandatory)][string[]]$DomainList,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][int]$TimeoutMs
    )

    # Probe first: a dead resolver (e.g. carrier-NAT DNS on a 5G adapter) then costs two timeouts,
    # not DomainList x Count of them.
    $reachable = $false
    foreach ($domain in ($DomainList | Select-Object -First 2)) {
        if ($null -ne (Invoke-RawDnsQuery -Domain $domain -ServerIP $ServerIP -TimeoutMs $TimeoutMs)) {
            $reachable = $true
            break
        }
    }

    $allSamples = [System.Collections.Generic.List[double]]::new()
    $detail = foreach ($domain in $DomainList) {
        $samples = [System.Collections.Generic.List[double]]::new()
        if ($reachable) {
            for ($i = 0; $i -lt $Count; $i++) {
                $ms = Invoke-RawDnsQuery -Domain $domain -ServerIP $ServerIP -TimeoutMs $TimeoutMs
                if ($null -ne $ms) { $samples.Add($ms) }
            }
        }
        $allSamples.AddRange($samples)

        $stats = Get-SampleStats -Samples $samples
        [PSCustomObject]@{
            Domain   = $domain
            Samples  = $samples.Count
            Failures = $Count - $samples.Count
            AvgMs    = $stats.AvgMs
            MinMs    = $stats.MinMs
            MaxMs    = $stats.MaxMs
        }
    }

    [PSCustomObject]@{
        Reachable = $reachable
        Samples   = $allSamples.ToArray()
        Queries   = $DomainList.Count * $Count
        Detail    = @($detail)
    }
}
#EndRegion Functions

#Region Main Execution
$badEntries = @($Resolvers | Where-Object { $_ -notmatch '^[^=]+=.+$' })
if ($badEntries) {
    Write-Error "Invalid -Resolvers entry: $($badEntries -join ', '). Expected format: Name=IPAddress"
    return
}

$resolverList = [System.Collections.Generic.List[object]]::new()

if (-not $ExcludeCurrentDns) {
    $currentServers = Get-CurrentDnsServers
    if ($currentServers.Count -eq 0) {
        Write-Warning "Could not detect the current system DNS server(s) - skipping that comparison."
    }

    foreach ($group in ($currentServers | Group-Object -Property InterfaceType)) {
        $n = 0
        foreach ($server in $group.Group) {
            $n++
            $suffix = if ($group.Count -gt 1) { "-$n" } else { '' }
            $resolverList.Add([PSCustomObject]@{
                Name      = "Current ($($group.Name))$suffix"
                ServerIP  = $server.ServerIP
                Interface = $server.Interface
                IsCurrent = $true
            })
        }
    }
}

$otherResolvers = if ($Resolvers) {
    foreach ($entry in $Resolvers) {
        $name, $ip = $entry -split '=', 2
        @{ Name = $name; ServerIP = $ip }
    }
} else {
    foreach ($key in $defaultPublicResolvers.Keys) { @{ Name = $key; ServerIP = $defaultPublicResolvers[$key] } }
}
foreach ($r in $otherResolvers) {
    $resolverList.Add([PSCustomObject]@{ Name = $r.Name; ServerIP = $r.ServerIP; Interface = $null; IsCurrent = $false })
}

Write-Host "DNS Resolver Speed Test" -ForegroundColor Cyan
Write-Host "Resolvers under test: $(($resolverList | ForEach-Object { "$($_.Name) ($($_.ServerIP))" }) -join ', ')" -ForegroundColor Gray
Write-Host "Domains: $($Domains -join ', ')" -ForegroundColor Gray
Write-Host "Queries per domain: $QueryCount | Timeout: ${TimeoutSeconds}s" -ForegroundColor Gray
Write-Host ""

$allDetail = [System.Collections.Generic.List[object]]::new()
$summary = foreach ($resolver in $resolverList) {
    Write-Host "Testing $($resolver.Name) ($($resolver.ServerIP))$(if ($resolver.Interface) { " via $($resolver.Interface)" })..." -ForegroundColor Yellow

    $result = Test-DnsResolver -ServerIP $resolver.ServerIP -DomainList $Domains -Count $QueryCount -TimeoutMs ($TimeoutSeconds * 1000)
    if (-not $result.Reachable) {
        Write-Host "  -> No response to a quick probe - marking unreachable and skipping the full test." -ForegroundColor Red
    }

    foreach ($row in $result.Detail) {
        $allDetail.Add(($row | Select-Object @{ n = 'Resolver'; e = { $resolver.Name } }, @{ n = 'ServerIP'; e = { $resolver.ServerIP } }, *))
    }

    $stats = Get-SampleStats -Samples $result.Samples
    [PSCustomObject]@{
        Resolver    = $resolver.Name
        ServerIP    = $resolver.ServerIP
        Interface   = $resolver.Interface
        IsCurrent   = $resolver.IsCurrent
        AvgMs       = $stats.AvgMs
        JitterMs    = $stats.JitterMs
        MinMs       = $stats.MinMs
        MaxMs       = $stats.MaxMs
        FailureRate = [math]::Round((1 - $result.Samples.Count / $result.Queries) * 100, 1)
    }
}

Write-Host ""
Write-Host "===== Summary (sorted fastest to slowest) =====" -ForegroundColor Cyan
$summary |
    Sort-Object -Property @{ Expression = { if ($null -eq $_.AvgMs) { [double]::MaxValue } else { $_.AvgMs } } } |
    Format-Table -Property Resolver, ServerIP, Interface,
        @{ Label = 'Avg (ms)';    Expression = { $_.AvgMs } },
        @{ Label = 'Jitter (ms)'; Expression = { $_.JitterMs } },
        @{ Label = 'Min (ms)';    Expression = { $_.MinMs } },
        @{ Label = 'Max (ms)';    Expression = { $_.MaxMs } },
        @{ Label = 'Failure %';   Expression = { $_.FailureRate } } -AutoSize |
    Out-Host

$currentResolvers = @($summary | Where-Object IsCurrent)
$best = $summary |
    Where-Object { -not $_.IsCurrent -and $null -ne $_.AvgMs -and $_.FailureRate -lt $failingPct } |
    Sort-Object -Property AvgMs | Select-Object -First 1

if ($currentResolvers.Count -eq 0) {
    Write-Host "No current system resolver was tested (skipped or undetectable) - no comparison available." -ForegroundColor Gray
}
foreach ($current in $currentResolvers) {
    $tag = "VERDICT [$($current.Resolver)]: $($current.ServerIP)"
    if ($null -eq $current.AvgMs -or $current.FailureRate -ge $failingPct) {
        Write-Host "$tag is failing or timing out on $($current.FailureRate)% of queries. This is a strong candidate for the 'slow internet' complaint even if raw bandwidth is fine." -ForegroundColor Red
    }
    elseif ($best -and $current.AvgMs -gt [math]::Max($slowFloorMs, $best.AvgMs * $slowFactor)) {
        Write-Host "$tag (avg $($current.AvgMs)ms) is notably slower than $($best.Resolver) (avg $($best.AvgMs)ms). DNS is a plausible cause of the perceived slowness on this interface - consider a faster public resolver or check the router/ISP DNS." -ForegroundColor Yellow
    }
    else {
        Write-Host "$tag (avg $($current.AvgMs)ms) performs comparably to the public resolvers tested. DNS is unlikely to explain a 'slow internet' complaint on this interface - look elsewhere (Wi-Fi signal, device, application-level issues)." -ForegroundColor Green
    }
}

if ($ExportCsvPath) {
    $allDetail | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Detailed results exported to $ExportCsvPath" -ForegroundColor Gray
}
#EndRegion Main Execution
