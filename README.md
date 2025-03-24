# ⚡ PowerShell Script Shortcuts

Use the aliases below to quickly run common admin tasks via `irm | iex` in PowerShell.

---

## 🚀 Quick Aliases

| Alias       | Script                         | Description                                                                                       | Example Command                                                  |
|-------------|--------------------------------|---------------------------------------------------------------------------------------------------|------------------------------------------------------------------|
| `/speedtest` | `Run-Speedtest.ps1`           | Run and auto-update the latest Ookla Speedtest CLI.                                               | `irm https://ps.cqts.com.au/speedtest | iex`                      |
| `/addwifi`   | `Add-WirelessNetwork.ps1`     | Add a Wi-Fi profile using SSID and password.                                                      | `irm https://ps.cqts.com.au/addwifi | iex -- "SSID" "Password"`  |
| `/reckonfw`  | `Configure-ReckonFirewall.ps1`| Add/remove firewall rules and folder permissions for Reckon Accounts (2013–2024).                 | `irm https://ps.cqts.com.au/reckonfw | iex`                       |
| `/ods`       | `Check-OneDriveSyncHealth.ps1`| Check total synced OneDrive file count and flag if over 280k.                                     | `irm https://ps.cqts.com.au/ods | iex`                         |

---
