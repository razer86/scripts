<#
# =========================================
# ===   Get-LastBootReason.ps1         ===
# =========================================
.SYNOPSIS
    Determines the last boot time for the local Windows device and classifies
    whether the last shutdown/restart was planned or unexpected.

.DESCRIPTION
    This script:
      - Reads the last boot time from Win32_OperatingSystem
      - Queries the System event log for shutdown/restart related events
        (IDs 1074, 1076, 6006, 6008, 41) in a configurable lookback window
      - Picks the most relevant event by priority (41, 6008, 1076, 1074, 6006)
      - Classifies the shutdown as Planned, Graceful, Unexpected, CrashOrPowerLoss,
        or NoEventFound
      - Returns a PSCustomObject with detailed data for use in scripts / logging
      - When run as a script, prints a coloured summary + formatted message

.PARAMETER MinutesLookback
    Number of minutes before the last boot time to search in the System log
    for shutdown/restart events. Default is 30.

.EXAMPLE
    .\Get-LastBootReason.ps1
    Queries the local computer and prints summary + message.

    .\Get-LastBootReason.ps1 -MinutesLookback 60
    Optional adjust lookback time for shutdown/restart events

.NOTES
    Author  : Raymond Slater
    Source  : https://github.com/razer86/scripts

#>

# =========================================
# ===   Parameters                      ===
# =========================================

[CmdletBinding()]
param (
    [int]$MinutesLookback = 30
)

function Get-LastBootReason {
    [CmdletBinding()]
    param (
        [int]$MinutesLookback = 30
    )

    # Event IDs to check
    $eventIds      = 1074, 1076, 6006, 6008, 41
    $priorityOrder = 41, 6008, 1076, 1074, 6006

    # --- Get local boot time ---
    try {
        $boot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime

        if ($boot.Kind -eq [System.DateTimeKind]::Unspecified) {
            $bootLocal = [DateTime]::SpecifyKind($boot, [System.DateTimeKind]::Local)
        } else {
            $bootLocal = $boot.ToLocalTime()
        }

        # Calculate uptime
        $uptimeSpan = (Get-Date) - $bootLocal
        $uptimeFormatted = "{0}d {1:00}h {2:00}m {3:00}s" -f $uptimeSpan.Days, $uptimeSpan.Hours, $uptimeSpan.Minutes, $uptimeSpan.Seconds



    }
    catch {
        return [pscustomobject]@{
            BootTime          = $null
            BootTimeLocal     = $null
            Uptime            = $null
            ShutdownEventId   = $null
            ShutdownTime      = $null
            ShutdownSource    = $null
            Classification    = "Error"
            ReasonSummary     = "Failed to query Win32_OperatingSystem."
            Message           = $_.Exception.Message
        }
    }

    # --- Query recent shutdown/restart events ---
    $startTime = $bootLocal.AddMinutes(-1 * [math]::Abs($MinutesLookback))
    $endTime   = $bootLocal

    try {
    $shutdownEvents = Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Id        = $eventIds
        StartTime = $startTime
        EndTime   = $endTime
    } -ErrorAction Stop |
    Sort-Object TimeCreated -Descending
}
catch {
    if ($_.Exception.Message -like '*No events were found that match the specified selection criteria*') {
        # This is the "no events in this window" case – treat as normal.
        $shutdownEvents = @()
    }
    else {
        # Real error querying the log
        return [pscustomobject]@{
            BootTime          = $boot
            BootTimeLocal     = $bootLocal
            Uptime            = $uptimeFormatted
            ShutdownEventId   = $null
            ShutdownTime      = $null
            ShutdownSource    = $null
            Classification    = "Error"
            ReasonSummary     = "Failed to query System event log."
            Message           = $_.Exception.Message
        }
    }
}


    # --- Pick highest priority shutdown event ---
    $primaryEvent = $null

    foreach ($id in $priorityOrder) {
        $primaryEvent = $shutdownEvents | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if ($primaryEvent) { break }
    }

    $classification = "NoEventFound"
    $reasonSummary  = "No shutdown, restart, or power event was found in the lookback window."


    if ($primaryEvent) {
        switch ($primaryEvent.Id) {
            1074 { $classification = "Planned";              $reasonSummary = "Planned restart/shutdown (User32 1074)." }
            6006 { $classification = "Graceful";             $reasonSummary = "Clean shutdown; Event Log service stopped (6006)." }
            6008 { $classification = "Unexpected";           $reasonSummary = "Unexpected shutdown (6008)." }
            41   { $classification = "CrashOrPowerLoss";     $reasonSummary = "Critical Kernel-Power (41); likely crash or power loss." }
            1076 { $classification = "UnexpectedWithReason"; $reasonSummary = "Unexpected shutdown with recorded reason (1076)." }
        }
    }

    # --- Source Description Mapping ---
    $sourceDescription = switch ($primaryEvent.ProviderName) {
        "User32"          { "User-initiated or Windows Update initiated restart" }
        "EventLog"        { "Clean shutdown; Event Log service stopped" }
        "Kernel-Power"    { "Critical power loss, crash, or forced shutdown" }
        "Kernel-General"  { "General kernel lifecycle event during shutdown/startup" }
        "Service Control Manager" { "Normal service shutdown sequence" }
        default {
            if ($primaryEvent) { "Event logged by $($primaryEvent.ProviderName)" }
            else { $null }
        }
    }

