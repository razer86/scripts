<#
# =========================================
# ===   Get-LogonHistory.ps1            ===
# =========================================
.SYNOPSIS
    Lists recent interactive user logon/logoff activity on the local Windows
    device, filtering out noisy service/network/system logons.

.DESCRIPTION
    This script:
      - Reads Security log events 4624 (logon), 4634/4647 (logoff) within a
        configurable lookback window
      - Parses the event XML for TargetUserName, LogonType, IpAddress, and
        LogonId
      - Filters to human-relevant logon types by default: Interactive (2),
        RemoteInteractive/RDP (10), Unlock (7), CachedInteractive (11)
      - Pairs each logon with its matching logoff (by LogonId) to compute
        session duration where available
      - Collapses the duplicate linked logon UAC records for admin sign-ins
      - Labels RDP reconnects (4624 type 10 followed by 4778) as "RDP Reconnect"
        and links each one to the session it resumed, pulling in that
        session's original logon even if it predates the lookback window
      - Returns PSCustomObjects for use in scripts / logging
      - When run as a script, prints a formatted table

    Requires that Security log auditing for Logon/Logoff events is enabled
    (Local/Group Policy: Advanced Audit Policy Configuration > Logon/Logoff).
    Without auditing enabled, 4624/4634 events will not be recorded and this
    script will return no results.

.PARAMETER HoursLookback
    Number of hours back from now to search the Security log. Default is 24.

.PARAMETER IncludeAllTypes
    Include every logon type (network, service, batch, etc.) instead of just
    the human-relevant interactive/RDP/unlock types.

.EXAMPLE
    .\Get-LogonHistory.ps1
    Shows interactive/RDP logons on the local computer from the last 24 hours.

    .\Get-LogonHistory.ps1 -HoursLookback 168
    Looks back 7 days.

    .\Get-LogonHistory.ps1 -IncludeAllTypes
    Also shows network, service, and batch logons.

.NOTES
    Author  : Raymond Slater
    Source  : https://github.com/razer86/scripts

#>

# =========================================
# ===   Parameters                      ===
# =========================================

[CmdletBinding()]
param (
    [int]$HoursLookback = 24,
    [switch]$IncludeAllTypes
)

function Get-LogonHistory {
    [CmdletBinding()]
    param (
        [int]$HoursLookback = 24,
        [switch]$IncludeAllTypes
    )

    $logonTypeNames = @{
        2  = 'Interactive'
        3  = 'Network'
        4  = 'Batch'
        5  = 'Service'
        7  = 'Unlock'
        8  = 'NetworkCleartext'
        9  = 'NewCredentials'
        10 = 'RemoteInteractive'
        11 = 'CachedInteractive'
    }

    # Human-relevant logon types shown by default
    $interactiveTypes = 2, 7, 10, 11

    # A 4778 "session reconnected" this soon after a type-10 logon means that logon was a reconnect
    $reconnectWindowSeconds = 10

    $startTime = (Get-Date).AddHours(-1 * [math]::Abs($HoursLookback))

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Security'
            Id        = 4624, 4634, 4647, 4778
            StartTime = $startTime
        } -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -like '*No events were found that match the specified selection criteria*') {
            return @()
        }
        Write-Error "Failed to query Security event log: $($_.Exception.Message)"
        return @()
    }

    $logons     = @{}
    $logoffs    = @{}
    $reconnects = [System.Collections.Generic.List[object]]::new()

    foreach ($event in $events) {
        $data = Get-EventData $event

        if ($event.Id -eq 4624) {
            $logonType = [int]($data['LogonType'])

            if (-not $IncludeAllTypes -and ($interactiveTypes -notcontains $logonType)) {
                continue
            }

            # Skip machine/service accounts (SYSTEM, DWM-*, UMFD-*, and computer accounts ending in $)
            $user = $data['TargetUserName']
            if ($user -match '^(SYSTEM|DWM-\d+|UMFD-\d+)$' -or $user -like '*$') {
                continue
            }

            # With UAC, an admin sign-in logs two linked logons (elevated + filtered token) that
            # point at each other - keep only the first one seen.
            $linkedId = $data['TargetLinkedLogonId']
            if ($linkedId -and $logons.ContainsKey($linkedId)) {
                continue
            }

            $logons[$data['TargetLogonId']] = New-LogonRecord -LogEvent $event -Data $data
        }
        elseif ($event.Id -eq 4778) {
            $reconnects.Add([pscustomobject]@{
                Time           = $event.TimeCreated
                UserName       = $data['AccountName']
                SessionLogonId = $data['LogonID']
            })
        }
        else {
            # 4634 / 4647 logoff events
            $id = $data['TargetLogonId']
            if ($id -and -not $logoffs.ContainsKey($id)) {
                $logoffs[$id] = $event.TimeCreated
            }
        }
    }

    foreach ($id in $logons.Keys) {
        if ($logoffs.ContainsKey($id)) {
            Set-LogoffTime -Logon $logons[$id] -LogoffTime $logoffs[$id]
        }
    }

    # An RDP reconnect creates a new type-10 logon, hands the user back their existing session
    # (event 4778, which names that session's LogonId), then logs the new logon off within a
    # second. Label these instead of reporting a zero-length session.
    foreach ($logon in @($logons.Values | Where-Object LogonType -eq 10)) {
        $match = $reconnects |
            Where-Object {
                $_.UserName -eq $logon.UserName -and
                ($_.Time - $logon.Time).TotalSeconds -ge 0 -and
                ($_.Time - $logon.Time).TotalSeconds -le $reconnectWindowSeconds
            } |
            Sort-Object Time | Select-Object -First 1

        if ($match) {
            $logon.LogonTypeName = 'RDP Reconnect'
            $logon.ReconnectedTo = $match.SessionLogonId
            $logon.LogoffTime    = $null
            $logon.Duration      = $null
        }
    }

    # Pull in the original session each reconnect resumed, even if it began before the lookback window
    $sessionIds = @($logons.Values.ReconnectedTo | Where-Object { $_ } | Select-Object -Unique)
    foreach ($sessionId in $sessionIds) {
        $known = $logons.Values | Where-Object { $_.LogonId -eq $sessionId -or $_.LinkedLogonId -eq $sessionId } | Select-Object -First 1
        if ($known) {
            if ($known.LogonId -ne $sessionId) {
                $logons.Values | Where-Object ReconnectedTo -eq $sessionId | ForEach-Object { $_.ReconnectedTo = $known.LogonId }
            }
            continue
        }

        $original = Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction SilentlyContinue -FilterXPath (
            "*[System[EventID=4624] and EventData[Data[@Name='TargetLogonId']='$sessionId']]")
        if (-not $original) {
            $logons.Values | Where-Object ReconnectedTo -eq $sessionId | ForEach-Object { $_.ReconnectedTo = "$sessionId (logon no longer in log)" }
            continue
        }

        $record = New-LogonRecord -LogEvent $original -Data (Get-EventData $original)
        $logoff = Get-WinEvent -LogName Security -MaxEvents 1 -ErrorAction SilentlyContinue -FilterXPath (
            "*[System[(EventID=4634 or EventID=4647)] and EventData[Data[@Name='TargetLogonId']='$sessionId']]")
        if ($logoff) {
            Set-LogoffTime -Logon $record -LogoffTime $logoff.TimeCreated
        }
        else {
            $record.Duration = 'No logoff recorded'
        }
        $logons[$sessionId] = $record
    }

    return $logons.Values | Sort-Object Time -Descending
}

