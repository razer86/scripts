<#
  Removes an existing Atera Agent installation (including the bundled
  Splashtop Streamer remote-access component) and cleans up any leftover
  files, folders, registry keys, services, and scheduled tasks so the
  device is clean for a fresh Atera agent push.

  Runs standalone -- as a ScreenConnect command or directly in an elevated
  PowerShell session on the device. Writes a running summary to the
  console/output stream as it goes.

  Pass -DryRun to only report what would be removed, without changing
  anything on the device.
#>

param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

$actions = New-Object System.Collections.Generic.List[string]

function Add-Action($msg) {
  $prefix = if ($DryRun) { '[DRY RUN] ' } else { '' }
  Write-Host "$prefix$msg"
  $actions.Add("$prefix$msg")
}

$uninstallRoots = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Remove-BundledApp {
  param(
    [string]   $AppLabel,
    [string]   $DisplayNameFilter,
    [string[]] $ServiceNames,
    [string[]] $ProcessNames,
    [string[]] $Folders,
    [string[]] $PerUserRelativeFolders,
    [string[]] $RegKeys,
    [string]   $ScheduledTaskFilter
  )

  Add-Action "--- $AppLabel ---"

  # Stop and remove services
  foreach ($svcName in $ServiceNames) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc) {
      if ($DryRun) {
        Add-Action "Would stop and delete service '$svcName' (current status: $($svc.Status))."
      } else {
        try {
          Stop-Service -Name $svcName -Force -ErrorAction Stop
          Add-Action "Stopped service '$svcName'."
        } catch {
          Add-Action "Failed to stop service '$svcName': $($_.Exception.Message)"
        }
        try {
          & sc.exe delete $svcName | Out-Null
          Add-Action "Deleted service '$svcName'."
        } catch {
          Add-Action "Failed to delete service '$svcName': $($_.Exception.Message)"
        }
      }
    }
  }

  # Kill running processes
  foreach ($procName in $ProcessNames) {
    $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
    if ($procs) {
      if ($DryRun) {
        Add-Action "Would kill running process '$procName' ($($procs.Count) instance(s))."
      } else {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Add-Action "Killed running process '$procName'."
      }
    }
  }

  # Run the official uninstaller if one is registered (covers MSI and EXE installs)
  $uninstallEntries = Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like $DisplayNameFilter }

  foreach ($entry in $uninstallEntries) {
    $uninstallString = $entry.UninstallString
    if (-not $uninstallString) { continue }

    if ($DryRun) {
      Add-Action "Would run uninstaller for '$($entry.DisplayName)' -> $uninstallString"
      continue
    }

    Add-Action "Found uninstall entry '$($entry.DisplayName)' -> $uninstallString"
    try {
      if ($uninstallString -match 'msiexec') {
        $productCode = [regex]::Match($uninstallString, '\{[0-9A-Fa-f\-]+\}').Value
        if ($productCode) {
          Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $productCode /qn /norestart" -Wait -ErrorAction Stop
          Add-Action "Ran msiexec silent uninstall for $productCode."
        }
      } else {
        $exePath, $exeArgs = $uninstallString -split '(?<=\.exe"?)\s+', 2
        $exePath = $exePath.Trim('"')
        $silentArgs = if ($exeArgs) { "$exeArgs /S /silent /verysilent" } else { '/S /silent /verysilent' }
        Start-Process -FilePath $exePath -ArgumentList $silentArgs -Wait -ErrorAction Stop
        Add-Action "Ran EXE silent uninstall: $exePath $silentArgs"
      }
    } catch {
      Add-Action "Uninstaller for '$($entry.DisplayName)' failed or was not silent-capable: $($_.Exception.Message)"
    }
  }

  if (-not $DryRun -and $uninstallEntries) {
    Start-Sleep -Seconds 5
  }

  # Remove leftover folders (including per-user AppData copies)
  $allFolders = New-Object System.Collections.Generic.List[string]
  $Folders | Where-Object { $_ } | ForEach-Object { $allFolders.Add($_) }
  if ($PerUserRelativeFolders) {
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      foreach ($relative in $PerUserRelativeFolders) {
        $allFolders.Add((Join-Path $_.FullName $relative))
      }
    }
  }

  foreach ($folder in ($allFolders | Select-Object -Unique)) {
    if ($folder -and (Test-Path $folder)) {
      if ($DryRun) {
        Add-Action "Would remove folder '$folder'."
      } else {
        try {
          Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
          Add-Action "Removed folder '$folder'."
        } catch {
          Add-Action "Failed to remove folder '$folder': $($_.Exception.Message)"
        }
      }
    }
  }

  # Remove leftover registry keys
  foreach ($key in $RegKeys) {
    if (Test-Path $key) {
      if ($DryRun) {
        Add-Action "Would remove registry key '$key'."
      } else {
        try {
          Remove-Item -Path $key -Recurse -Force -ErrorAction Stop
          Add-Action "Removed registry key '$key'."
        } catch {
          Add-Action "Failed to remove registry key '$key': $($_.Exception.Message)"
        }
      }
    }
  }

  # Remove any remaining uninstall registry entries
  $remainingUninstallEntries = Get-ItemProperty -Path $uninstallRoots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like $DisplayNameFilter }
  foreach ($entry in $remainingUninstallEntries) {
    if ($DryRun) {
      Add-Action "Would remove uninstall registry entry '$($entry.DisplayName)'."
    } else {
      try {
        Remove-Item -Path $entry.PSPath -Recurse -Force -ErrorAction Stop
        Add-Action "Removed uninstall registry entry '$($entry.DisplayName)'."
      } catch {
        Add-Action "Failed to remove uninstall registry entry '$($entry.DisplayName)': $($_.Exception.Message)"
      }
    }
  }

  # Remove scheduled tasks
  if ($ScheduledTaskFilter) {
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like $ScheduledTaskFilter }
    foreach ($task in $tasks) {
      if ($DryRun) {
        Add-Action "Would remove scheduled task '$($task.TaskPath)$($task.TaskName)'."
      } else {
        try {
          Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction Stop
          Add-Action "Removed scheduled task '$($task.TaskPath)$($task.TaskName)'."
        } catch {
          Add-Action "Failed to remove scheduled task '$($task.TaskName)': $($_.Exception.Message)"
        }
      }
    }
  }
}

