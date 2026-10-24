<#
.SYNOPSIS
    Self-test for Invoke-EventLogReview.ps1. No Pester needed.

.DESCRIPTION
    Feeds synthetic events through the real functions, so the rules, the
    restart correlation and the masking are checked without touching the
    machine's event log.

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\EventLogReview.Tests.ps1

    Exits 0 when everything passes, 1 otherwise. Works in Windows PowerShell 5.1
    and PowerShell 7.
#>
[CmdletBinding()]
param ()

. (Join-Path $PSScriptRoot 'Invoke-EventLogReview.ps1')

$script:Pass = 0
$script:Fail = 0

function Assert-True {
    param($Condition, [string]$Name)
    if ($Condition) { $script:Pass++ } else { $script:Fail++; Write-Host "FAIL: $Name" -ForegroundColor Red }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Name)
    if ("$Actual" -eq "$Expected") { $script:Pass++ }
    else { $script:Fail++; Write-Host "FAIL: $Name`n   expected: $Expected`n   actual:   $Actual" -ForegroundColor Red }
}

$t0 = Get-Date '2026-10-20 09:00:00'

function New-Ev {
    param(
        [string]$Provider, [int]$Id, [int]$Level = 2, [string]$Log = 'System',
        [datetime]$Time = $t0, [object[]]$Props = @(), [object]$Msg = $null
    )
    [pscustomobject]@{
        Time = $Time; Provider = $Provider; Id = $Id; Level = $Level; Log = $Log
        RecordId = [guid]::NewGuid(); Props = $Props; Raw = $null; Msg = $Msg
    }
}
function New-K41 {
    param([datetime]$Time, [object]$Code = 0, [object]$Sleep = 0, [object]$PowerButton = 0)
    New-Ev 'Microsoft-Windows-Kernel-Power' 41 1 'System' $Time @($Code, 0, 0, 0, 0, $Sleep, $PowerButton, 0)
}
function New-E6008 {
    param([datetime]$Time, [string]$TimeText = '7:37:05 AM', [string]$DateText = '10/20/2026')
    New-Ev 'EventLog' 6008 2 'System' $Time @($TimeText, $DateText)
}
function New-Ser {
    param([datetime]$Time, [string]$Text)
    New-Ev 'Microsoft-Windows-WER-SystemErrorReporting' 1001 2 'System' $Time @($Text)
}
function Get-Finding {
    param($Findings, [string]$RuleId)
    @($Findings | Where-Object { $_.RuleId -eq $RuleId })[0]
}

# --- bugcheck lookup ----------------------------------------------------------
Assert-Equal (Get-BugcheckInfo 0x9F).Name 'DRIVER_POWER_STATE_FAILURE' 'bugcheck 0x9F name'
Assert-Equal (Get-BugcheckInfo 0x9F).Class 'Power' 'bugcheck 0x9F class'
Assert-Equal (Get-BugcheckInfo 0x124).Name 'WHEA_UNCORRECTABLE_ERROR' 'bugcheck 0x124 (three digits)'
Assert-Equal (Get-BugcheckInfo 0xC000021A).Name 'STATUS_SYSTEM_PROCESS_TERMINATED' 'bugcheck 0xC000021A'
Assert-Equal (Get-BugcheckInfo 0xDEADBEEF).Class 'Unknown' 'unknown stop code'

# --- number handling ----------------------------------------------------------
Assert-Equal (ConvertTo-UInt32Safe ([uint32]159)) 159 'uint32 passes through'
Assert-Equal (ConvertTo-UInt32Safe ([int]-1073741286)) 3221226010 'negative int32 becomes 0xC000021A'
Assert-Equal (ConvertTo-UInt32Safe '0x9f') 159 'hex string'
Assert-Equal (ConvertTo-UInt32Safe '159') 159 'decimal string'
Assert-Equal (ConvertTo-UInt32Safe 'junk') 0 'junk is zero'
Assert-Equal (ConvertTo-UInt32Safe $null) 0 'null is zero'