function Get-EventData {
    param ([Parameter(Mandatory)]$LogEvent)

    $data = @{}
    foreach ($node in ([xml]$LogEvent.ToXml()).Event.EventData.Data) {
        $data[$node.Name] = $node.'#text'
    }
    return $data
}

function New-LogonRecord {
    param (
        [Parameter(Mandatory)]$LogEvent,
        [Parameter(Mandatory)][hashtable]$Data
    )

    # $logonTypeNames comes from the calling Get-LogonHistory scope
    $logonType = [int]$Data['LogonType']
    [pscustomobject]@{
        LogonId       = $Data['TargetLogonId']
        LinkedLogonId = $Data['TargetLinkedLogonId']
        Time          = $LogEvent.TimeCreated
        UserName      = $Data['TargetUserName']
        User          = "$($Data['TargetDomainName'])\$($Data['TargetUserName'])"
        LogonType     = $logonType
        LogonTypeName = $logonTypeNames[$logonType]
        SourceIP      = $Data['IpAddress']
        Workstation   = $Data['WorkstationName']
        ReconnectedTo = $null
        LogoffTime    = $null
        Duration      = $null
    }
}

function Set-LogoffTime {
    param (
        [Parameter(Mandatory)]$Logon,
        [Parameter(Mandatory)][datetime]$LogoffTime
    )

    $Logon.LogoffTime = $LogoffTime
    $span = $LogoffTime - $Logon.Time
    if ($span.TotalSeconds -ge 0) {
        $Logon.Duration = "{0}d {1:00}h {2:00}m" -f $span.Days, $span.Hours, $span.Minutes
    }
}

# =========================================
# ===   Script Output                   ===
# =========================================

$results = Get-LogonHistory -HoursLookback $HoursLookback -IncludeAllTypes:$IncludeAllTypes

Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ("Computer         : {0}" -f $env:COMPUTERNAME) -ForegroundColor Cyan
Write-Host ("Lookback         : {0} hour(s)" -f $HoursLookback) -ForegroundColor Cyan
Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

$oldestEvent = Get-WinEvent -LogName Security -MaxEvents 1 -Oldest -ErrorAction SilentlyContinue
if ($oldestEvent -and $oldestEvent.TimeCreated -gt (Get-Date).AddHours(-[math]::Abs($HoursLookback))) {
    Write-Host ("WARNING: The Security log only goes back to {0} - older logons and the original sessions behind reconnects have been overwritten. Increase the Security log's maximum size to keep more history." -f $oldestEvent.TimeCreated) -ForegroundColor Yellow
}

if (-not $results -or $results.Count -eq 0) {
    Write-Host "No matching logon events found. If this is unexpected, verify that Security auditing for Logon/Logoff is enabled." -ForegroundColor DarkYellow
}
else {
    $results |
        Select-Object Time, User, LogonTypeName, SourceIP, Workstation, LogonId, ReconnectedTo, LogoffTime, Duration |
        Format-Table -AutoSize
}
