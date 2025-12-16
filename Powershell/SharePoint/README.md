# SharePoint Online Management Scripts

PowerShell scripts for SharePoint Online inventory management, migration validation, and file comparison.

---

## Requirements

- **PnP PowerShell Module**
  ```powershell
  Install-Module -Name PnP.PowerShell -Scope CurrentUser
  ```

- **Azure AD App Registration** (for Export-SharePointInventory.ps1)
  - App must be registered in Azure AD
  - Requires appropriate SharePoint permissions
  - Interactive authentication flow supported

- **Configuration File**: `config.json` required for these scripts

---

## Configuration

Create a `config.json` file in the SharePoint directory:

```json
{
  "AppId": "your-app-id",
  "Tenant": "yourtenant.onmicrosoft.com",
  "SiteUrl": "https://yourtenant.sharepoint.com/sites/YourSite",
  "LibraryTitle": "Documents",
  "ReportFolder": "C:\\Reports\\SharePoint",
  "TimestampToleranceSeconds": 2
}
```

**Configuration Fields:**
- `AppId` - Azure AD App Registration client ID
- `Tenant` - Your Microsoft 365 tenant domain
- `SiteUrl` - Full URL to SharePoint site
- `LibraryTitle` - Display name of document library to inventory
- `ReportFolder` - Local path for CSV reports
- `TimestampToleranceSeconds` - Tolerance for timestamp comparison (Compare.ps1)

---

## Scripts

### Export-SharePointInventory.ps1

Exports a comprehensive file inventory from a SharePoint Online document library.

**Synopsis:**
Connects to SharePoint Online using PnP PowerShell and exports a detailed CSV inventory of all files in a specified library. Useful for migration planning, compliance audits, and comparison with on-premises data.

**Parameters:**
- `-ConfigPath` - Path to config.json (optional, defaults to `.\config.json`)

**What It Does:**
1. Loads configuration from `config.json`
2. Connects to SharePoint Online via PnP (interactive MFA)
3. Enumerates all files in specified library (files only, no folders)
4. Exports to CSV with relative paths, sizes, and timestamps

**Usage:**
```powershell
# Export inventory using default config
.\Export-SharePointInventory.ps1

# Use custom config path
.\Export-SharePointInventory.ps1 -ConfigPath "C:\Configs\sharepoint-config.json"
```

**Output:**
Creates CSV file: `SharePoint_<LibraryName>_<Timestamp>.csv`

**CSV Columns:**
- `RelativePath` - Path relative to library root (backslash format)
- `ServerRelativeUrl` - Full SharePoint server-relative URL
- `Length` - File size in bytes
- `LastWriteTimeUtc` - Last modified timestamp (UTC)

**Example Output:**
```
RelativePath,ServerRelativeUrl,Length,LastWriteTimeUtc
Documents\Report.docx,/sites/Contoso/Shared Documents/Documents/Report.docx,45632,2024-01-15 14:23:10
Finance\Budget.xlsx,/sites/Contoso/Shared Documents/Finance/Budget.xlsx,128945,2024-02-20 09:15:33
```

**Notes:**
- Only files are enumerated (folders are excluded)
- Uses pagination (2000 items per page) for large libraries
- URL-decodes paths automatically
- Converts forward slashes to backslashes for compatibility

---

### Compare.ps1

Compares local file inventory against SharePoint inventory to identify discrepancies.

**Synopsis:**
Performs a three-way comparison between local and SharePoint file inventories, identifying files that exist only in one location or have mismatched sizes/timestamps. Essential for migration validation and ongoing sync verification.

**Parameters:**
- `-LocalCsv` - Path to local inventory CSV (optional, auto-detects newest)
- `-SharePointCsv` - Path to SharePoint inventory CSV (optional, auto-detects newest)
- `-ConfigPath` - Path to config.json (optional, defaults to `.\config.json`)

**What It Does:**
1. Loads most recent local and SharePoint inventory CSVs from `ReportFolder`
2. Compares files by relative path
3. Identifies three categories of discrepancies:
   - **Cloud Only** - Files in SharePoint but not local (stale/deleted locally)
   - **Local Only** - Files locally but not in SharePoint (not migrated)
   - **Mismatched** - Files exist in both but differ in size or timestamp