# --- restart correlation ------------------------------------------------------
$when = Get-Date '2026-10-20 16:49:00'
$inc = Get-RestartIncidents @(
    (New-K41 $when ([uint32]0x9F)), (New-E6008 $when.AddSeconds(19)),
    (New-Ser $when.AddMinutes(1) '0x0000009f (0x3, 0xffff, 0xffffc0, 0xffff)'))
Assert-Equal @($inc).Count 1 'K41 + 6008 + bugcheck record collapse to one incident'
Assert-Equal $inc[0].Kind 'BlueScreen' 'blue screen kind'
Assert-Equal $inc[0].Severity 'Critical' 'blue screen is critical'
Assert-Equal $inc[0].Title 'Blue screen: DRIVER_POWER_STATE_FAILURE (0x9F)' 'blue screen title'
Assert-Equal $inc[0].Class 'Power' 'blue screen class'
Assert-Equal $inc[0].Parameters '0x0, 0x0, 0x0, 0x0' 'K41 parameters used when present'

$inc = Get-RestartIncidents @((New-Ser $when '0x000000d1 (0x1, 0x2, 0x0, 0xfffff80000000000)'))
Assert-Equal $inc[0].StopCode '0xD1' 'stop code read from the bugcheck record alone'
Assert-Equal $inc[0].StopName 'DRIVER_IRQL_NOT_LESS_OR_EQUAL' 'stop name from the bugcheck record alone'

$inc = Get-RestartIncidents @((New-K41 $when ([int]-1073741286)), (New-E6008 $when))
Assert-Equal $inc[0].StopCode '0xC000021A' 'negative int32 stop code from K41'

$inc = Get-RestartIncidents @((New-K41 $when), (New-E6008 $when))
Assert-Equal $inc[0].Kind 'PowerLoss' 'K41 with no code is a power loss'
Assert-Equal $inc[0].Severity 'High' 'power loss is high'

$inc = Get-RestartIncidents @((New-K41 $when 0 0 ([uint64]132000000000000000)), (New-E6008 $when))
Assert-Equal $inc[0].Kind 'ForcedPowerOff' 'power button timestamp means forced power-off'

$inc = Get-RestartIncidents @((New-K41 $when 0 1), (New-E6008 $when))
Assert-True $inc[0].DuringSleep 'sleep flag is carried'

$inc = Get-RestartIncidents @((New-E6008 $when))
Assert-Equal $inc[0].Kind 'UnexpectedShutdown' '6008 alone'
Assert-Equal $inc[0].Severity 'Medium' '6008 alone is medium'

$inc = Get-RestartIncidents @((New-K41 $when.AddHours(-3)), (New-E6008 $when.AddHours(-3)), (New-K41 $when), (New-E6008 $when))
Assert-Equal @($inc).Count 2 'events hours apart are separate incidents'
Assert-True ($inc[0].Time -gt $inc[1].Time) 'incidents are newest first'

$none = Get-RestartIncidents @()
Assert-Equal $none.Count 0 'no events, no incidents'

$inc = Get-RestartIncidents @((New-E6008 $when 'junk' 'junk'))
Assert-True ($null -eq $inc[0].LastActivity) 'last activity is filled in later from the log, never guessed from 6008'

# --- silence before a restart ---------------------------------------------------
Assert-Equal (Format-Duration ([timespan]::FromMinutes(2.6))) '3m' 'duration in minutes'
Assert-Equal (Format-Duration ([timespan]::FromMinutes(95))) '1h 35m' 'duration in hours'
Assert-Equal (Format-Duration ([timespan]::FromHours(8.7))) '8h 42m' 'duration with minutes'
Assert-Equal (Format-Duration ([timespan]::FromHours(30))) '1d 6h' 'duration in days'