# Build a combined source line like: "User32 (User-initiated restart)"
$sourceCombined = if ($primaryEvent) {
    if ($sourceDescription) {
        "$($primaryEvent.ProviderName) ($sourceDescription)"
    } else {
        $primaryEvent.ProviderName
    }
} else {
    "(none)"
}

return [pscustomobject]@{
    BootTime        = $boot
    BootTimeLocal   = $bootLocal
    Uptime          = $uptimeFormatted
    ShutdownEventId = if ($primaryEvent) { $primaryEvent.Id } else { $null }
    ShutdownTime    = if ($primaryEvent) { $primaryEvent.TimeCreated } else { $null }
    ShutdownSource  = $sourceCombined
    Classification  = $classification
    ReasonSummary   = $reasonSummary
    Message         = if ($primaryEvent) {
        $primaryEvent.Message
    } else {
@"
This may indicate:
  - The device was powered on from a cold boot
  - The shutdown was a hard power loss (no event logged)
  - The shutdown occurred earlier than the lookback period
  - The System event log was cleared or overwritten
"@
    }
}


}

# =========================================
# ===   Script Output                   ===
# =========================================

$r = Get-LastBootReason -MinutesLookback $MinutesLookback

Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ("Computer              : {0}" -f $env:COMPUTERNAME) -ForegroundColor Cyan
Write-Host ("Last Boot (Local)     : {0} (Uptime {1})" -f $r.BootTimeLocal, $r.Uptime) -ForegroundColor Yellow

if ($r.ShutdownEventId) {
    switch ($r.Classification) {
        "Planned"              { $color = "Green" }
        "Graceful"             { $color = "Green" }
        "Unexpected"           { $color = "Red" }
        "CrashOrPowerLoss"     { $color = "Red" }
        "UnexpectedWithReason" { $color = "DarkYellow" }
        "Error"                { $color = "Red" }
        default                { $color = "DarkYellow" }
    }

    Write-Host ("Shutdown Event        : {0} ({1})" -f $r.ShutdownEventId, $r.Classification) -ForegroundColor $color
    Write-Host ("Event Time            : {0}" -f $r.ShutdownTime) -ForegroundColor Yellow
    Write-Host ("Source                : {0}" -f $r.ShutdownSource) -ForegroundColor Yellow
    #Write-Host ("Summary               : {0}" -f $r.ReasonSummary) -ForegroundColor White
} else {
    Write-Host "Shutdown Event        : (none in lookback window)" -ForegroundColor DarkYellow
    #Write-Host ("Summary              : {0}" -f $r.ReasonSummary) -ForegroundColor White
}
if ($r.Message) {
    $msgObj = [pscustomobject]@{ Message = $r.Message }
    $msgObj | Format-List
}
