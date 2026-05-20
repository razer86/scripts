# ==============================================================================
# Invoke-FolderMigration.ps1
#
# Reusable framework for migrating a shared folder to a new location while
# keeping end-users connected via a transparent junction at the old path.
#
# What this script does (in order):
#   1.  Discovers and backs up any SMB shares on the source path (JSON)
#   2.  Backs up NTFS ACLs from the entire source tree (icacls export)
#   3.  Pre-flight path-length check — flags any destination path >= 260 chars
#   4.  Copies all data via Robocopy (/COPYALL — preserves NTFS ACLs,
#       timestamps, ownership, audit flags)
#   5.  Verifies destination file count and total size match the source
#   6.  Removes old SMB share(s) and recreates them at the new path with
#       identical share-level permissions — drive mappings reconnect unchanged
#   7.  Deletes the source folder
#   8.  Creates an NTFS junction at the original source path pointing to the
#       destination — any hard-coded UNC or local paths continue to resolve
#
# Usage:
#   # Dry run — safe, no changes made (always run this first)
#   .\Invoke-FolderMigration.ps1 -Source "E:\Data\Docs" -Destination "E:\OneDrive\Acme\Docs"
#
#   # Path-length report only, then exit
#   .\Invoke-FolderMigration.ps1 -Source "E:\Data\Docs" -Destination "E:\OneDrive\Acme\Docs" -CheckOnly
#
#   # Live migration
#   .\Invoke-FolderMigration.ps1 -Source "E:\Data\Docs" -Destination "E:\OneDrive\Acme\Docs" -Execute
#
#   # Live migration without creating a junction at the source (e.g. retiring the old path)
#   .\Invoke-FolderMigration.ps1 -Source "E:\Data\Docs" -Destination "E:\OneDrive\Acme\Docs" -Execute -SkipJunction
#
# Requirements:
#   - Run as Administrator (required for share management and NTFS ACL copy)
#   - SmbShare module (built into Windows Server 2012+ and Windows 10+)
# ==============================================================================

param(
    [Parameter(Mandatory, HelpMessage = "Full path to the folder being migrated (source).")]
    [string]$Source,

    [Parameter(Mandatory, HelpMessage = "Full path to the new folder location (destination).")]
    [string]$Destination,

    [string]$LogDir      = "C:\MigrationLogs",   # Override to redirect all log output
    [int]   $MaxPathLen  = 260,                   # Windows MAX_PATH — paths at/above this WILL fail
    [int]   $WarnPathLen = 240,                   # Paths here are close to the limit — flagged as warnings

    [switch]$Execute,      # Perform the actual migration (default is dry-run)
    [switch]$CheckOnly,    # Run the path-length pre-flight only, then exit
    [switch]$SkipJunction  # Do not create a junction at the source path after migration
)

# Robocopy flags:
#   /E        - copy subdirectories including empty ones
#   /COPYALL  - copy Data, Attributes, Timestamps, Security (ACLs), Owner, aUdit info
#   /DCOPY:DAT - copy directory Data, Attributes, Timestamps
#   /R:3      - retry 3 times on failure
#   /W:5      - wait 5 seconds between retries
#   /TEE      - output to both console and log file
#   /NP       - suppress progress percentage (cleaner logs)
$RobocopyFlags = "/E /COPYALL /DCOPY:DAT /R:3 /W:5 /TEE /NP"

# ==============================================================================
# SETUP
# ==============================================================================

# Strip trailing backslashes so path concatenation is consistent
$Source      = $Source.TrimEnd('\')
$Destination = $Destination.TrimEnd('\')

$timestamp       = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile         = "$LogDir\Migration_$timestamp.log"
$PathReport      = "$LogDir\PathLengthReport_$timestamp.csv"
$ShareBackupFile = "$LogDir\ShareBackup_$timestamp.json"
$NtfsBackupFile  = "$LogDir\NtfsAcl_$timestamp.txt"
$RobocopyLog     = "$LogDir\Robocopy_$timestamp.log"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    $colour = switch ($Level) {
        "ERROR" { "Red"    }
        "WARN"  { "Yellow" }
        default { $null    }
    }
    if ($colour) { Write-Host $entry -ForegroundColor $colour } else { Write-Host $entry }
    Add-Content -Path $LogFile -Value $entry
}

# ==============================================================================
# ADMIN CHECK
# ==============================================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[ERROR] This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $Source)) {
    Write-Host "[ERROR] Source path does not exist: $Source" -ForegroundColor Red
    exit 1
}