# --- dump headers and graphics-hang findings ----------------------------------
function New-DumpBytes {
    param([string]$Signature = 'PAGEDU64', [uint32]$Code = 0x141, [uint64]$P1 = 4660, [int]$Length = 0x60)
    $b = New-Object byte[] $Length
    [Text.Encoding]::ASCII.GetBytes($Signature).CopyTo($b, 0)
    if ($Length -ge 0x3C) { [BitConverter]::GetBytes($Code).CopyTo($b, 0x38) }
    if ($Length -ge 0x48) { [BitConverter]::GetBytes($P1).CopyTo($b, 0x40) }
    return , $b
}
$h = ConvertFrom-DumpHeader (New-DumpBytes)
Assert-Equal $h.Code 321 'dump header stop code (0x141)'
Assert-Equal $h.Parameter1 4660 'dump header first parameter'
Assert-True ($null -eq (ConvertFrom-DumpHeader (New-DumpBytes 'PAGEDUMP'))) '32-bit dump signature is not decoded'
Assert-True ($null -eq (ConvertFrom-DumpHeader (New-DumpBytes 'NOTADUMP'))) 'unknown signature is not decoded'
Assert-True ($null -eq (ConvertFrom-DumpHeader ([byte[]](1, 2, 3)))) 'short input is not decoded'
Assert-True ($null -eq (ConvertFrom-DumpHeader $null)) 'null input is not decoded'
Assert-Equal (Get-BugcheckInfo 0x193).Name 'VIDEO_DXGKRNL_LIVEDUMP' 'live dump code 0x193'
Assert-Equal (Get-BugcheckInfo 0x141).Class 'Video' 'live dump code 0x141 is video'

function New-DumpEntry {
    param([string]$Code, [string]$Name, [string]$Class, [datetime]$When = $t0)
    [pscustomobject]@{ Kind = 'Live kernel'; Path = 'C:\x.dmp'; SizeMB = 0.3; Modified = $When; Code = $Code; CodeName = $Name; Class = $Class }
}
Assert-Equal @(ConvertTo-DumpFindings @()).Count 0 'no dumps, no dump finding'
Assert-Equal @(ConvertTo-DumpFindings @((New-DumpEntry '0x1B0' '' ''))).Count 0 'an unrecognised live dump code is listed but not claimed as a graphics hang'
$vf = ConvertTo-DumpFindings @((New-DumpEntry '0x141' 'VIDEO_ENGINE_TIMEOUT_DETECTED' 'Video' $t0), (New-DumpEntry '0x117' 'VIDEO_TDR_TIMEOUT_DETECTED' 'Video' $t0.AddMinutes(1)))
Assert-Equal $vf[0].Severity 'Medium' 'two graphics dumps are medium'
Assert-Equal $vf[0].Count 2 'graphics dumps are counted'
$vf3 = ConvertTo-DumpFindings @(1..3 | ForEach-Object { New-DumpEntry '0x141' 'VIDEO_ENGINE_TIMEOUT_DETECTED' 'Video' $t0.AddMinutes($_) })
Assert-Equal $vf3[0].Severity 'High' 'three graphics dumps escalate'
Assert-True ($vf3[0].Detail -match 'VIDEO_ENGINE_TIMEOUT_DETECTED \(0x141\) x3') 'dump finding summarises by stop code'

# --- incident findings --------------------------------------------------------
$three = Get-RestartIncidents @(
    (New-E6008 $when.AddDays(-2)), (New-E6008 $when.AddDays(-1)), (New-E6008 $when))
$f = ConvertTo-IncidentFindings $three
Assert-Equal $f.Count 1 'same kind of incident groups into one finding'
Assert-Equal $f[0].Count 3 'finding counts incidents'
Assert-Equal $f[0].Severity 'High' 'repeated unexpected shutdowns escalate'

$bs = ConvertTo-IncidentFindings (Get-RestartIncidents @((New-K41 $when ([uint32]0x116)), (New-K41 $when.AddDays(-1) ([uint32]0x116))))
Assert-Equal @($bs).Count 1 'same stop code groups together'
Assert-True ($bs[0].Explain -match 'graphics') 'video stop code uses video guidance'

# --- rules --------------------------------------------------------------------
$rules = Get-ReviewRules
$ids = @($rules | ForEach-Object { $_.Id })
Assert-Equal $ids.Count (@($ids | Select-Object -Unique).Count) 'rule ids are unique'
$valid = @('Critical', 'High', 'Medium', 'Low', 'Info')
$badRules = @($rules | Where-Object {
        -not $_.Title -or -not $_.Explain -or -not $_.Next -or ($valid -notcontains $_.Severity) -or
        ($_.EscalateTo -and ($valid -notcontains $_.EscalateTo)) })
