# PowerShell Scripts

PowerShell automation scripts for Windows administration, Microsoft 365, Azure, and system management.

---

## Quick Access via Web Shortcuts

Use the aliases below to quickly run common admin tasks from PowerShell.

> Scripts that take no arguments use `irm | iex`. Scripts that require arguments use the scriptblock pattern so parameters can be passed directly.

| Alias        | Script                            | Description                                                |
|--------------|-----------------------------------|------------------------------------------------------------|
| `/speedtest` | `Run-Speedtest.ps1`               | Run and auto-update the latest Ookla Speedtest CLI.        |
| `/addwifi`   | `Add-WirelessNetwork.ps1`         | Add a Wi-Fi profile using SSID and password.               |
| `/reckonfw`  | `Configure-ReckonFirewall.ps1`    | Add/remove firewall rules for Reckon Accounts.             |
| `/ods`       | `Check-OneDriveSyncHealth.ps1`    | Check synced OneDrive file count and flag if over 280k.    |
| `/kfm`       | `Intune/Set-OneDriveConfig.ps1`   | Apply OneDrive KFM and sync policies (requires `-TenantID`). |

### Usage Examples

```powershell
# Speedtest CLI
irm https://ps.cqts.com.au/speedtest | iex

# Add a wireless profile (SSID and password passed as arguments)
& ([scriptblock]::Create((irm https://ps.cqts.com.au/addwifi))) "MySSID" "MyPassword"

# Configure firewall rules for Reckon Accounts
irm https://ps.cqts.com.au/reckonfw | iex

# Check OneDrive sync health
irm https://ps.cqts.com.au/ods | iex

# Apply OneDrive KFM / sync policies
& ([scriptblock]::Create((irm https://ps.cqts.com.au/kfm))) -TenantID 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

---

## All Available Scripts

### Exchange Online Management

Scripts for managing Exchange Online mailboxes, permissions, and archiving.

See [`Exchange Online/README.md`](Exchange%20Online/README.md) for detailed documentation.

| Script | Description |
| ------ | ----------- |
| `Invoke-ExchOnlineArchiveAudit.ps1` | Audits mailbox size and archive status; optionally enables archiving for mailboxes below a configurable free-space threshold |
| `Enable-ExchOnlineArchive.ps1` | Scans all mailboxes, reports licensing via Graph, and auto-enables archives for mailboxes with < 25% free space |
| `Get-AllMailboxPermissions.ps1` | Generates user-centric delegated permissions report (FullAccess, SendAs, SendOnBehalf) |
| `Get-MailboxAccessByUser.ps1` | Shows all mailboxes where a specific user has delegated access |
| `Get-MailboxReport.ps1` | Generates a full tenant mailbox summary report (HTML + CSVs) for admin handover |

### Azure Management

Scripts for automating Azure AD app registrations and service principal configuration.

See [`Azure/README.md`](Azure/README.md) for detailed documentation.

| Script                        | Description                                                     |
|-------------------------------|-----------------------------------------------------------------|
| `Create-AzureMailSendApp.ps1` | Creates Azure App Registration with Graph Mail.Send permissions |
| `Create-HuduAzureApp.ps1`     | Creates Azure App Registration for Hudu integration             |

### Atera RMM

Scripts for interacting with the Atera RMM API.

| Script                  | Description                                                                                                      |
|-------------------------|------------------------------------------------------------------------------------------------------------------|
| `Get-AteraAgents.ps1`   | Exports all Atera agents to CSV with device details, flags stale agents (90+ days), and optionally removes them |

**Usage:**

```powershell
# Export all agents
.\Atera\Get-AteraAgents.ps1

# Preview stale agent removal
.\Atera\Get-AteraAgents.ps1 -RemoveStale -WhatIf

# Export stale agents to a separate CSV
.\Atera\Get-AteraAgents.ps1 -RemoveStale -ListOnly
```

**Configuration:** Copy `config.psd1.example` to `config.psd1` and add your API key. The `.psd1` is gitignored.

### Windows Administration

General Windows system administration and troubleshooting utilities.

| Script | Description |
| ------ | ----------- |
| `Add-WirelessNetwork.ps1` | Adds wireless network profile with SSID and password |
| `Check-OneDriveSyncHealth.ps1` | Checks OneDrive sync status and file count (warns if >280k files) |
| `Configure-ReckonFirewall.ps1` | Configures Windows Firewall rules for Reckon Accounts software |
| `Fix-OutlookIMAPFolders.ps1` | Converts Outlook IMAP folders (IPF.Imap) to standard folders (IPF.Note) |
| `Get-LastBootReason.ps1` | Determines last boot time and classifies shutdown reason (planned, unexpected, crash, etc.) |
| `Run-Speedtest.ps1` | Downloads and runs latest Ookla Speedtest CLI, auto-updates if outdated |
| `Test-PantherMonitorSize.ps1` | Detects oversized `C:\Windows\Panther\monitor` folder and remediates leftover `WinSetupMon` driver auto-start (designed for RMM/Intune detection) |
| `Test-SMTPAuthentication.ps1` | Tests SMTP authentication against mail servers (supports STARTTLS, SSL) |

### Outlook Archive Automation

Scripts for automatically routing Outlook inbox emails into folders based on sender domain or rc+ address mappings.

| Script | Description |
| ------ | ----------- |
| `OutlookArchive/Invoke-InboxArchive.ps1` | Moves inbox emails into subfolders mapped by sender domain |
| `OutlookArchive/Invoke-RCInboxArchive.ps1` | Archives rc@neconnect.com.au inbox emails using rc+tag address mappings |
| `OutlookArchive/Add-DomainMappings.ps1` | Reads `UnmappedDomains.csv` and creates the corresponding Outlook folders |
| `OutlookArchive/Get-InboxUnmappedDomains.ps1` | Scans inbox for sender domains not yet mapped to a folder |
| `OutlookArchive/Get-RCInboxMappings.ps1` | Discovers rc+tag address mappings from existing Outlook folders |
| `OutlookArchive/Get-OutlookFolders.ps1` | Lists all folders in a mailbox store |
| `OutlookArchive/Get-OutlookStores.ps1` | Lists all accounts/stores currently open in Outlook |
| `OutlookArchive/Get-SenderDiagnostics.ps1` | Samples skipped inbox items to help diagnose mapping gaps |
| `OutlookArchive/Test-RCAddressResolution.ps1` | Tests rc+ address resolution against the configured mappings |

---

### Migration

| Script | Description |
| ------ | ----------- |
| `Migration/Move-SharedFolder.ps1` | End-to-end shared folder migration: Robocopy with retries, ACL backup/restore, and junction point creation at the old path |

---

### Intune Deployment

Scripts for applying Intune-style policies to devices, suitable for direct execution, RMM, or remote scriptblock delivery.

| Script | Description |
| ------ | ----------- |
| `Intune/Set-OneDriveConfig.ps1` | Applies OneDrive ADMX policies under `HKLM:\SOFTWARE\Policies\Microsoft\OneDrive` (Silent SSO, KFM for Desktop/Documents/Pictures, Files On-Demand, Sync Admin Reports, PST sync block) and restarts OneDrive in user context (skipped when running as SYSTEM) |

**Usage:**

```powershell
# Remote execution
& ([scriptblock]::Create((irm https://ps.cqts.com.au/kfm))) -TenantID 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

# Local execution
.\Intune\Set-OneDriveConfig.ps1 -TenantID 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

**Requirements:** Must run as Administrator. Tenant ID is mandatory.

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
<https://github.com/razer86/scripts>