Write-Log "===== Folder Migration Script ====="
Write-Log "Source      : $Source"
Write-Log "Destination : $Destination"
Write-Log "Mode        : $(if ($Execute) { 'LIVE EXECUTE' } elseif ($CheckOnly) { 'CHECK ONLY' } else { 'DRY RUN' })"
Write-Log "Log dir     : $LogDir"

# ==============================================================================
# STEP 1 — DISCOVER & BACK UP SMB SHARES
# ==============================================================================
Write-Log ""
Write-Log "----- Step 1: SMB Share Discovery & Backup -----"

# Match shares at the source root or any subfolder within it
$matchedShares = Get-SmbShare | Where-Object {
    $_.Path -eq $Source -or $_.Path -like "$Source\*"
}

if ($matchedShares.Count -eq 0) {
    Write-Log "No SMB shares found on '$Source' or any subfolder." "WARN"
    Write-Log "If a share exists under a different account or as a hidden share (\$), verify manually." "WARN"
} else {
    Write-Log "Found $($matchedShares.Count) share(s):"
}

$shareBackups = @()
foreach ($share in $matchedShares) {
    $acl = Get-SmbShareAccess -Name $share.Name
    $shareBackup = [PSCustomObject]@{
        Name                  = $share.Name
        OriginalPath          = $share.Path
        Description           = $share.Description
        ConcurrentUserLimit   = $share.ConcurrentUserLimit
        CachingMode           = $share.CachingMode.ToString()
        FolderEnumerationMode = $share.FolderEnumerationMode.ToString()
        EncryptData           = $share.EncryptData
        ACEs                  = $acl | Select-Object AccountName, AccessControlType, AccessRight
    }
    $shareBackups += $shareBackup

    Write-Log "  Share : $($share.Name)"
    Write-Log "  Path  : $($share.Path)"
    Write-Log "  Desc  : $($share.Description)"
    foreach ($ace in $acl) {
        Write-Log "  ACE   : $($ace.AccountName) — $($ace.AccessControlType) — $($ace.AccessRight)"
    }
    Write-Log ""
}

# Always write the backup (read-only, safe in dry-run too)
$shareBackups | ConvertTo-Json -Depth 5 | Out-File -FilePath $ShareBackupFile -Encoding UTF8
Write-Log "Share config saved : $ShareBackupFile"

# ==============================================================================
# STEP 2 — BACK UP NTFS ACLs
# ==============================================================================
Write-Log ""
Write-Log "----- Step 2: NTFS ACL Backup -----"
Write-Log "Note: robocopy /COPYALL is the primary ACL copy mechanism. This is an audit backup."

# icacls /save exports a binary ACL blob for the tree; /restore can replay it later.
# The saved file paths are relative to $Source — restore with:
#   icacls "$Source" /restore "$NtfsBackupFile" /T
$icaclsErrFile = "$LogDir\NtfsAcl_stderr_$timestamp.txt"
$icaclsProc = Start-Process -FilePath "icacls" `
    -ArgumentList "`"$Source`" /save `"$NtfsBackupFile`" /T" `
    -Wait -PassThru -NoNewWindow `
    -RedirectStandardError $icaclsErrFile

if ($icaclsProc.ExitCode -ne 0) {
    Write-Log "icacls backup exited with code $($icaclsProc.ExitCode). See: $icaclsErrFile" "WARN"
} else {
    Write-Log "NTFS ACLs backed up : $NtfsBackupFile"
    Write-Log "  Restore with  : icacls `"$Source`" /restore `"$NtfsBackupFile`" /T"
}

