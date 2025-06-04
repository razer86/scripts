<#
.SYNOPSIS
Performs a one-time sync from a source folder to a destination folder and continuously monitors for changes to keep them in sync.

.DESCRIPTION
This script uses Robocopy to perform an initial mirror of all contents from the source to the destination folder (unless -MonitorOnly is specified),
then sets up a FileSystemWatcher to monitor real-time file changes (create, modify, delete, rename) and applies those changes to the destination path.

Author: Raymond Slater
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Path to the source folder to monitor.")]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath,

    [Parameter(Mandatory = $true, HelpMessage = "Path to the destination folder where changes will be copied.")]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationPath,

    [Parameter(HelpMessage = "Skips the initial one-time sync and only monitors changes.")]
    [switch]$MonitorOnly
)

# === Validate Source ===
if (-not (Test-Path $SourcePath)) {
    Write-Error "Source folder does not exist: $SourcePath"
    exit 1
}

# === Ensure Destination Exists ===
if (-not (Test-Path $DestinationPath)) {
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
}

# === Initial One-Time Sync ===
if (-not $MonitorOnly) {
    Write-Host "Performing one-time sync from $SourcePath to $DestinationPath..."
    robocopy $SourcePath $DestinationPath /MIR /R:1 /W:1 /MT:16
    Write-Host "Initial sync complete."
} else {
    Write-Host "Skipping initial sync due to -MonitorOnly flag."
}

# === Setup FileSystemWatcher ===
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $SourcePath
$watcher.IncludeSubdirectories = $true
$watcher.EnableRaisingEvents = $true
$watcher.Filter = "*.*"

# === Action on Change ===
$action = {
    $changeType = $Event.SourceEventArgs.ChangeType
    $fullPath = $Event.SourceEventArgs.FullPath
    $relativePath = $fullPath.Substring(${using:SourcePath}.Length).TrimStart('\')
    $targetPath = Join-Path ${using:DestinationPath} $relativePath

    try {
        switch ($changeType) {
            'Deleted' {
                if (Test-Path $targetPath) {
                    Remove-Item $targetPath -Force
                    Write-Host "Deleted: $relativePath"
                }
            }
            'Renamed' {
                $oldFullPath = $Event.SourceEventArgs.OldFullPath
                $oldRelative = $oldFullPath.Substring(${using:SourcePath}.Length).TrimStart('\')
                $oldTarget = Join-Path ${using:DestinationPath} $oldRelative
                if (Test-Path $oldTarget) {
                    Rename-Item $oldTarget -NewName (Split-Path $targetPath -Leaf)
                    Write-Host "Renamed: $oldRelative -> $relativePath"
                }
            }
            Default {
                $targetFolder = Split-Path $targetPath -Parent
                if (-not (Test-Path $targetFolder)) {
                    New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
                }
                Copy-Item $fullPath -Destination $targetPath -Force
                Write-Host "${changeType}: $relativePath"
            }
        }
    } catch {
        Write-Warning "Error processing $changeType for ${relativePath}: $_"
    }
}

# === Register Events ===
Register-ObjectEvent $watcher "Created" -Action $action | Out-Null
Register-ObjectEvent $watcher "Changed" -Action $action | Out-Null
Register-ObjectEvent $watcher "Deleted" -Action $action | Out-Null
Register-ObjectEvent $watcher "Renamed" -Action $action | Out-Null

Write-Host "Monitoring $SourcePath for changes..."
Write-Host "Press Ctrl+C to exit."

while ($true) {
    Start-Sleep -Seconds 1
}
