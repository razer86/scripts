#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules SmbShare

<#
.SYNOPSIS
    Migrates a shared folder to a new location while keeping end-users connected.

.DESCRIPTION
    Performs an end-to-end shared-folder migration in the following order:

      1. Discovers and backs up SMB shares on the source path (JSON)
      2. Backs up NTFS ACLs for the source tree (icacls /save export)
      3. Checks that all destination paths stay within the Windows path-length limit
      4. Copies data via Robocopy (/COPYALL — NTFS ACLs, timestamps, owner, audit flags)
      5. Verifies destination file count and total size match the source
      6. Recreates SMB shares at the new path with identical share-level permissions
         so drive mappings reconnect unchanged
      7. Deletes the source folder
      8. Creates an NTFS junction at the original source path pointing to the
         destination so hard-coded paths and shortcuts continue to resolve

    Without -Execute the script performs a dry run: it logs every planned action
    without touching data, shares, or the filesystem.

.PARAMETER Source
    Full path to the folder being migrated.

.PARAMETER Destination
    Full path to the new location.

.PARAMETER LogDir
    Directory where all log and backup files are written. Created if absent.
    Default: C:\MigrationLogs

.PARAMETER MaxPathLen
    Abort threshold: destination paths at or above this character count will
    cause the script to exit before copying anything.
    Default: 260 (Windows MAX_PATH limit).

.PARAMETER WarnPathLen
    Warning threshold: destination paths at or above this character count are
    flagged in the report but do not abort the run.
    Default: 240.

.PARAMETER Execute
    Perform the actual migration. Omit this switch for a safe dry run.

.PARAMETER CheckOnly
    Run only the path-length pre-flight check, then exit. No data is moved.

.PARAMETER SkipJunction
    Skip creation of the NTFS junction at the source path after migration.
    Use when the old path is being retired rather than kept transparent.

.EXAMPLE
    .\Move-SharedFolder.ps1 -Source 'E:\CompanyData\Docs' -Destination 'E:\OneDrive\Acme\Docs'

    Dry run — logs all planned actions without making any changes. Always run this first.

.EXAMPLE
    .\Move-SharedFolder.ps1 -Source 'E:\CompanyData\Docs' -Destination 'E:\OneDrive\Acme\Docs' -CheckOnly

    Generates a path-length report only, then exits.

.EXAMPLE
    .\Move-SharedFolder.ps1 -Source 'E:\CompanyData\Docs' -Destination 'E:\OneDrive\Acme\Docs' -Execute

    Performs the live migration with a junction left at the source path.

.EXAMPLE
    .\Move-SharedFolder.ps1 -Source 'E:\CompanyData\Docs' -Destination 'E:\OneDrive\Acme\Docs' -Execute -SkipJunction

    Performs the live migration without creating a junction (retiring the old path).

.NOTES
    - Administrator rights are enforced via #Requires -RunAsAdministrator.
    - The SmbShare module ships with Windows Server 2012+ and Windows 10+.
    - Robocopy /COPYALL is the primary ACL transfer mechanism. The icacls export
      (Step 2) is an audit backup only.
    - To restore NTFS ACLs from the backup file:
        icacls "<OriginalSource>" /restore "<NtfsBackupFile>" /T
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory, HelpMessage = 'Full path to the folder being migrated.')]
    [ValidateNotNullOrEmpty()]
    [string]$Source,

    [Parameter(Mandatory, HelpMessage = 'Full path to the new location.')]
    [ValidateNotNullOrEmpty()]
    [string]$Destination,

    [ValidateNotNullOrEmpty()]
    [string]$LogDir = 'C:\MigrationLogs',

    # Paths at or above this length will fail to copy on a default Windows install.
    [ValidateRange(1, 32767)]
    [int]$MaxPathLen = 260,

    # Paths at or above this length are flagged as warnings for awareness.
    [ValidateRange(1, 32767)]
    [int]$WarnPathLen = 240,

    [switch]$Execute,      # Perform the migration (default is dry-run)
    [switch]$CheckOnly,    # Path-length pre-flight only, then exit
    [switch]$SkipJunction  # Skip junction creation at source after migration
)