# ==============================================================================
# STEP 3 — PATH LENGTH PRE-FLIGHT
# ==============================================================================
Write-Log ""
Write-Log "----- Step 3: Path Length Pre-Flight (MaxPathLen=$MaxPathLen, WarnPathLen=$WarnPathLen) -----"

$allFiles      = Get-ChildItem -Path $Source -Recurse -File -ErrorAction SilentlyContinue
$pathIssues    = @()
$warningCount  = 0
$criticalCount = 0

foreach ($file in $allFiles) {
    $relativePath = $file.FullName.Substring($Source.Length)
    $destFullPath = $Destination + $relativePath
    $destLen      = $destFullPath.Length

    if ($destLen -ge $MaxPathLen) {
        $severity = "CRITICAL"
        $criticalCount++
    } elseif ($destLen -ge $WarnPathLen) {
        $severity = "WARNING"
        $warningCount++
    } else {
        continue
    }

    $pathIssues += [PSCustomObject]@{
        Severity        = $severity
        DestPathLength  = $destLen
        SourceLength    = $file.FullName.Length
        SourcePath      = $file.FullName
        DestinationPath = $destFullPath
    }
    Write-Log "  [$severity] len=$destLen  $destFullPath" $(if ($severity -eq "CRITICAL") { "ERROR" } else { "WARN" })
}

if ($pathIssues.Count -gt 0) {
    $pathIssues | Export-Csv -Path $PathReport -NoTypeInformation -Encoding UTF8
    Write-Log ""
    Write-Log "Path check: $criticalCount CRITICAL, $warningCount WARNING." "WARN"
    Write-Log "Full report : $PathReport"

    if ($criticalCount -gt 0) {
        Write-Log "" "ERROR"
        Write-Log "ACTION REQUIRED — $criticalCount file(s) will exceed the path length limit at destination." "ERROR"
        Write-Log "Options:" "ERROR"
        Write-Log "  1. Enable long path support (requires reboot or policy refresh):" "ERROR"
        Write-Log "     Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1" "ERROR"
        Write-Log "  2. Shorten folder/file names in source before migrating" "ERROR"
        Write-Log "  3. Add /256 to RobocopyFlags (uses \\?\ prefix internally)" "ERROR"
        Write-Log "Aborting. Fix path issues then re-run." "ERROR"
        exit 1
    }
} else {
    $longestDest = if ($allFiles.Count -gt 0) {
        ($allFiles | ForEach-Object { ($Destination + $_.FullName.Substring($Source.Length)).Length } |
            Measure-Object -Maximum).Maximum
    } else { 0 }
    Write-Log "All $($allFiles.Count) file(s) pass. Longest destination path: $longestDest chars."
}

if ($CheckOnly) {
    Write-Log ""
    Write-Log "Check-only mode — exiting without making any changes."
    exit 0
}

# ==============================================================================
# STEP 4 — DESTINATION PREPARATION
# ==============================================================================
Write-Log ""
Write-Log "----- Step 4: Destination Preparation -----"

if (-not (Test-Path $Destination)) {
    if ($Execute) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Write-Log "Created destination : $Destination"
    } else {
        Write-Log "[DRY RUN] Would create destination : $Destination"
    }
} else {
    Write-Log "Destination already exists — incoming files will merge with any existing content."
}

# ==============================================================================
# STEP 5 — SOURCE BASELINE
# ==============================================================================
Write-Log ""
Write-Log "----- Step 5: Source Baseline -----"
$sourceStats     = $allFiles | Measure-Object -Property Length -Sum
$sourceFileCount = $sourceStats.Count
$sourceSizeGB    = [math]::Round(($sourceStats.Sum ?? 0) / 1GB, 2)
Write-Log "Source : $sourceFileCount file(s), $sourceSizeGB GB"