Assert-Equal $badRules.Count 0 'every rule has text and a valid severity'

$svc = 1..3 | ForEach-Object { New-Ev 'Service Control Manager' 7031 2 'System' $t0.AddMinutes($_) @('Spooler', 1) }
$f = Get-Finding (Get-RuleFindings $svc $rules) 'svc-crashed'
Assert-Equal $f.Count 3 'service crash count'
Assert-Equal $f.Detail 'Spooler x3' 'service crash detail'
Assert-Equal $f.Severity 'Medium' 'three crashes stay medium'

$svc = 1..5 | ForEach-Object { New-Ev 'Service Control Manager' 7034 2 'System' $t0.AddMinutes($_) @('Spooler', 1) }
Assert-Equal (Get-Finding (Get-RuleFindings $svc $rules) 'svc-crashed').Severity 'High' 'five crashes of one service escalate'

$mixed = (1..3 | ForEach-Object { New-Ev 'Service Control Manager' 7031 2 'System' $t0 @("Svc$_", 1) })
Assert-Equal (Get-Finding (Get-RuleFindings $mixed $rules) 'svc-crashed').Severity 'Medium' 'escalation counts one service, not the total'

$app = 1..2 | ForEach-Object { New-Ev 'Application Error' 1000 2 'Application' $t0.AddMinutes($_) @('chrome.exe', '1.0', 'x', 'chrome.dll') }
$f = Get-Finding (Get-RuleFindings $app $rules) 'app-crash'
Assert-Equal $f.Detail 'chrome.exe [chrome.dll] x2' 'app crash names app and faulting module'

$timeout = New-Ev 'Service Control Manager' 7009 3 'System' $t0 @(30000, 'SlowSvc')
Assert-Equal (Get-Finding (Get-RuleFindings @($timeout) $rules) 'svc-timeout').Detail 'SlowSvc x1' 'timeout rule keys on the service (property 1)'

$disk = New-Ev 'disk' 7 2 'System' $t0 @('\Device\Harddisk1\DR1')
$f = Get-Finding (Get-RuleFindings @($disk) $rules) 'disk-bad-block'
Assert-Equal $f.Severity 'High' 'bad block is high'
Assert-Equal $f.Detail '\Device\Harddisk1\DR1 x1' 'bad block names the device'
Assert-Equal (Get-Finding (Get-RuleFindings @((New-Ev 'disk' 52 2)) $rules) 'disk-predicted-failure').Severity 'Critical' 'predicted failure is critical'

$d154 = 1..3 | ForEach-Object { New-Ev 'disk' 154 2 'System' $t0.AddMinutes($_) }
Assert-Equal (Get-Finding (Get-RuleFindings $d154 $rules) 'disk-hardware-error').Severity 'Medium' 'a few disk hardware errors are medium'
$d154many = 1..25 | ForEach-Object { New-Ev 'disk' 154 2 'System' $t0.AddMinutes($_) }
Assert-Equal (Get-Finding (Get-RuleFindings $d154many $rules) 'disk-hardware-error').Severity 'High' 'many disk hardware errors escalate'

$ntfs = New-Ev 'Ntfs' 55 2
Assert-True ($null -ne (Get-Finding (Get-RuleFindings @($ntfs) $rules) 'ntfs-corruption')) 'Ntfs provider matches'
$ntfs2 = New-Ev 'Microsoft-Windows-Ntfs' 55 2
Assert-True ($null -ne (Get-Finding (Get-RuleFindings @($ntfs2) $rules) 'ntfs-corruption')) 'Microsoft-Windows-Ntfs provider matches'