# Robocopy flags:
#   /E        - include subdirectories, even empty ones
#   /COPYALL  - copy Data, Attributes, Timestamps, Security (NTFS ACLs), Owner, aUdit info
#   /DCOPY:DAT - copy directory Data, Attributes, Timestamps
#   /R:3      - retry 3 times on failure
#   /W:5      - wait 5 seconds between retries
#   /TEE      - output to both console and log file simultaneously
#   /NP       - suppress progress percentage (cleaner logs)
$RobocopyFlags = '/E /COPYALL /DCOPY:DAT /R:3 /W:5 /TEE /NP'

# ==============================================================================
# SETUP
# ==============================================================================

# Normalise paths: strip trailing backslashes for consistent string concatenation.
$Source      = $Source.TrimEnd('\')
$Destination = $Destination.TrimEnd('\')

$timestamp       = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile         = "$LogDir\Migration_$timestamp.log"
$PathReport      = "$LogDir\PathLengthReport_$timestamp.csv"
$ShareBackupFile = "$LogDir\ShareBackup_$timestamp.json"
$NtfsBackupFile  = "$LogDir\NtfsAcl_$timestamp.txt"
$NtfsErrFile     = "$LogDir\NtfsAcl_stderr_$timestamp.txt"
$RobocopyLog     = "$LogDir\Robocopy_$timestamp.log"

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -ErrorAction Stop | Out-Null
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $entry
    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red    }
        'WARN'  { Write-Host $entry -ForegroundColor Yellow }
        default { Write-Host $entry }
    }
}

if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    Write-Host "[ERROR] Source path does not exist or is not a directory: $Source" -ForegroundColor Red
    exit 1
}

Write-Log '===== Shared Folder Migration ====='
Write-Log "Source      : $Source"
Write-Log "Destination : $Destination"
Write-Log "Mode        : $(if ($Execute) { 'LIVE EXECUTE' } elseif ($CheckOnly) { 'CHECK ONLY' } else { 'DRY RUN' })"
Write-Log "Log dir     : $LogDir"

# ==============================================================================
# STEP 1 — DISCOVER & BACK UP SMB SHARES
# ==============================================================================
Write-Log ''
Write-Log '----- Step 1: SMB Share Discovery & Backup -----'

# Wrap in @() so $matchedShares is always an array even when one share matches.
$matchedShares = @(Get-SmbShare | Where-Object {
    $_.Path -eq $Source -or $_.Path -like "$Source\*"
})

if ($matchedShares.Count -eq 0) {
    Write-Log "No SMB shares found on '$Source' or any subfolder." 'WARN'
    Write-Log 'If a share exists under a different account or as a hidden share ($), verify manually.' 'WARN'
} else {
    Write-Log "Found $($matchedShares.Count) share(s):"
}

$shareBackups = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($share in $matchedShares) {
    $acl = Get-SmbShareAccess -Name $share.Name
    $shareBackups.Add([PSCustomObject]@{
        Name                  = $share.Name
        OriginalPath          = $share.Path
        Description           = $share.Description
        ConcurrentUserLimit   = $share.ConcurrentUserLimit
        CachingMode           = $share.CachingMode.ToString()
        FolderEnumerationMode = $share.FolderEnumerationMode.ToString()
        EncryptData           = $share.EncryptData
        ACEs                  = @($acl | Select-Object AccountName, AccessControlType, AccessRight)
    })
    Write-Log "  Share : $($share.Name)"
    Write-Log "  Path  : $($share.Path)"
    Write-Log "  Desc  : $($share.Description)"
    foreach ($ace in $acl) {
        Write-Log "  ACE   : $($ace.AccountName) - $($ace.AccessControlType) - $($ace.AccessRight)"
    }
    Write-Log ''
}

# Write the JSON backup even during dry-run — it is read-only and always useful.
$shareBackups | ConvertTo-Json -Depth 5 | Out-File -FilePath $ShareBackupFile -Encoding UTF8
Write-Log "Share config saved : $ShareBackupFile"

# ==============================================================================
# STEP 2 — BACK UP NTFS ACLs
# ==============================================================================
Write-Log ''
Write-Log '----- Step 2: NTFS ACL Backup -----'
Write-Log 'Note: Robocopy /COPYALL is the primary ACL copy mechanism. This export is an audit backup.'