# ==============================================================================
# STEP 6 — ROBOCOPY
# ==============================================================================
Write-Log ""
Write-Log "----- Step 6: $(if ($Execute) { 'Copy Data (Robocopy)' } else { 'DRY RUN — Simulate Copy' }) -----"

if ($Execute) {
    $rcArgs = "`"$Source`" `"$Destination`" $RobocopyFlags /LOG+:`"$RobocopyLog`""
} else {
    $rcArgs = "`"$Source`" `"$Destination`" $RobocopyFlags /L /LOG+:`"$RobocopyLog`""
    Write-Log "[DRY RUN] /L flag active — file listing only, no data will be copied."
}

Write-Log "Running : robocopy $rcArgs"
Write-Log ""

$rcProcess = Start-Process -FilePath "robocopy" -ArgumentList $rcArgs -Wait -PassThru -NoNewWindow
$rcExit    = $rcProcess.ExitCode

# Robocopy exit codes: 0 = no change, 1 = files copied OK, 2 = extra files at dest,
# 3 = 1+2, 4 = mismatched files, 5 = 1+4, 6 = 2+4, 7 = 1+2+4, >= 8 = at least one error
if ($rcExit -ge 8) {
    Write-Log "Robocopy reported errors (exit code $rcExit). Source is untouched. Aborting." "ERROR"
    Write-Log "Review robocopy log : $RobocopyLog" "ERROR"
    exit 1
}
Write-Log "Robocopy completed (exit code $rcExit)."
Write-Log "Robocopy log : $RobocopyLog"

# ==============================================================================
# STEP 7 — POST-COPY VERIFICATION
# ==============================================================================
if ($Execute) {
    Write-Log ""
    Write-Log "----- Step 7: Post-Copy Verification -----"

    $destStats     = Get-ChildItem -Path $Destination -Recurse -File -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum
    $destFileCount = $destStats.Count
    $destSizeGB    = [math]::Round(($destStats.Sum ?? 0) / 1GB, 2)

    Write-Log "Source : $sourceFileCount file(s), $sourceSizeGB GB"
    Write-Log "Dest   : $destFileCount file(s), $destSizeGB GB"

    if ($destFileCount -ne $sourceFileCount -or $destSizeGB -ne $sourceSizeGB) {
        Write-Log "VERIFICATION FAILED — file count or size mismatch. Aborting share cutover and source deletion." "ERROR"
        Write-Log "Review the robocopy log and resolve discrepancies, then re-run with -Execute." "ERROR"
        exit 1
    }
    Write-Log "VERIFICATION PASSED."
}

# ==============================================================================
# STEP 8 — SMB SHARE CUTOVER
# ==============================================================================
Write-Log ""
Write-Log "----- Step 8: SMB Share Cutover -----"

if ($shareBackups.Count -eq 0) {
    Write-Log "No shares to migrate — skipping."
} else {
    foreach ($backup in $shareBackups) {
        # Preserve any sub-path offset (e.g. a share rooted inside the source folder)
        $newPath = $backup.OriginalPath -replace [regex]::Escape($Source), $Destination

        if ($Execute) {
            Write-Log "Removing  '$($backup.Name)' from $($backup.OriginalPath) ..."
            Remove-SmbShare -Name $backup.Name -Force

            Write-Log "Recreating '$($backup.Name)' at $newPath ..."
            New-SmbShare `
                -Name                  $backup.Name `
                -Path                  $newPath `
                -Description           $backup.Description `
                -CachingMode           $backup.CachingMode `
                -FolderEnumerationMode $backup.FolderEnumerationMode `
                -EncryptData           $backup.EncryptData `
                -ErrorAction           Stop | Out-Null

            # New-SmbShare adds Everyone/Full Control by default — remove it before re-applying original ACEs
            Revoke-SmbShareAccess -Name $backup.Name -AccountName "Everyone" -Force -ErrorAction SilentlyContinue

            foreach ($ace in $backup.ACEs) {
                if ($ace.AccessControlType -eq "Allow") {
                    Grant-SmbShareAccess -Name $backup.Name -AccountName $ace.AccountName `
                        -AccessRight $ace.AccessRight -Force
                    Write-Log "  Granted : $($ace.AccountName) — $($ace.AccessRight)"
                } elseif ($ace.AccessControlType -eq "Deny") {
                    Block-SmbShareAccess -Name $backup.Name -AccountName $ace.AccountName -Force
                    Write-Log "  Denied  : $($ace.AccountName)"
                }
            }
            Write-Log "  '$($backup.Name)' is now live at $newPath"
        } else {
            Write-Log "[DRY RUN] Would remove   '$($backup.Name)' from $($backup.OriginalPath)"
            Write-Log "[DRY RUN] Would recreate '$($backup.Name)' at $newPath"
            foreach ($ace in $backup.ACEs) {
                Write-Log "[DRY RUN]   ACE : $($ace.AccountName) — $($ace.AccessControlType) — $($ace.AccessRight)"
            }
        }
        Write-Log ""
    }
}

