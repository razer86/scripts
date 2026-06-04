<#
.SYNOPSIS
    Detects and remediates an oversized C:\Windows\Panther\monitor folder.

.DESCRIPTION
    Checks the size of C:\Windows\Panther\monitor against a 1 GB threshold.
    If over threshold, unloads the WinSetupMon filter driver, removes its log files,
    and sets the driver start type to demand so it no longer auto-starts.

    Returns a PSCustomObject with: ComputerName, SizeBeforeGB, FileCount,
    DriverState, StartType, Action, SizeAfterGB.

    Designed for use as an RMM or Intune detection/remediation script.

.EXAMPLE
    # Run interactively and inspect the result
    .\Test-PantherMonitorSize.ps1

.EXAMPLE
    # Use in an RMM script to flag non-compliant devices
    $result = .\Test-PantherMonitorSize.ps1
    if ($result.Action -eq 'Remediated') { Write-Host "$($result.ComputerName) remediated: was $($result.SizeBeforeGB) GB" }

.NOTES
    Author: Raymond Slater
    Version: 1.0
#>

$MonitorPath = 'C:\Windows\Panther\monitor'
$ThresholdGB = 1
$Result = [PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    SizeBeforeGB = 0
    FileCount    = 0
    DriverState  = $null
    StartType    = $null
    Action       = 'None'
    SizeAfterGB  = 0
}

if (-not (Test-Path $MonitorPath)) { 
    $Result.Action = 'PathNotPresent'
    return $Result 
}

$Files = Get-ChildItem $MonitorPath -ErrorAction SilentlyContinue
$Result.FileCount = $Files.Count
$Result.SizeBeforeGB = [math]::Round((($Files | Measure-Object Length -Sum).Sum / 1GB), 2)

$Svc = Get-Service WinSetupMon -ErrorAction SilentlyContinue
if ($Svc) {
    $Result.DriverState = $Svc.Status
    $Result.StartType   = (Get-CimInstance Win32_SystemDriver -Filter "Name='WinSetupMon'").StartMode
}

if ($Result.SizeBeforeGB -gt $ThresholdGB) {
    Write-Host "Remediating $($env:COMPUTERNAME): $($Result.SizeBeforeGB) GB" -ForegroundColor Yellow
    & fltmc.exe unload WinSetupMon 2>$null
    Get-ChildItem "$MonitorPath\WinSetupMon*.log" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    & sc.exe config WinSetupMon start= demand | Out-Null
    $Result.Action = 'Remediated'
    $Result.SizeAfterGB = [math]::Round(((Get-ChildItem $MonitorPath -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB), 2)
} else {
    $Result.Action = 'NoActionRequired'
    $Result.SizeAfterGB = $Result.SizeBeforeGB
}

return $Result