$whea2 = New-Ev 'Microsoft-Windows-WHEA-Logger' 18 2
Assert-Equal (Get-Finding (Get-RuleFindings @($whea2) $rules) 'whea').Severity 'Critical' 'fatal WHEA is critical'
$whea3 = 1..3 | ForEach-Object { New-Ev 'Microsoft-Windows-WHEA-Logger' 17 3 'System' $t0.AddMinutes($_) }
Assert-Equal (Get-Finding (Get-RuleFindings $whea3 $rules) 'whea').Severity 'Medium' 'a few corrected WHEA errors are medium'
$whea10 = 1..10 | ForEach-Object { New-Ev 'Microsoft-Windows-WHEA-Logger' 17 3 'System' $t0.AddMinutes($_) }
Assert-Equal (Get-Finding (Get-RuleFindings $whea10 $rules) 'whea').Severity 'High' 'many corrected WHEA errors escalate'

$wer = New-Ev 'Windows Error Reporting' 1001 4 'Application' $t0 @('LiveKernelEvent')
Assert-True ($null -ne (Get-Finding (Get-RuleFindings @($wer) $rules) 'kernel-watchdog')) 'LiveKernelEvent matches the watchdog rule'
$wer2 = New-Ev 'Windows Error Reporting' 1001 4 'Application' $t0 @('APPCRASH')
Assert-True ($null -eq (Get-Finding (Get-RuleFindings @($wer2) $rules) 'kernel-watchdog')) 'ordinary WER report does not'

Assert-True ($null -ne (Get-Finding (Get-RuleFindings @((New-Ev 'Microsoft-Windows-WindowsUpdateClient' 20 2)) $rules) 'wu-failures')) 'update failure at error level'
Assert-True ($null -eq (Get-Finding (Get-RuleFindings @((New-Ev 'Microsoft-Windows-WindowsUpdateClient' 19 4)) $rules) 'wu-failures')) 'update success is ignored'

# Restart events belong to the incident logic, not the rules.
$none = Get-RuleFindings @((New-K41 $t0), (New-E6008 $t0), (New-Ser $t0 '0x1'), (New-Ev 'User32' 1074 4)) $rules
Assert-Equal @($none).Count 0 'restart events are not double-counted by rules'

# --- unmatched events ---------------------------------------------------------
$odd = @((New-Ev 'Contoso' 5 2), (New-Ev 'Contoso' 5 2), (New-Ev 'Contoso' 9 1), (New-Ev 'Contoso' 7 3), (New-Ev 'Contoso' 8 4))
$f = Get-Finding (Get-RuleFindings $odd $rules) 'other-errors'
Assert-Equal $f.Count 3 'only unmatched Error/Critical events are counted as other'
Assert-True ($f.Detail -match 'Contoso 5 x2') 'other detail lists the most frequent kind'

$noise = 1..5 | ForEach-Object { New-Ev 'Microsoft-Windows-DistributedCOM' 10016 3 }
Assert-Equal (Get-Finding (Get-RuleFindings $noise $rules) 'noise-dcom').Severity 'Info' 'DCOM 10016 is info'

# --- ranking ------------------------------------------------------------------
$ranked = Sort-Findings @(
    [pscustomobject]@{ RuleId = 'other-errors'; Severity = 'Low'; Count = 500; Last = $t0 },
    [pscustomobject]@{ RuleId = 'a'; Severity = 'Low'; Count = 2; Last = $t0 },
    [pscustomobject]@{ RuleId = 'b'; Severity = 'Medium'; Count = 1; Last = $t0 },
    [pscustomobject]@{ RuleId = 'c'; Severity = 'Critical'; Count = 1; Last = $t0 },
    [pscustomobject]@{ RuleId = 'd'; Severity = 'Medium'; Count = 9; Last = $t0 })
Assert-Equal (($ranked | ForEach-Object { $_.RuleId }) -join ',') 'c,d,b,a,other-errors' 'severity, then count; catch-all last in its tier'

Assert-Equal (Get-Verdict 'Critical') 'ACTION' 'verdict critical'
Assert-Equal (Get-Verdict 'High') 'ACTION' 'verdict high'
Assert-Equal (Get-Verdict 'Medium') 'REVIEW' 'verdict medium'
Assert-Equal (Get-Verdict 'Low') 'INFO' 'verdict low'