# ==============================================================================
# STEP 9 — DELETE SOURCE
# ==============================================================================
Write-Log "----- Step 9: Source Deletion -----"

if ($Execute) {
    Write-Log "Deleting source : $Source"
    try {
        Remove-Item -Path $Source -Recurse -Force -ErrorAction Stop
        Write-Log "Source deleted."
    } catch {
        Write-Log "Failed to delete source: $_" "ERROR"
        Write-Log "Resolve manually, then run:" "WARN"
        Write-Log "  Remove-Item -Path `"$Source`" -Recurse -Force" "WARN"
        Write-Log "  New-Item -ItemType Junction -Path `"$Source`" -Target `"$Destination`"" "WARN"
        exit 1
    }
} else {
    Write-Log "[DRY RUN] Would delete source : $Source"
}

# ==============================================================================
# STEP 10 — CREATE JUNCTION AT SOURCE PATH
# ==============================================================================
Write-Log ""
Write-Log "----- Step 10: Junction Creation -----"

if ($SkipJunction) {
    Write-Log "SkipJunction flag set — no junction created."
} elseif ($Execute) {
    Write-Log "Creating junction : $Source  ->  $Destination"
    try {
        New-Item -ItemType Junction -Path $Source -Target $Destination -ErrorAction Stop | Out-Null
        Write-Log "Junction created."
        Write-Log "  Verify : (Get-Item '$Source').LinkType  and  (Get-Item '$Source').Target"
    } catch {
        Write-Log "Failed to create junction: $_" "ERROR"
        Write-Log "Create manually:" "WARN"
        Write-Log "  New-Item -ItemType Junction -Path `"$Source`" -Target `"$Destination`"" "WARN"
    }
} else {
    Write-Log "[DRY RUN] Would create junction : $Source  ->  $Destination"
}

# ==============================================================================
# SUMMARY
# ==============================================================================
Write-Log ""
Write-Log "===== Migration Summary ====="
Write-Log "Mode           : $(if ($Execute) { 'LIVE EXECUTE' } else { 'DRY RUN (no changes made)' })"
Write-Log "Source         : $Source"
Write-Log "Destination    : $Destination"
Write-Log "Source files   : $sourceFileCount ($sourceSizeGB GB)"
if ($Execute) {
    Write-Log "Dest files     : $destFileCount ($destSizeGB GB)"
    Write-Log "Verification   : PASSED"
    Write-Log "Junction       : $(if ($SkipJunction) { 'Skipped' } else { "$Source -> $Destination" })"
}
Write-Log "Path warnings  : $warningCount"
Write-Log "Path criticals : $criticalCount"
Write-Log "Robocopy exit  : $rcExit"
Write-Log "Shares moved   : $($shareBackups.Count)"
Write-Log "Log dir        : $LogDir\"
Write-Log ""

if (-not $Execute) {
    Write-Log "*** DRY RUN complete — no data moved, no shares changed, no junction created. ***"
    Write-Log "*** Review the logs above, then re-run with -Execute to perform the migration. ***"
}

Write-Log "===== Done ====="