# icacls /save creates a binary ACL dump for the tree that can be replayed with /restore.
# Paths in the saved file are relative to $Source.
$icaclsProc = Start-Process -FilePath 'icacls' `
    -ArgumentList "`"$Source`" /save `"$NtfsBackupFile`" /T" `
    -Wait -PassThru -NoNewWindow `
    -RedirectStandardError $NtfsErrFile

if ($icaclsProc.ExitCode -ne 0) {
    Write-Log "icacls exited with code $($icaclsProc.ExitCode). See: $NtfsErrFile" 'WARN'
} else {
    Write-Log "NTFS ACLs backed up : $NtfsBackupFile"
    Write-Log "  Restore with      : icacls `"$Source`" /restore `"$NtfsBackupFile`" /T"
}

# ==============================================================================
# STEP 3 — PATH LENGTH PRE-FLIGHT
# ==============================================================================
Write-Log ''
Write-Log "----- Step 3: Path Length Pre-Flight (max=$MaxPathLen, warn=$WarnPathLen) -----"

$allFiles      = @(Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue)
$pathIssues    = [System.Collections.Generic.List[PSCustomObject]]::new()
$warningCount  = 0
$criticalCount = 0

foreach ($file in $allFiles) {
    $relativePath = $file.FullName.Substring($Source.Length)
    $destFullPath = $Destination + $relativePath
    $destLen      = $destFullPath.Length

    if ($destLen -ge $MaxPathLen) {
        $severity = 'CRITICAL'
        $criticalCount++
    } elseif ($destLen -ge $WarnPathLen) {
        $severity = 'WARNING'
        $warningCount++
    } else {
        continue
    }

    $pathIssues.Add([PSCustomObject]@{
        Severity        = $severity
        DestPathLength  = $destLen
        SourceLength    = $file.FullName.Length
        SourcePath      = $file.FullName
        DestinationPath = $destFullPath
    })
    Write-Log "  [$severity] len=$destLen  $destFullPath" $(if ($severity -eq 'CRITICAL') { 'ERROR' } else { 'WARN' })
}

if ($pathIssues.Count -gt 0) {
    $pathIssues | Export-Csv -Path $PathReport -NoTypeInformation -Encoding UTF8
    Write-Log ''
    Write-Log "Path check: $criticalCount CRITICAL, $warningCount WARNING." 'WARN'
    Write-Log "Full report : $PathReport"

    if ($criticalCount -gt 0) {
        Write-Log "ACTION REQUIRED: $criticalCount file(s) will exceed the path length limit at destination." 'ERROR'
        Write-Log 'Options:' 'ERROR'
        Write-Log "  1. Enable long path support (requires a reboot or Group Policy refresh):" 'ERROR'
        Write-Log "     Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1" 'ERROR'
        Write-Log '  2. Shorten folder or file names in the source before migrating.' 'ERROR'
        Write-Log '  3. Add /256 to $RobocopyFlags to use the \\?\ extended path prefix.' 'ERROR'
        Write-Log 'Aborting. Fix path issues then re-run.' 'ERROR'
        exit 1
    }
} else {
    $longestDest = if ($allFiles.Count -gt 0) {
        ($allFiles |
            ForEach-Object { ($Destination + $_.FullName.Substring($Source.Length)).Length } |
            Measure-Object -Maximum).Maximum
    } else { 0 }
    Write-Log "All $($allFiles.Count) file(s) pass. Longest destination path: $longestDest chars."
}

if ($CheckOnly) {
    Write-Log ''
    Write-Log 'Check-only mode — exiting without making any changes.'
    exit 0
}

# ==============================================================================
# STEP 4 — DESTINATION PREPARATION
# ==============================================================================
Write-Log ''
Write-Log '----- Step 4: Destination Preparation -----'

if (-not (Test-Path -LiteralPath $Destination)) {
    if ($Execute) {
        New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
        Write-Log "Created destination : $Destination"
    } else {
        Write-Log "[DRY RUN] Would create destination : $Destination"
    }
} else {
    Write-Log 'Destination already exists — incoming files will merge with any existing content.'
}

# ==============================================================================
# STEP 5 — SOURCE BASELINE
# ==============================================================================
Write-Log ''
Write-Log '----- Step 5: Source Baseline -----'

$sourceStats     = $allFiles | Measure-Object -Property Length -Sum
$sourceFileCount = $sourceStats.Count
$sourceSumBytes  = if ($null -ne $sourceStats.Sum) { $sourceStats.Sum } else { 0 }
$sourceSizeGB    = [math]::Round($sourceSumBytes / 1GB, 2)

