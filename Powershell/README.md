# PowerShell Scripts

PowerShell automation scripts for Windows administration, Microsoft 365, Azure, and system management.

---

## Quick Access via Web Shortcuts

Use the aliases below to quickly run common admin tasks via `irm | iex` in PowerShell.

| Alias        | Script                         | Description                                                |
|-----------_--|--------------------------------|------------------------------------------------------------|
| `/speedtest` | `Run-Speedtest.ps1`            | Run and auto-update the latest Ookla Speedtest CLI.        |
| `/addwifi`   | `Add-WirelessNetwork.ps1`      | Add a Wi-Fi profile using SSID and password.               |
| `/reckonfw`  | `Configure-ReckonFirewall.ps1` | Add/remove firewall rules for Reckon Accounts.             |
| `/ods`       | `Check-OneDriveSyncHealth.ps1` | Check synced OneDrive file count and flag if over 280k.    |

### Usage Examples

```powershell
# Speedtest CLI
irm https://ps.cqts.com.au/speedtest | iex

# Add a wireless profile
irm https://ps.cqts.com.au/addwifi | iex

# Configure firewall rules for Reckon Accounts
irm https://ps.cqts.com.au/reckonfw | iex

# Check OneDrive sync health
irm https://ps.cqts.com.au/ods | iex
```

---

## All Available Scripts

### Exchange Online Management

Scripts for managing Exchange Online mailboxes, permissions, and archiving.

See [`Exchange Online/README.md`](Exchange%20Online/README.md) for detailed documentation.

| Script | Description |
|--------|-------------|
| `Enable-ExchOnlineArchive.ps1` | Enables archive mailboxes for users |
| `Get-AllMailboxPermissions.ps1` | Generates user-centric delegated permissions report (FullAccess, SendAs, SendOnBehalf) |
| `Get-MailboxAccessByUser.ps1` | Shows all mailboxes where a specific user has delegated access |

### Azure Management

Scripts for automating Azure AD app registrations and service principal configuration.

See [`Azure/README.md`](Azure/README.md) for detailed documentation.

| Script | Description |
|--------|-------------|
| `Create-AzureMailSendApp.ps1` | Creates Azure App Registration with Graph Mail.Send permissions |
| `Create-HuduAzureApp.ps1` | Creates Azure App Registration for Hudu integration |

### Windows Administration

General Windows system administration and troubleshooting utilities.

| Script | Description |
|--------|-------------|
| `Add-WirelessNetwork.ps1` | Adds wireless network profile with SSID and password |
| `Check-OneDriveSyncHealth.ps1` | Checks OneDrive sync status and file count (warns if >280k files) |
| `Configure-ReckonFirewall.ps1` | Configures Windows Firewall rules for Reckon Accounts software |
| `Fix-OutlookIMAPFolders.ps1` | Converts Outlook IMAP folders (IPF.Imap) to standard folders (IPF.Note) |
| `Get-LastBootReason.ps1` | Determines last boot time and classifies shutdown reason (planned, unexpected, crash, etc.) |
| `Run-Speedtest.ps1` | Downloads and runs latest Ookla Speedtest CLI, auto-updates if outdated |
| `Test-SMTPAuthentication.ps1` | Tests SMTP authentication against mail servers (supports STARTTLS, SSL) |

---

## Requirements

Most scripts require one or more of the following:

- **Windows PowerShell 5.1** or **PowerShell 7+**
- **Exchange Online Management Module** - For Exchange scripts
  ```powershell
  Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser
  ```
- **Microsoft Graph PowerShell SDK** - For Azure/Graph scripts
  ```powershell
  Install-Module -Name Microsoft.Graph -Scope CurrentUser
  ```

Specific requirements are documented in each script's help section and category README.

---

## Usage

All scripts include comment-based help. View usage information with:

```powershell
Get-Help .\ScriptName.ps1 -Full
```

Most scripts support common parameters like `-Verbose` and `-WhatIf` where applicable.

---

## Author

Raymond Slater
https://github.com/razer86/scripts
