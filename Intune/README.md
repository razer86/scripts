# Microsoft Intune Remediation Scripts

Proactive remediation scripts for Microsoft Intune that detect and automatically resolve common issues on managed devices.

---

## What Are Proactive Remediations?

Proactive Remediations in Microsoft Intune allow you to deploy detection and remediation script pairs that:
- **Detect** issues on endpoints before users report them
- **Automatically remediate** problems without manual intervention
- **Report compliance** status back to Intune admin center

Each remediation consists of two scripts:
1. **Detection script** - Checks for the issue, exits 0 if compliant, exits 1 if issue detected
2. **Remediation script** - Fixes the issue, runs only when detection script exits 1

---

## Deployment

### Via Intune Admin Center

1. Navigate to **Devices** > **Scripts and remediations** > **Proactive remediations**
2. Click **Create script package**
3. Configure each script package:
   - **Detection script**: Upload the `Detect-*.ps1` file
   - **Remediation script**: Upload the corresponding `Set-*.ps1` or `Remove-*.ps1` file
   - **Run in 64-bit**: Yes (recommended)
   - **Run as system**: Yes (required for most remediations)
   - **Enforcement**: Run once, or on schedule

### Assignment

- Assign to device groups or user groups
- Set run frequency (daily, weekly, etc.)
- Monitor results in Intune admin center

---

## Available Remediations

### HP Bloatware Removal

Detects and removes HP-preinstalled bloatware and promotional software from HP devices.

**Detection**: `Detect-HPBloat.ps1`
**Remediation**: `Remove-HPBloat.ps1`

#### What It Detects

Scans for HP bloatware packages and programs including:
- HP JumpStarts
- HP Support Assistant
- HP Privacy Settings
- HP Power Manager
- HP Sure Click/Sense/Shield/Run/Recover
- HP Connection Optimizer
- HP Documentation
- HP Wolf Security
- HP System Information
- HP QuickDrop, WorkWell, QuickTouch, EasyClean
- And other HP promotional software

#### What It Removes

- **AppX Packages**: Removes HP apps from Windows Store
- **Provisioned Packages**: Prevents reinstallation for new users
- **Traditional Programs**: Uninstalls HP software via Package Manager
- **HP Wolf Security**: Removes via WMI Win32_Product

#### Exit Codes

**Detection Script:**
- `0` - No HP bloatware detected (compliant)
- `1` - HP bloatware detected, remediation needed

**Remediation Script:**
- `0` - Successfully removed all detected bloatware
- `1` - Removal failed or incomplete

#### Notes

- Based on [mark05e's HP bloatware removal script](https://gist.github.com/mark05e/a79221b4245962a477a49eb281d97388)
- Runs as SYSTEM for full removal permissions
- May require reboot after removal
- Detection runs on all devices, but only triggers remediation on HP devices with bloatware

#### Deployment Recommendations

- **Scope**: Assign to all devices or HP device group
- **Schedule**: Run once on deployment, then monthly
- **Settings**: Run as system, 64-bit PowerShell

---

### OneDrive Timer AutoMount Configuration

Configures the OneDrive Timer AutoMount registry setting to optimize sync performance.

**Detection**: `Detect-TimerAutoMount.ps1`
**Remediation**: `Set-TimerAutoMount.ps1`

#### What It Does

Sets the OneDrive `TimerAutoMount` registry value to `1`, which optimizes how OneDrive handles file mounting and sync operations.

**Registry Path:**
```
HKCU:\SOFTWARE\Microsoft\OneDrive\Accounts\Business1
```

**Registry Value:**
- **Name**: `Timerautomount`
- **Type**: `QWORD` (64-bit)
- **Value**: `1`

#### Purpose

The Timer AutoMount setting affects how OneDrive handles:
- Files On-Demand mounting behavior
- Sync timing optimization
- Reduced sync conflicts

**Note**: This setting is specific to OneDrive for Business (Business1 account).

#### Exit Codes

**Detection Script:**
- `0` - Timer AutoMount correctly set to 1 (compliant)
- `1` - Timer AutoMount not configured or set to incorrect value

**Remediation Script:**
- `0` - Successfully configured Timer AutoMount
- `1` - Failed to set registry value

#### Notes

- Runs in user context (HKCU registry hive)
- Only affects OneDrive for Business (not personal OneDrive)
- Changes take effect on next OneDrive restart
- No reboot required

#### Deployment Recommendations

- **Scope**: Assign to all users with OneDrive for Business
- **Schedule**: Run once, then weekly to catch new users
- **Settings**: Run as user (not system), 64-bit PowerShell

---

## Script Development Guidelines

When creating new remediations, follow these best practices:

### Detection Scripts

```powershell
# Detection template
try {
    # Check for issue
    $condition = Test-Something

    if ($condition -eq $desiredState) {
        Write-Output "Compliant"
        exit 0  # No remediation needed
    } else {
        Write-Warning "Non-compliant"
        exit 1  # Trigger remediation
    }
} catch {
    Write-Error "Detection failed: $_"
    exit 1  # Treat errors as non-compliant
}
```

### Remediation Scripts

```powershell
# Remediation template
try {
    # Fix the issue
    Set-Something -Value $desiredState

    # Verify fix
    $verification = Test-Something
    if ($verification -eq $desiredState) {
        Write-Output "Remediation successful"
        exit 0  # Success
    } else {
        Write-Warning "Remediation incomplete"
        exit 1  # Failed
    }
} catch {
    Write-Error "Remediation failed: $_"
    exit 1  # Failure
}
```

### Best Practices

1. **Exit Codes**: Always use exit 0 (success) or exit 1 (failure)
2. **Error Handling**: Wrap in try/catch to handle unexpected errors
3. **Verification**: Remediation scripts should verify success before exiting
4. **Logging**: Use Write-Output for success, Write-Warning for issues
5. **Idempotent**: Remediations should be safe to run multiple times
6. **Minimal Impact**: Avoid reboots unless absolutely necessary
7. **Testing**: Test on pilot devices before wide deployment

---

## Monitoring and Reporting

### View Remediation Status

1. Navigate to **Devices** > **Scripts and remediations** > **Proactive remediations**
2. Click on a remediation package
3. View **Device status** tab for compliance summary

### Status Meanings

- **With issue** - Detection script found issue (exit 1)
- **Without issue** - Detection script found no issue (exit 0)
- **Issue remediated** - Remediation script ran successfully (exit 0)
- **Failed** - Detection or remediation script failed

### Troubleshooting Failed Remediations

1. Check device-level reporting for error messages
2. Review script syntax and logic
3. Verify script runs with correct permissions (user vs system)
4. Test scripts locally on affected device:
   ```powershell
   # Run as current user
   .\Detect-TimerAutoMount.ps1

   # Run as SYSTEM (use PsExec)
   psexec -s -i powershell.exe -ExecutionPolicy Bypass -File ".\Detect-HPBloat.ps1"
   ```

---

## Contributing New Remediations

When adding new remediation scripts:

1. Use clear, descriptive naming: `Detect-Issue.ps1` and `Set-Issue.ps1`
2. Include comment-based help at the top of each script
3. Document in this README with:
   - What it detects/fixes
   - Registry paths or system changes
   - Exit codes
   - Deployment recommendations
4. Test thoroughly on pilot devices before production deployment

---

## Author

Raymond Slater
https://github.com/razer86/scripts
