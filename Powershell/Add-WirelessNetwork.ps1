<#
.SYNOPSIS
    Adds a Wi-Fi profile for WPA2-PSK networks using SSID and password.

.DESCRIPTION
    Supports direct use via PowerShell or one-liner remote execution via `irm | iex`.
    Accepts SSID and PSK as command-line arguments ($args[0], $args[1]).

.EXAMPLE
    irm https://ps.cqts.com.au/addwifi | iex -- "MySSID" "MyPassword"

.NOTES
	Author: Raymond Slater
	URL: https://ps.cqts.com.au/addwifi
#>

# If parameters weren't explicitly passed, allow falling back to $args[0] and $args[1]
param (
    [string]$SSID = $args[0],
    [string]$PSK  = $args[1]
)

if (-not $SSID -or -not $PSK) {
    Write-Error "Usage: irm https://ps.cqts.com.au/addwifi | iex -- <SSID> <Password>"
    return
}

# Generate a unique temp filename
$guid = New-Guid
$HexSSID = ($SSID.ToCharArray() | ForEach-Object { [System.String]::Format("{0:X}", [byte][char]$_) }) -join ""
$profilePath = Join-Path $env:TEMP "$guid.SSID"

# Build the XML profile
$ProfileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
	<name>$($SSID)</name>
	<SSIDConfig>
		<SSID>
			<hex>$($HexSSID)</hex>
			<name>$($SSID)</name>
		</SSID>
	</SSIDConfig>
	<connectionType>ESS</connectionType>
	<connectionMode>auto</connectionMode>
	<MSM>
		<security>
			<authEncryption>
				<authentication>WPA2PSK</authentication>
				<encryption>AES</encryption>
				<useOneX>false</useOneX>
			</authEncryption>
			<sharedKey>
				<keyType>passPhrase</keyType>
				<protected>false</protected>
				<keyMaterial>$($PSK)</keyMaterial>
			</sharedKey>
		</security>
	</MSM>
	<MacRandomization xmlns="http://www.microsoft.com/networking/WLAN/profile/v3">
		<enableRandomization>false</enableRandomization>
		<randomizationSeed>1451755948</randomizationSeed>
	</MacRandomization>
</WLANProfile>
"@

# Write the XML and import the profile
$ProfileXml | Out-File -FilePath $profilePath -Encoding UTF8 -Force
netsh wlan add profile filename="$profilePath" user=all | Out-Null
Remove-Item $profilePath -Force