**Usage:**
```powershell
# Auto-detect newest CSVs
.\Compare.ps1

# Specify explicit CSVs
.\Compare.ps1 -LocalCsv "C:\Reports\Local_20240115.csv" -SharePointCsv "C:\Reports\SharePoint_20240115.csv"
```

**Output:**
Creates three CSV files:
1. `CloudOnly_Stale_<Timestamp>.csv` - Files only in SharePoint
2. `LocalOnly_NotYetMigrated_<Timestamp>.csv` - Files only local
3. `Mismatched_SizeOrTimestamp_<Timestamp>.csv` - Files with differences

**Mismatch CSV Columns:**
- `RelativePath` - File path
- `Local_Length` - Local file size
- `Cloud_Length` - SharePoint file size
- `Local_LastWriteUtc` - Local timestamp
- `Cloud_LastWriteUtc` - SharePoint timestamp
- `SizeDifferent` - Boolean
- `TimestampDifferent` - Boolean (considers tolerance)

**Console Summary:**
```
LocalFiles                 : 1523
SharePointFiles            : 1498
CloudOnly_Stale            : 12
LocalOnly_NotYetMigrated   : 37
Mismatched_SizeOrTimestamp : 8
TimestampToleranceSeconds  : 2
OutputFolder               : C:\Reports\SharePoint
```

**Timestamp Tolerance:**
- Configured via `TimestampToleranceSeconds` in config.json
- Allows for minor clock skew between systems
- Default: 2 seconds
- Differences within tolerance are not flagged

---

## Common Workflows

### Initial Migration Planning

```powershell
# 1. Export local file inventory (run on file server)
Get-ChildItem -Path "D:\SharedData" -Recurse -File | Select-Object @{N='RelativePath';E={$_.FullName.Replace('D:\SharedData\','')}}, Length, LastWriteTimeUtc | Export-Csv "Local_SharedData_20240115.csv" -NoTypeInformation

# 2. Export SharePoint inventory
.\Export-SharePointInventory.ps1

# 3. Compare inventories
.\Compare.ps1

# 4. Review discrepancies
Import-Csv "LocalOnly_NotYetMigrated_<timestamp>.csv" | Out-GridView
```

### Post-Migration Validation

```powershell
# After migration, verify all files uploaded correctly
.\Export-SharePointInventory.ps1
.\Compare.ps1

# Check for files not migrated
$notMigrated = Import-Csv "LocalOnly_NotYetMigrated_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($notMigrated) {
    Write-Warning "$($notMigrated.Count) files not migrated"
}

# Check for mismatches
$mismatched = Import-Csv "Mismatched_SizeOrTimestamp_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($mismatched) {
    Write-Warning "$($mismatched.Count) files have discrepancies"
}
```

### Ongoing Sync Monitoring

```powershell
# Schedule as a daily task
$task = {
    Set-Location "C:\Scripts\SharePoint"
    .\Export-SharePointInventory.ps1
    .\Compare.ps1

    # Alert if mismatches found
    $mismatch = Get-ChildItem "Mismatched_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ((Import-Csv $mismatch.FullName).Count -gt 0) {
        Send-MailMessage -To "admin@domain.com" -Subject "SharePoint Sync Issues" -Body "Discrepancies found. Check: $($mismatch.FullName)"
    }
}
```

---

## Troubleshooting

### "Config file not found"
- Ensure `config.json` exists in the script directory
- Or specify path: `.\Export-SharePointInventory.ps1 -ConfigPath "C:\path\to\config.json"`

### "No Local_*.csv found"
- Ensure you've created a local inventory CSV first
- CSV must be in the `ReportFolder` specified in config.json
- Filename must start with `Local_`

### Authentication Failures
- Verify Azure AD app has SharePoint permissions
- Ensure `Sites.Read.All` or `Sites.FullControl.All` granted
- Check app registration is not expired

### Large Library Performance
- Script uses pagination (2000 items/page)
- Very large libraries (>100k items) may take several minutes
- Consider filtering by folder if full library scan is not needed

---

## Best Practices

1. **Regular Inventories**: Export weekly during migrations, monthly for audits
2. **Timestamp Tolerance**: Adjust based on observed clock drift between systems
3. **Archive Reports**: Keep historical comparison reports for compliance
4. **Automation**: Schedule regular comparisons for ongoing sync monitoring
5. **App Permissions**: Use dedicated app with minimal required permissions

---

## Author

Raymond Slater
https://github.com/razer86/scripts
