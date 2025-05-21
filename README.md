# PowerShell Script Shortcuts

Use the aliases below to quickly run common admin tasks via `irm | iex` in PowerShell.

---

## Quick Aliases

| Alias       | Script                         | Description                                                |
|-------------|--------------------------------|------------------------------------------------------------|
| `/speedtest` | `Run-Speedtest.ps1`           | Run and auto-update the latest Ookla Speedtest CLI.       |
| `/addwifi`   | `Add-WirelessNetwork.ps1`     | Add a Wi-Fi profile using SSID and password.              |
| `/reckonfw`  | `Configure-ReckonFirewall.ps1`| Add/remove firewall rules for Reckon Accounts.            |
| `/ods`       | `Check-OneDriveSyncHealth.ps1`| Check synced OneDrive file count and flag if over 280k.   |

---

## Usage Examples

```powershell
# Speedtest CLI
irm https://ps.cqts.com.au/speedtest | iex

# Add a wireless profile
irm https://ps.cqts.com.au/addwifi | iex -- "MySSID" "MySecretPassword"

# Configure firewall rules for Reckon Accounts
irm https://ps.cqts.com.au/reckonfw | iex

# Check OneDrive sync health
irm https://ps.cqts.com.au/ods | iex

# Test SMTP Authentication
irm https://ps.cqts.com.au/Test-SMTPAuthentication.ps1 -SmtpServer "smtp.office365.com" -SmtpPort 587 -Encryption STARTTLS -Username "user@domain.com" -Password "MyAppPassword"