Write-Log "Source : $sourceFileCount file(s), $sourceSizeGB GB"

# ==============================================================================
# STEP 6 — ROBOCOPY
# ==============================================================================
Write-Log ''
Write-Log "----- Step 6: $(if ($Execute) { 'Copy Data (Robocopy)' } else { 'DRY RUN - Simulate Copy' }) -----"

if ($Execute) {
    $rcArgs = "`"$Source`" `"$Destination`" $RobocopyFlags /LOG+:`"$RobocopyLog`""
} else {
    $rcArgs = "`"$Source`" `"$Destination`" $RobocopyFlags /L /LOG+:`"$RobocopyLog`""
    Write-Log '[DRY RUN] /L flag active — file listing only, no data will be copied.'
}

Write-Log "Running : robocopy $rcArgs"
Write-Log ''

$rcProcess = Start-Process -FilePath 'robocopy' -ArgumentList $rcArgs -Wait -PassThru -NoNewWindow
$rcExit    = $rcProcess.ExitCode

# Robocopy exit codes: 0=no change 1=copied OK 2=extra files 3=1+2 4=mismatches
# 5=1+4 6=2+4 7=1+2+4 >=8=at least one error
if ($rcExit -ge 8) {
    Write-Log "Robocopy reported errors (exit code $rcExit). Source is untouched. Aborting." 'ERROR'
    Write-Log "Review : $RobocopyLog" 'ERROR'
    exit 1
}
Write-Log "Robocopy completed (exit code $rcExit). Log : $RobocopyLog"

# ==============================================================================
# STEP 7 — POST-COPY VERIFICATION
# ==============================================================================
$destFileCount = 0
$destSizeGB    = 0

if ($Execute) {
    Write-Log ''
    Write-Log '----- Step 7: Post-Copy Verification -----'

    $destStats    = Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue |
                        Measure-Object -Property Length -Sum
    $destFileCount = $destStats.Count
    $destSumBytes  = if ($null -ne $destStats.Sum) { $destStats.Sum } else { 0 }
    $destSizeGB    = [math]::Round($destSumBytes / 1GB, 2)

    Write-Log "Source : $sourceFileCount file(s), $sourceSizeGB GB"
    Write-Log "Dest   : $destFileCount file(s), $destSizeGB GB"

    if ($destFileCount -ne $sourceFileCount -or $destSizeGB -ne $sourceSizeGB) {
        Write-Log 'VERIFICATION FAILED — count or size mismatch. Aborting share cutover and source deletion.' 'ERROR'
        Write-Log "Review $RobocopyLog and resolve discrepancies, then re-run with -Execute." 'ERROR'
        exit 1
    }
    Write-Log 'VERIFICATION PASSED.'
}

# ==============================================================================
# STEP 8 — SMB SHARE CUTOVER
# ==============================================================================
Write-Log ''
Write-Log '----- Step 8: SMB Share Cutover -----'

