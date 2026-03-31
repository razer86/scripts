# Hudu Scripts

PowerShell scripts for Hudu documentation management and Azure integration setup.

---

## Requirements

- **PowerShell 7.2+**
- **Hudu API key** — found in Hudu under Administrator > API Keys (not required for `Create-HuduAzureApp.ps1` if pushing to Hudu is not needed)
- A `config.psd1` in this directory (copy from `config.psd1.example` and fill in your values)

---

## Configuration

Copy `config.psd1.example` to `config.psd1` and set your Hudu credentials:

```powershell
@{
    HuduBaseUrl           = 'https://your-hudu-instance.huducloud.com'
    HuduApiKey            = 'your-api-key'
    HuduM365AssetLayoutId = 0      # 0 = auto-discover by name
    HuduM365AssetName     = 'Hudu-M365 Integration'
}
```

`config.psd1` is covered by `.gitignore` and will never be committed. Explicit command-line parameters always override config file values.

---

## Scripts

### Create-HuduAzureApp.ps1

Creates an Azure App Registration for Hudu M365/Intune integration with automatic admin consent and optional direct push to Hudu.

**What It Does:**
1. Installs and imports required Microsoft Graph modules
2. Connects to the customer's Azure tenant via interactive browser login
3. Creates (or reuses) an app registration named `Hudu M365 Integration`
4. Assigns required Microsoft Graph permissions (Directory.Read.All, User.Read.All, Reports.Read.All, Device.Read.All, Group.Read.All)
5. Generates a client secret (default: 24 months validity)
6. **Automatically grants admin consent** — no manual portal action required in most cases
7. Displays credentials in console: Name, Application ID, Tenant ID, Secret Key, Secret Expiry
8. **Optionally** creates or updates a `Hudu-M365 Integration` asset in Hudu with all four credential fields

**Usage:**
```powershell
# Basic — outputs credentials to console only
.\Create-HuduAzureApp.ps1

# Create and push credentials directly to Hudu (recommended)
.\Create-HuduAzureApp.ps1 -HuduCompanyId 'a1b2c3d4e5f6'

# Push using company name (if slug is unknown)
.\Create-HuduAzureApp.ps1 -HuduCompanyName 'Contoso'

# Custom app name and 12-month secret
.\Create-HuduAzureApp.ps1 -AppName 'Contoso M365 App' -SecretExpiryInMonths 12

# Recreate the app from scratch (e.g., if secret leaked)
.\Create-HuduAzureApp.ps1 -Recreate

# Preview mode — no changes made
.\Create-HuduAzureApp.ps1 -WhatIf
```

**Parameters:**
| Parameter | Default | Description |
|---|---|---|
| `-AppName` | `Hudu M365 Integration` | Azure app display name |
| `-SecretExpiryInMonths` | `24` | Secret validity (1–24 months) |
| `-HuduCompanyId` | — | Hudu company slug (12-char hex) or numeric ID |
| `-HuduCompanyName` | — | Exact Hudu company name |
| `-HuduBaseUrl` | from config.psd1 | Hudu instance base URL |
| `-HuduApiKey` | from config.psd1 | Hudu API key |
| `-Recreate` | — | Remove and recreate the app registration |
| `-Remove` | — | Remove the app registration and exit |
| `-SkipModuleCheck` | — | Skip Graph module install/import checks |

**Post-creation:**
1. **Admin consent** is granted automatically. If any permission fails, the Azure Portal opens directly to the API permissions page — click **Grant admin consent** and confirm
2. If Hudu push was configured, verify the asset in the Hudu company
3. If running without Hudu push, copy the console output credentials into Hudu > Admin > Integrations > Microsoft 365 / Intune

---

### Migrate-HuduM365Passwords.ps1

One-shot migration of `Hudu M365 Integration` password vault entries into the structured `Hudu-M365 Integration` asset layout.

**Background:**

The original Hudu M365 integration SOP stored Azure app credentials as a plain password entry, with Application ID, Tenant ID, and Secret Expiry pasted into the notes field. This script reads those entries across all companies and populates the dedicated asset layout with properly typed fields:

| Field | Type |
|---|---|
| Application ID | Text |
| Tenant ID | Text |
| Secret Key | Password |
| Secret Expiry | Date |

**What It Does:**
1. Verifies Hudu API connectivity
2. Discovers the `Hudu-M365 Integration` asset layout (by name or configured ID)
3. Fetches all password entries named `Hudu M365 Integration`
4. For each password: parses the notes for Application ID, Tenant ID, and Secret Expiry; retrieves the decrypted secret; creates or updates the asset for that company
5. Flags any records whose notes could not be parsed for manual review
6. Optionally archives the source password entry after successful migration

**Usage:**
```powershell
# Dry run — preview all changes without writing anything
.\Migrate-HuduM365Passwords.ps1 -WhatIf

# Migrate all passwords
.\Migrate-HuduM365Passwords.ps1

# Migrate a single password by ID (useful for manual retries from the Needs Review list)
.\Migrate-HuduM365Passwords.ps1 -PasswordId 9231

# Migrate and archive source passwords in one pass
.\Migrate-HuduM365Passwords.ps1 -Archive
```

> **Recommended workflow:** run without `-Archive` first, verify the created assets in Hudu, then re-run with `-Archive` to clean up the source password entries.

**Parameters:**
| Parameter | Default | Description |
|---|---|---|
| `-PasswordId` | — | Migrate a single password by Hudu numeric ID instead of scanning all |
| `-PasswordName` | `Hudu M365 Integration` | Name of the source password entries to search for |
| `-AssetLayoutName` | `Hudu-M365 Integration` | Name of the target asset layout in Hudu |
| `-AssetLayoutId` | `0` (auto-discover) | Numeric asset layout ID — skips name lookup when set |
| `-AssetNamePrefix` | `Hudu-M365 Integration` | Prefix for created/updated asset names (`<prefix> - <Company>`) |
| `-HuduBaseUrl` | from config.psd1 | Hudu instance base URL |
| `-HuduApiKey` | from config.psd1 | Hudu API key |
| `-Archive` | — | Archive each source password after successful migration |
| `-WhatIf` | — | Preview mode — no records are created or modified |

**Example output:**
```
  Processing: Contoso (password id: 9300)
    Application ID : 19e65e4f-b37e-4572-ab56-3d863c5a5531
    Tenant ID      : 2d352d10-4bf7-4b02-95e0-95cba8dd3be9
    Secret Expiry  : 2027-12-31
    Secret Key     : (retrieved)
    Created asset: Hudu-M365 Integration - Contoso (id: 18031)

  Migrated:            97
  Needs review:        1
  Failed:              0

  The following passwords could not be parsed — migrate manually:
    - company_id:123 (password id: 4567)
```

---

## Author

Raymond Slater
https://github.com/razer86/scripts
