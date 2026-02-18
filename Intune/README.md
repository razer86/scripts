# Microsoft Intune Management

Scripts and tools for managing devices, applications, and configurations via Microsoft Intune.

---

## Overview

This directory contains PowerShell scripts and utilities for Microsoft Intune device management, including:

- **Proactive Remediations** - Automated detection and remediation of common issues
- **Configuration Scripts** - Device and application configuration automation
- **Compliance Scripts** - Custom compliance checks and reporting
- **Application Deployment** - App installation and configuration helpers

---

## Subdirectories

### Remediations

Proactive remediation script pairs for automated issue detection and resolution.

See [`Remediations/README.md`](Remediations/README.md) for complete documentation.

**Available Remediations:**
- HP Bloatware Detection & Removal
- OneDrive Timer AutoMount Configuration

---

## Requirements

- **Microsoft Intune** subscription (included with Microsoft 365 E3/E5, Enterprise Mobility + Security)
- **Azure AD** for device enrollment
- **Appropriate licenses** assigned to users/devices
- **Admin permissions** in Microsoft Intune admin center

---

## Getting Started

### Accessing Intune Admin Center

Navigate to: https://intune.microsoft.com

Required roles:
- Global Administrator
- Intune Service Administrator
- Endpoint Security Manager (for specific tasks)

### Deploying Scripts

Most scripts in this directory are deployed via:

1. **Proactive Remediations** - For detection/remediation pairs
   - Navigate to: **Devices** > **Scripts and remediations** > **Proactive remediations**

2. **PowerShell Scripts** - For general automation
   - Navigate to: **Devices** > **Scripts and remediations** > **Platform scripts**

3. **Compliance Policies** - For custom compliance checks
   - Navigate to: **Devices** > **Compliance policies**

---

## Best Practices

### Script Deployment
- **Test First**: Always test on pilot devices before production deployment
- **Use Groups**: Leverage Azure AD groups for targeted deployment
- **Monitor Results**: Regularly review script execution reports
- **Version Control**: Keep track of script versions and changes

### Security
- **Run as System**: Use when scripts need elevated permissions
- **Least Privilege**: Only grant necessary permissions
- **Sign Scripts**: Consider code signing for production environments
- **Audit Logging**: Enable and review audit logs regularly

### Performance
- **Scheduling**: Avoid running heavy scripts during business hours
- **Timeout Settings**: Set appropriate timeouts for long-running scripts
- **Error Handling**: Include proper error handling and logging
- **Resource Impact**: Monitor CPU/memory usage on endpoints

---

## Common Tasks

### Deploy a Remediation Script

```powershell
# 1. Prepare your detection and remediation scripts
# 2. Test locally on a sample device
# 3. Upload to Intune admin center
# 4. Assign to a pilot group
# 5. Monitor results
# 6. Expand to production groups
```

### View Script Execution Results

1. Navigate to **Devices** > **Scripts and remediations**
2. Select your script package
3. View **Device status** and **User status** tabs
4. Review error messages for failed executions

### Troubleshoot Failed Scripts

1. Check device-level error messages in Intune portal
2. Review script exit codes and output
3. Test script locally on affected device
4. Verify correct execution context (user vs system)
5. Check device compliance and connectivity

---

## Contributing

When adding new scripts to this directory:

1. Follow PowerShell best practices and style guidelines
2. Include comment-based help with .SYNOPSIS, .DESCRIPTION, .EXAMPLE
3. Use proper exit codes (0 = success, 1 = failure)
4. Test thoroughly on multiple device types
5. Document in the appropriate README
6. Consider security and performance implications

---

## Resources

### Microsoft Documentation
- [Intune Documentation](https://learn.microsoft.com/en-us/mem/intune/)
- [Proactive Remediations](https://learn.microsoft.com/en-us/mem/intune/fundamentals/remediations)
- [PowerShell Scripts in Intune](https://learn.microsoft.com/en-us/mem/intune/apps/intune-management-extension)
- [Compliance Policies](https://learn.microsoft.com/en-us/mem/intune/protect/device-compliance-get-started)

### Community Resources
- [Intune Community on GitHub](https://github.com/microsoft/Intune-PowerShell-SDK)
- [r/Intune on Reddit](https://reddit.com/r/Intune)
- [Microsoft Tech Community - Intune](https://techcommunity.microsoft.com/t5/microsoft-intune/ct-p/MicrosoftIntune)

---

## Author

Raymond Slater
https://github.com/razer86/scripts