if ($shareBackups.Count -eq 0) {
    Write-Log 'No shares to migrate — skipping.'
} else {
    foreach ($backup in $shareBackups) {
        # Recalculate path: replace source root with destination root, preserving
        # any sub-folder offset for shares rooted inside the source tree.
        $newPath = $backup.OriginalPath -replace [regex]::Escape($Source), $Destination

        if ($Execute) {
            Write-Log "Removing   '$($backup.Name)' from $($backup.OriginalPath) ..."
            Remove-SmbShare -Name $backup.Name -Force -ErrorAction Stop

            Write-Log "Recreating '$($backup.Name)' at $newPath ..."
            New-SmbShare `
                -Name                  $backup.Name `
                -Path                  $newPath `
                -Description           $backup.Description `
                -CachingMode           $backup.CachingMode `
                -FolderEnumerationMode $backup.FolderEnumerationMode `
                -EncryptData           $backup.EncryptData `
                -ErrorAction           Stop | Out-Null

            # New-SmbShare grants Everyone/Full Control by default — revoke it
            # before re-applying the original ACEs from the backup.
            Revoke-SmbShareAccess -Name $backup.Name -AccountName 'Everyone' -Force -ErrorAction SilentlyContinue

            foreach ($ace in $backup.ACEs) {
                if ($ace.AccessControlType -eq 'Allow') {
                    Grant-SmbShareAccess -Name $backup.Name -AccountName $ace.AccountName `
                        -AccessRight $ace.AccessRight -Force -ErrorAction Stop
                    Write-Log "  Granted : $($ace.AccountName) - $($ace.AccessRight)"
                } elseif ($ace.AccessControlType -eq 'Deny') {
                    Block-SmbShareAccess -Name $backup.Name -AccountName $ace.AccountName `
                        -Force -ErrorAction Stop
                    Write-Log "  Denied  : $($ace.AccountName)"
                }
            }
            Write-Log "  '$($backup.Name)' is now live at $newPath"
        } else {
            Write-Log "[DRY RUN] Would remove   '$($backup.Name)' from $($backup.OriginalPath)"
            Write-Log "[DRY RUN] Would recreate '$($backup.Name)' at $newPath"
            foreach ($ace in $backup.ACEs) {
                Write-Log "[DRY RUN]   ACE : $($ace.AccountName) - $($ace.AccessControlType) - $($ace.AccessRight)"
            }
        }
        Write-Log ''
    }
}

# ==============================================================================
# STEP 9 — DELETE SOURCE
# ==============================================================================
Write-Log '----- Step 9: Source Deletion -----'

if ($Execute) {
    Write-Log "Deleting source : $Source"
    try {
        Remove-Item -LiteralPath $Source -Recurse -Force -ErrorAction Stop
        Write-Log 'Source deleted.'
    } catch {
        Write-Log "Failed to delete source: $_" 'ERROR'
        Write-Log 'Resolve manually, then create the junction by hand:' 'WARN'
        Write-Log "  Remove-Item -LiteralPath `"$Source`" -Recurse -Force" 'WARN'
        Write-Log "  New-Item -ItemType Junction -Path `"$Source`" -Target `"$Destination`"" 'WARN'
        exit 1
    }
} else {
    Write-Log "[DRY RUN] Would delete source : $Source"
}

# ==============================================================================
# STEP 10 — CREATE JUNCTION AT SOURCE PATH
# ==============================================================================
Write-Log ''
Write-Log '----- Step 10: Junction Creation -----'

if ($SkipJunction) {
    Write-Log 'SkipJunction flag set — no junction created.'
} elseif ($Execute) {
    Write-Log "Creating junction : $Source  ->  $Destination"
    try {
        New-Item -ItemType Junction -Path $Source -Target $Destination -ErrorAction Stop | Out-Null
        Write-Log 'Junction created.'
        Write-Log "  Verify : (Get-Item -LiteralPath '$Source').LinkType"
        Write-Log "           (Get-Item -LiteralPath '$Source').Target"
    } catch {
        Write-Log "Failed to create junction: $_" 'ERROR'
        Write-Log 'Create manually:' 'WARN'
        Write-Log "  New-Item -ItemType Junction -Path `"$Source`" -Target `"$Destination`"" 'WARN'
    }
} else {
    Write-Log "[DRY RUN] Would create junction : $Source  ->  $Destination"
}

# ==============================================================================
# SUMMARY
# ==============================================================================
Write-Log ''
Write-Log '===== Migration Summary ====='
Write-Log "Mode           : $(if ($Execute) { 'LIVE EXECUTE' } else { 'DRY RUN (no changes made)' })"
Write-Log "Source         : $Source"
Write-Log "Destination    : $Destination"
Write-Log "Source files   : $sourceFileCount ($sourceSizeGB GB)"
if ($Execute) {
    Write-Log "Dest files     : $destFileCount ($destSizeGB GB)"
    Write-Log 'Verification   : PASSED'
    Write-Log "Junction       : $(if ($SkipJunction) { 'Skipped' } else { "$Source -> $Destination" })"
}
Write-Log "Path warnings  : $warningCount"
Write-Log "Path criticals : $criticalCount"
Write-Log "Robocopy exit  : $rcExit"
Write-Log "Shares moved   : $($shareBackups.Count)"
Write-Log "Log dir        : $LogDir\"
Write-Log ''

if (-not $Execute) {
    Write-Log '*** DRY RUN complete — no data moved, no shares changed, no junction created. ***'
    Write-Log '*** Review the logs above, then re-run with -Execute to perform the migration. ***'
}

Write-Log '===== Done ====='
