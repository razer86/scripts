# Exchange Online Management Scripts

PowerShell scripts for managing Exchange Online mailboxes, permissions, and archiving.

---

## Requirements

- **Exchange Online Management Module**
  ```powershell
  Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser
  ```

- **Permissions**: Global Administrator or Exchange Administrator role

---

## Scripts

### Enable-ExchOnlineArchive.ps1

Enables archive mailboxes for Exchange Online users.

**Synopsis:**
Automates the process of enabling archive mailboxes for users who need additional mailbox storage.

**Parameters:**
- `-Identity` - User principal name or email address
- `-AutoExpandingArchive` - Enable auto-expanding archive (optional)

**Usage:**
```powershell
# Enable archive for a single user
.\Enable-ExchOnlineArchive.ps1 -Identity user@domain.com

# Enable auto-expanding archive
.\Enable-ExchOnlineArchive.ps1 -Identity user@domain.com -AutoExpandingArchive
```

**Requirements:**
- User must have Exchange Online Plan 2 or appropriate license
- Auto-expanding archive requires E3/E5 license

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

### Bulk Enable Archives
```powershell
# Enable archives for all users in a CSV
Import-Csv users.csv | ForEach-Object {
    .\Enable-ExchOnlineArchive.ps1 -Identity $_.UserPrincipalName
}
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
