# Azure Management Scripts

PowerShell scripts for automating Azure AD app registrations and service principal configuration.

---

## Requirements

- **Microsoft Graph PowerShell SDK**
  ```powershell
  Install-Module -Name Microsoft.Graph -Scope CurrentUser
  ```

- **Permissions**: Global Administrator or Application Administrator role in Azure AD

---

## Scripts

### Create-AzureMailSendApp.ps1

Creates an Azure App Registration configured for sending email via Microsoft Graph API.

**Synopsis:**
Automates the creation of an Azure AD app with Microsoft Graph Mail.Send application permissions, service principal, and client secret. Designed for app-only authentication scenarios where applications need to send email without user interaction.

**What It Does:**
1. Connects to Microsoft Graph with required scopes
2. Validates user has necessary permissions
3. Creates new app registration (default name: `GraphMailSendApp`)
4. Creates associated service principal
5. Generates client secret
6. Assigns `Mail.Send` application permission to Microsoft Graph API
7. Outputs credentials for use in automation

**Required Permissions:**
The script requests these Graph scopes:
- `Application.ReadWrite.All` - Create app registrations
- `AppRoleAssignment.ReadWrite.All` - Assign permissions
- `Directory.ReadWrite.All` - Create service principals

**Usage:**
```powershell
# Run the script
.\Create-AzureMailSendApp.ps1

# Interactive authentication prompt will appear
# Consent to required permissions when prompted
```

**Output:**
```
App Registration Complete
---------------------------------------------
Tenant ID     : <your-tenant-id>
Client ID     : <app-client-id>
Client Secret : <generated-secret>
---------------------------------------------
```

**Post-Creation Steps:**
1. **Grant Admin Consent**: Navigate to Azure Portal > App Registrations > Your App > API Permissions > Grant admin consent
2. **Save Credentials Securely**: Store the Tenant ID, Client ID, and Client Secret in a secure location (e.g., Azure Key Vault)
3. **Test Authentication**: Verify the app can authenticate and send email

**Using the Credentials:**
```powershell
# Example: Send email using Microsoft Graph PowerShell
$TenantId = "<tenant-id>"
$ClientId = "<client-id>"
$ClientSecret = "<client-secret>"

$SecureSecret = ConvertTo-SecureString -String $ClientSecret -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($ClientId, $SecureSecret)

Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $Credential

# Send email
Send-MgUserMail -UserId "sender@domain.com" -Message @{
    subject = "Test Email"
    body = @{ content = "This is a test email sent via Graph API" }
    toRecipients = @(@{ emailAddress = @{ address = "recipient@domain.com" } })
}
```

**Security Considerations:**
- Application permissions grant access to ALL mailboxes in the tenant
- Consider using Exchange Transport Rules to restrict which mailboxes the app can send from
- Store client secrets in secure vaults, never in source code
- Rotate secrets regularly (recommended: every 90 days)
- Monitor audit logs for unexpected usage

---

### Create-HuduAzureApp.ps1

Creates an Azure App Registration for Hudu documentation platform integration.

**Synopsis:**
Automates the creation of an Azure AD app configured for Hudu integration, enabling automated synchronization of Azure/M365 data into Hudu documentation.

**What It Does:**
1. Creates Azure AD app registration for Hudu
2. Configures required Microsoft Graph API permissions
3. Generates client secret for authentication
4. Outputs credentials for Hudu configuration

**Usage:**
```powershell
# Run the script
.\Create-HuduAzureApp.ps1
```

**Required Hudu Permissions:**
The app is configured with permissions commonly needed for Hudu integrations:
- User.Read.All - Read user profiles
- Group.Read.All - Read group information
- Device.Read.All - Read device information
- Directory.Read.All - Read directory data
- (Additional permissions as configured in script)

**Post-Creation:**
1. Grant admin consent in Azure Portal
2. Add credentials to Hudu > Admin > Integrations > Microsoft
3. Configure sync settings in Hudu

**Notes:**
- Check script comments for specific permissions configured
- Permissions may need adjustment based on Hudu integration requirements
- Review Hudu documentation for latest integration requirements

---

## Common Tasks

### Create Mail-Sending Application
```powershell
# Create app for automated email sending
.\Create-AzureMailSendApp.ps1

# Save the output credentials securely
```

### Create Hudu Integration
```powershell
# Create app for Hudu sync
.\Create-HuduAzureApp.ps1

# Configure in Hudu portal
```

### Verify App Permissions
```powershell
# Connect to Graph
Connect-MgGraph

# View app permissions
Get-MgApplication -Filter "displayName eq 'GraphMailSendApp'" |
    Select-Object DisplayName, AppId, RequiredResourceAccess
```

---

## Security Best Practices

1. **Least Privilege**: Only grant permissions actually needed for the use case
2. **Secret Management**: Store secrets in Azure Key Vault or equivalent secure storage
3. **Secret Rotation**: Rotate client secrets every 90 days
4. **Audit Logging**: Enable and monitor Azure AD sign-in and audit logs
5. **Conditional Access**: Consider applying conditional access policies to service principals
6. **Regular Reviews**: Quarterly review of app permissions and usage

---

## Troubleshooting

### "Missing required permissions" Error
- Ensure you have Global Admin or Application Administrator role
- Try disconnecting and reconnecting: `Disconnect-MgGraph; Connect-MgGraph -Scopes "Application.ReadWrite.All","AppRoleAssignment.ReadWrite.All","Directory.ReadWrite.All"`

### Admin Consent Required
- After creating the app, navigate to Azure Portal > Azure AD > App Registrations
- Select your app > API Permissions > Grant admin consent for [tenant]

### Secret Expiration
- Client secrets expire after configured lifetime (default: 2 years)
- Set calendar reminders to rotate before expiration
- Consider certificate-based authentication for longer validity

---

## Author

Raymond Slater
https://github.com/razer86/scripts
