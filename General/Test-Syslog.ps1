$server = '157.211.0.101'    # remote syslog server IP or FQDN
$port   = 514
$facility = 1          # numeric facility (you can change)
$severity = 6          # numeric severity (6 = informational)
$pri = $facility*8 + $severity
$timestamp = (Get-Date).ToString('MMM dd HH:mm:ss')
$hostname = $env:COMPUTERNAME
$app = 'WinTest'
$msg = "<$pri>$timestamp $hostname ${app}: Syslog test from Windows"

$udp = New-Object System.Net.Sockets.UdpClient
$bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
$udp.Send($bytes, $bytes.Length, $server, $port) | Out-Null
$udp.Close()
Write-Host "Sent UDP syslog to ${server}:$port -> $msg"
