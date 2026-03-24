# Exchange Online Management Scripts

PowerShell scripts for managing Exchange Online mailboxes, permissions, and archiving.

---

## Requirements

- **Exchange Online Management Module**
  ```powershell
  Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser
  ```

- **Microsoft Graph Users Module** *(required by `Enable-ExchOnlineArchive.ps1`)*
  ```powershell
  Install-Module -Name Microsoft.Graph.Users -Scope CurrentUser
  ```

- **Permissions**: Global Administrator or Exchange Administrator role; `User.Read.All` and `Directory.Read.All` for Graph calls

---

## Scripts

### Invoke-ExchOnlineArchiveAudit.ps1

Reports mailbox size and in-place archive status; optionally enables archiving for mailboxes below a configurable free-space threshold.

**Synopsis:**
Read-only audit by default. Pass `-EnableArchive` to act on flagged mailboxes. Supports `-WhatIf` and single-mailbox scoping.

**Parameters:**
- `-FreeSpaceThresholdPercent` - Flag mailboxes below this % free space (default: `25`, range: 1–99)
- `-EnableArchive` - Enable archiving on qualifying mailboxes (omit for report-only)
- `-UserPrincipalName` - Scope to a single mailbox by UPN
- `-OutputPath` - Full path for the exported CSV (default: timestamped file in Documents)
- `-SkipConnect` - Skip `Connect-ExchangeOnline` if a session is already active

**Usage:**
```powershell
# Audit all mailboxes (no changes made)
.\Invoke-ExchOnlineArchiveAudit.ps1

# Enable archiving for mailboxes with < 30% free space
.\Invoke-ExchOnlineArchiveAudit.ps1 -EnableArchive -FreeSpaceThresholdPercent 30

# Preview which mailboxes would be archived (WhatIf)
.\Invoke-ExchOnlineArchiveAudit.ps1 -EnableArchive -WhatIf

# Audit a single mailbox
.\Invoke-ExchOnlineArchiveAudit.ps1 -UserPrincipalName jdoe@contoso.com
```

**Requirements:**
- ExchangeOnlineManagement module only

---

### Enable-ExchOnlineArchive.ps1

Scans all user mailboxes for size, quota, and archive status; retrieves assigned licenses via Microsoft Graph; and automatically enables in-place archives for mailboxes below 25% free space.

**Synopsis:**
Comprehensive archive-enablement script with license reporting. Enables archives automatically (unless `-ReportOnly` or `-WhatIf` is used) and exports a CSV named `Mailbox_Report_<CompanyName>_yyyyMMdd.csv`.

**Parameters:**
- `-ReportOnly` - Generate report without enabling any archives
- `-LogPath` - Folder path where the CSV report is saved (default: Documents folder)

**Usage:**
```powershell
# Enable archives for qualifying mailboxes and generate report
.\Enable-ExchOnlineArchive.ps1

# Report only — no changes made
.\Enable-ExchOnlineArchive.ps1 -ReportOnly

# Simulation mode
.\Enable-ExchOnlineArchive.ps1 -WhatIf

# Save report to a custom path
.\Enable-ExchOnlineArchive.ps1 -ReportOnly -LogPath "C:\Reports"
```

**Requirements:**
- ExchangeOnlineManagement module
- Microsoft.Graph.Users module
- `User.Read.All` and `Directory.Read.All` Graph permissions

---

### Get-AllMailboxPermissions.ps1

Generates a user-centric delegated permissions report for all Exchange Online mailboxes.

**Synopsis:**
Enumerates Full Access, Send As, and Send on Behalf permissions across all mailboxes, then pivots results so each row shows a delegate user and which mailbox they have access to with boolean flags for each permission type.

**Parameters:**
- `-OutputPath` - Path for CSV output (default: `.\MailboxDelegates_ByUser.csv`)
- `-ResolveTrusteesToUPN` - Resolves trustee names to UPN/email (performs additional lookups)

**Usage:**
```powershell
# Generate report with default settings
.\Get-AllMailboxPermissions.ps1

# Specify custom output path
.\Get-AllMailboxPermissions.ps1 -OutputPath "C:\Reports\Permissions.csv"

# Resolve trustee identities to UPN
.\Get-AllMailboxPermissions.ps1 -ResolveTrusteesToUPN
```

**Output Format:**
CSV file with columns:
- `DelegateUser` - User with delegated access
- `Mailbox` - Display name of mailbox
- `MailboxUPN` - User principal name of mailbox
- `FullAccess` - Boolean
- `SendAs` - Boolean
- `SendOnBehalf` - Boolean

**Notes:**
- Script automatically connects to Exchange Online if not already connected
- Non-inherited permissions only
- Excludes NT AUTHORITY\SELF
- Can take significant time in large tenants

---

### Get-MailboxAccessByUser.ps1

Shows all mailboxes where a specific user has delegated access.

**Synopsis:**
Checks all mailboxes to identify where the specified user has Full Access, Send As, or Send on Behalf permissions.

**Parameters:**
- `-UPN` (Required) - User principal name to search for

**Usage:**
```powershell
# Find all mailboxes accessible by user
.\Get-MailboxAccessByUser.ps1 -UPN delegateuser@domain.com
```

**Output:**
Table showing:
- `Mailbox` - Email address of mailbox
- `AccessType` - Type of permission (FullAccess, SendAs, SendOnBehalf)

**Notes:**
- Automatically connects to Exchange Online if needed
- Checks all three permission types
- Only shows non-inherited permissions

---

## Common Tasks

### Generate Full Permissions Audit
```powershell
# Connect to Exchange Online
Connect-ExchangeOnline

# Generate comprehensive report
.\Get-AllMailboxPermissions.ps1 -OutputPath "C:\Audit\Permissions_$(Get-Date -Format 'yyyyMMdd').csv"
```

### Check Specific User Access
```powershell
# Find where an employee has mailbox access (useful before offboarding)
.\Get-MailboxAccessByUser.ps1 -UPN employee@domain.com
```

### Enable Archives for Low Free-Space Mailboxes
```powershell
# Preview which mailboxes would be archived (no changes)
.\Invoke-ExchOnlineArchiveAudit.ps1 -EnableArchive -WhatIf

# Enable archives for all mailboxes with < 25% free space
.\Invoke-ExchOnlineArchiveAudit.ps1 -EnableArchive
```

---

## Best Practices

1. **Regular Auditing**: Run permission reports quarterly to ensure compliance
2. **Archive Licensing**: Verify licensing before enabling archives
3. **Documentation**: Keep records of delegated permissions for security audits
4. **Least Privilege**: Review and remove unnecessary delegated permissions

---

## Author

Raymond Slater
https://github.com/razer86/scripts