Remove-BundledApp -AppLabel 'Atera Agent' -DisplayNameFilter '*Atera*' `
  -ServiceNames @('AteraAgent', 'AteraAgentMaintenance') `
  -ProcessNames @('AteraAgent', 'AteraAgentPackage', 'CoreAgent', 'AteraAgentMaintenance') `
  -Folders @(
    "$env:ProgramFiles\Atera Networks",
    "${env:ProgramFiles(x86)}\Atera Networks",
    "$env:ProgramData\Atera Networks",
    "$env:ProgramData\ATERA Networks"
  ) `
  -PerUserRelativeFolders @('AppData\Local\Atera Networks') `
  -RegKeys @(
    'HKLM:\SOFTWARE\Atera Networks',
    'HKLM:\SOFTWARE\WOW6432Node\Atera Networks'
  ) `
  -ScheduledTaskFilter '*Atera*'

Remove-BundledApp -AppLabel 'Splashtop Streamer (bundled with Atera)' -DisplayNameFilter '*Splashtop*' `
  -ServiceNames @('SplashtopRemoteService', 'SplashtopSoftwareUpdater') `
  -ProcessNames @('SRServer', 'SRService', 'SRManager', 'SPLog') `
  -Folders @(
    "$env:ProgramFiles\Splashtop",
    "${env:ProgramFiles(x86)}\Splashtop",
    "$env:ProgramFiles\Splashtop Inc",
    "${env:ProgramFiles(x86)}\Splashtop Inc",
    "$env:ProgramData\Splashtop",
    "$env:ProgramData\Splashtop Inc"
  ) `
  -PerUserRelativeFolders @('AppData\Local\Splashtop', 'AppData\Roaming\Splashtop') `
  -RegKeys @(
    'HKLM:\SOFTWARE\Splashtop Inc.',
    'HKLM:\SOFTWARE\WOW6432Node\Splashtop Inc.'
  ) `
  -ScheduledTaskFilter '*Splashtop*'

# Final verification
$remaining = @()
if (Get-Service -Name 'AteraAgent' -ErrorAction SilentlyContinue) { $remaining += 'AteraAgent service' }
if (Get-Service -Name 'SplashtopRemoteService' -ErrorAction SilentlyContinue) { $remaining += 'SplashtopRemoteService service' }
foreach ($folder in @(
  "$env:ProgramFiles\Atera Networks", "${env:ProgramFiles(x86)}\Atera Networks",
  "$env:ProgramData\Atera Networks", "$env:ProgramData\ATERA Networks",
  "$env:ProgramFiles\Splashtop", "${env:ProgramFiles(x86)}\Splashtop",
  "$env:ProgramFiles\Splashtop Inc", "${env:ProgramFiles(x86)}\Splashtop Inc",
  "$env:ProgramData\Splashtop", "$env:ProgramData\Splashtop Inc"
)) {
  if ($folder -and (Test-Path $folder)) { $remaining += $folder }
}
foreach ($key in @(
  'HKLM:\SOFTWARE\Atera Networks', 'HKLM:\SOFTWARE\WOW6432Node\Atera Networks',
  'HKLM:\SOFTWARE\Splashtop Inc.', 'HKLM:\SOFTWARE\WOW6432Node\Splashtop Inc.'
)) {
  if (Test-Path $key) { $remaining += $key }
}

$summary = ($actions -join "`n")

if ($DryRun) {
  $summary += "`n`nThis was a dry run -- nothing was changed on this device."
  Write-Host "Dry run complete. No changes were made."
} elseif ($remaining.Count -gt 0) {
  $summary += "`n`nItems still present after cleanup: " + ($remaining -join ', ')
  Write-Host "Cleanup completed with leftovers: $($remaining -join ', ')"
} else {
  Write-Host "Atera agent and Splashtop Streamer removed; device is clean."
}

Write-Host "`n----- Summary -----`n$summary"
