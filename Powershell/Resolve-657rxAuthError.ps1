<#
    =========================================
    Resolve-657rxAuthError.ps1
    =========================================
    Author:  Raymond Slater
    Version: 1.0.0
    Purpose: Remediate the M365/Azure AD "Something Went Wrong" error
             tagged 657rx (often paired with code 2148073494) seen in
             Outlook, Teams, and Office activation.

    Common root causes addressed:
      - Stale/corrupted Azure AD broker plugin tokens
      - Corrupted Office identity / licensing cache
      - Stale Outlook profile cache (OST/NST/identity files)
      - Leftover work/school credentials in Credential Manager

    Changelog (Keep a Changelog / SemVer):
      1.0.0 - Initial rebuild after original script was misplaced.

    Usage:
      .\Resolve-657rxAuthError.ps1               # runs remediation
      .\Resolve-657rxAuthError.ps1 -DryRun        # reports only, no changes
    =========================================
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

# =========================================
# ===   Helper Functions   ===
# =========================================

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Remove-PathSafely {
    param(
        [string]$Path,
        [string]$Description
    )

    if (-not (Test-Path $Path)) {
        Write-Host "  [SKIP] $Description not found: $Path" -ForegroundColor DarkGray
        return
    }

    if ($DryRun) {
        Write-Host "  [DRYRUN] Would remove $Description : $Path" -ForegroundColor Yellow
        return
    }

    try {
        Remove-Item -Path $Path -Force -Recurse -ErrorAction Stop
        Write-Host "  [OK] Removed $Description : $Path" -ForegroundColor Green
    }
    catch {
        Write-Host "  [FAIL] Could not remove $Description : $($_.Exception.Message)" -ForegroundColor Red
    }
}

# =========================================
# ===   Pre-flight   ===
# =========================================

Write-Section "Resolve-657rxAuthError"
Write-Host "Target error: M365/Azure AD 'Something went wrong' (tag 657rx, code 2148073494)"
if ($DryRun) {
    Write-Host "Running in DRY RUN mode - no changes will be made." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Close Outlook, Teams, and any Office apps before continuing." -ForegroundColor Yellow
Write-Host "Press Enter to continue, or Ctrl+C to abort..."
Read-Host | Out-Null

# =========================================
# ===   Step 1: Stop relevant processes   ===
# =========================================

Write-Section "Step 1: Stopping Office/Teams processes"

$processNames = @('OUTLOOK', 'Teams', 'ms-teams', 'WINWORD', 'EXCEL')

foreach ($proc in $processNames) {
    $running = Get-Process -Name $proc -ErrorAction SilentlyContinue
    if ($running) {
        if ($DryRun) {
            Write-Host "  [DRYRUN] Would stop process: $proc" -ForegroundColor Yellow
        }
        else {
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] Stopped process: $proc" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  [SKIP] Process not running: $proc" -ForegroundColor DarkGray
    }
}

# =========================================
# ===   Step 2: Clear Azure AD broker tokens   ===
# =========================================

Write-Section "Step 2: Clearing Azure AD broker plugin cache"

Remove-PathSafely -Path "$env:LOCALAPPDATA\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy" `
    -Description "AAD Broker Plugin cache"

# =========================================
# ===   Step 3: Clear Office identity / licensing cache   ===
# =========================================

Write-Section "Step 3: Clearing Office identity and licensing cache"

Remove-PathSafely -Path "$env:LOCALAPPDATA\Microsoft\Office\16.0\Licensing" `
    -Description "Office 16.0 Licensing cache"

Remove-PathSafely -Path "$env:LOCALAPPDATA\Microsoft\Office\16.0\IdentityCache" `
    -Description "Office 16.0 Identity cache"

if ($DryRun) {
    Write-Host "  [DRYRUN] Would remove registry key: HKCU:\Software\Microsoft\Office\16.0\Common\Identity" -ForegroundColor Yellow
}
else {
    try {
        Remove-Item -Path "HKCU:\Software\Microsoft\Office\16.0\Common\Identity" -Force -Recurse -ErrorAction Stop
        Write-Host "  [OK] Removed registry key: Common\Identity" -ForegroundColor Green
    }
    catch {
        Write-Host "  [SKIP] Registry key not found or already clear" -ForegroundColor DarkGray
    }
}

# =========================================
# ===   Step 4: Clear Outlook profile cache   ===
# =========================================

Write-Section "Step 4: Clearing stale Outlook profile cache files"

if (Test-Path "$env:LOCALAPPDATA\Microsoft\Outlook") {
    $outlookFiles = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\Outlook" -Include "*.ost", "*.nst", "outcmd.dat", "*.xml", "*.srs" -Recurse -ErrorAction SilentlyContinue

    if ($outlookFiles) {
        foreach ($file in $outlookFiles) {
            Remove-PathSafely -Path $file.FullName -Description "Outlook cache file"
        }
    }
    else {
        Write-Host "  [SKIP] No matching Outlook cache files found" -ForegroundColor DarkGray
    }
}
else {
    Write-Host "  [SKIP] Outlook local data folder not found" -ForegroundColor DarkGray
}

# =========================================
# ===   Step 5: Clear related Credential Manager entries   ===
# =========================================

Write-Section "Step 5: Clearing related Credential Manager entries"

try {
    $creds = cmdkey /list | Select-String -Pattern "MicrosoftOffice|AzureAD|MicrosoftAccount"
    if ($creds) {
        foreach ($line in $creds) {
            if ($line -match 'Target:\s*(.+)') {
                $target = $Matches[1].Trim()
                if ($DryRun) {
                    Write-Host "  [DRYRUN] Would remove credential: $target" -ForegroundColor Yellow
                }
                else {
                    cmdkey /delete:$target | Out-Null
                    Write-Host "  [OK] Removed credential: $target" -ForegroundColor Green
                }
            }
        }
    }
    else {
        Write-Host "  [SKIP] No matching stored credentials found" -ForegroundColor DarkGray
    }
}
catch {
    Write-Host "  [FAIL] Could not enumerate Credential Manager entries: $($_.Exception.Message)" -ForegroundColor Red
}

# =========================================
# ===   Step 6: Manual follow-up checklist   ===
# =========================================

Write-Section "Step 6: Manual follow-up (if error persists)"

Write-Host "  1. Settings > Accounts > Access work or school > Remove and re-add the work account"
Write-Host "  2. Settings > Accounts > Access work or school > Info > check device is registered/joined correctly"
Write-Host "  3. If device trust is broken (post hardware change), disjoin/rejoin Azure AD (dsregcmd /leave then re-enroll)"
Write-Host "  4. Confirm credentials aren't expired/locked, especially if federated via ADFS"
Write-Host "  5. Restart the machine before retesting sign-in"

Write-Section "Done"
if ($DryRun) {
    Write-Host "Dry run complete - no changes were made. Re-run without -DryRun to apply." -ForegroundColor Yellow
}
else {
    Write-Host "Remediation steps applied. Restart the machine and retest sign-in." -ForegroundColor Green
}