# --- message text -------------------------------------------------------------
$ev = New-Ev 'X' 1 2 'System' $t0 @() $null
Assert-True ((Get-EventText $ev) -match 'no message text') 'missing message falls back to provider and id'
$ev = New-Ev 'X' 1 2 'System' $t0 @() $null
$ev.Raw = [pscustomobject]@{ Message = ('a' * 400) }
Assert-True ((Get-EventText $ev).Length -le 300) 'long messages are truncated'
$ev = New-Ev 'X' 1 2 'System' $t0 @() $null
$ev.Raw = [pscustomobject]@{ Message = "line one`r`n   line two" }
Assert-Equal (Get-EventText $ev) 'line one line two' 'whitespace in messages is collapsed'

# --- masking ------------------------------------------------------------------
$script:MaskOn = $true
$script:MaskUserRx = $null
Assert-Equal (Protect 'C:\Users\jsmith\AppData\x.dll') 'C:\Users\<user>\AppData\x.dll' 'profile path'
Assert-Equal (Protect 'C:\\Users\\jsmith\\x') 'C:\\Users\\<user>\\x' 'profile path in JSON form'
Assert-Equal (Protect 'S-1-5-21-1111111111-2222222222-3333333333-1001') '<SID>' 'SID'
Assert-Equal (Protect 'from 192.168.1.20 now') 'from <ip> now' 'IPv4'
Assert-Equal (Protect 'version 10.0.22631.4317') 'version 10.0.22631.4317' 'build numbers are not IP addresses'
Assert-Equal (Protect 'mac 00-1A-2B-3C-4D-5E ok') 'mac <mac> ok' 'MAC'
Assert-Equal (Protect 'mail bob.smith@example.com.au now') 'mail <email> now' 'email'
if ($env:COMPUTERNAME) {
    Assert-Equal (Protect "host $($env:COMPUTERNAME) ok") 'host <computer> ok' 'computer name'
    Assert-Equal (Protect "$($env:COMPUTERNAME)X") "$($env:COMPUTERNAME)X" 'longer word containing the computer name is left alone'
}
$script:MaskUserRx = '(?i)(?<![\w.-])(alice)(?![\w-])'
Assert-Equal (Protect 'user alice logged on; malice') 'user <user> logged on; malice' 'profile names masked as whole words only'
$script:MaskOn = $false
$script:MaskUserRx = $null
Assert-Equal (Protect 'C:\Users\jsmith\x') 'C:\Users\jsmith\x' 'no masking when off'

# --- HTML ---------------------------------------------------------------------
$report = [pscustomobject]@{
    Computer = 'PC<01>'; Generated = Get-Date; Days = 7; Since = Get-Date
    Context = [ordered]@{ OS = 'Windows 11'; Model = 'Test & Co' }
    Coverage = @([pscustomobject]@{ Log = 'System'; Oldest = Get-Date })
    EventsRead = 1; Boots = 1; Incidents = @(); Planned = @(); Hidden = @(); Dumps = @(); Limits = @(); Notes = @()
    Findings = @([pscustomobject]@{ RuleId = 'x'; Severity = 'High'; Category = 'C'; Title = '<script>alert(1)</script>'
            Count = 2; First = Get-Date; Last = Get-Date; Detail = 'a & b'; Explain = 'e'; Next = 'n'; Sample = '<b>s</b>' })
}
$html = ConvertTo-ReviewHtml $report
Assert-True ($html -notmatch '<script>alert') 'HTML output encodes event-derived text'
Assert-True ($html -match '&lt;script&gt;') 'encoded form is present'
Assert-True ($html -match 'Test &amp; Co') 'ampersand encoded'
$text = Format-ReviewText $report 5
Assert-True ($text -match 'VERDICT: 1 needing action') 'text report states the verdict'

$rows = ConvertTo-FindingRows $report 5
Assert-Equal @($rows).Count 1 'one table row per finding'
Assert-Equal $rows[0].Verdict 'ACTION' 'table row verdict'

# --- result -------------------------------------------------------------------
Write-Host ('{0} passed, {1} failed' -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
