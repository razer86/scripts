# Event Log Review

Reads a Windows device's event log history and reports what went wrong, ranked, in plain language. Read-only: it never changes the device and writes to disk only when you pass `-OutDir`.

Built for the "something is wrong with this PC, what has it been doing?" check. Run it from ScreenConnect Backstage (as SYSTEM, nobody logged on) or from a prompt.

| File | Purpose |
| ---- | ------- |
| `Invoke-EventLogReview.ps1` | The tool. One self-contained file (rules and bugcheck catalog included) so it can be pasted into Backstage or picked from the sc-console GitHub tab. |
| `EventLogReview.Tests.ps1` | Self-test. Feeds synthetic events through the real functions. No Pester needed. |

## Usage

```powershell
.\Invoke-EventLogReview.ps1                      # last 7 days, text summary
.\Invoke-EventLogReview.ps1 -Days 30             # a month
.\Invoke-EventLogReview.ps1 -Days 14 -OutDir C:\Temp\Review -Mask
.\Invoke-EventLogReview.ps1 -IncludeInfo         # also list known-noisy events
```

| Parameter | Default | Meaning |
| --------- | ------- | ------- |
| `-Days` | 7 | How far back (1-90). Limited by how far the logs actually go; the output says when a log is shorter than asked. |
| `-OutDir` | none | Write an HTML report and a JSON file here. |
| `-Mask` | off | Mask user names, computer name, SIDs, IPs, MACs and e-mail addresses in the output and files. |
| `-Top` | 12 | Findings listed in the text output. HTML/JSON always contain all of them. |
| `-IncludeInfo` | off | List low-value findings (counted but hidden by default). |
| `-PassThru` | off | Also return the report object. |

Runs on Windows PowerShell 5.1 (what ScreenConnect uses) and PowerShell 7.

## What it reports

**Restarts & crashes.** Kernel-Power 41, EventLog 6008 and the bugcheck record are correlated into one incident per restart (a blue screen and its restart are not listed three times):

- **Blue screen** - stop code and name (about 60 codes mapped), with guidance for the class of fault (driver, memory, storage, video, hardware, power, system).
- **Unexpected power loss or hard reset** - restarted with no crash recorded.
- **Forced power-off** - power button held.
- **Unexpected shutdown** - Windows says so, with no further record.

It also notes whether it happened during sleep/resume, roughly when the PC went down (from the 6008 text, only when that parses sensibly), planned restarts, and crash dump files in the window (including `LiveKernelReports`, which a watchdog hang leaves behind without a blue screen).

**Findings**, ranked by severity then count. Each has a plain explanation and a suggested next check:

| Area | Examples |
| ---- | -------- |
| Storage | disk bad blocks, controller errors, paging errors, hardware I/O errors, predicted failure, retries, device resets, NTFS corruption, delayed write failures, chkdsk at boot, shadow copy failures |
| Hardware | WHEA errors, CPU throttled by firmware, low memory, GPU driver resets, kernel watchdog reports, graphics hangs read from live kernel dump headers (works even when Windows Error Reporting is off) |
| Services / apps | service crashes and failures, application crashes (with faulting module), hangs, unhandled .NET exceptions |
| Updates / security | Windows Update failures, Defender detections |
| Other | any Error/Critical event with no rule, counted with a sample, so nothing is silently dropped |

Escalation: repeats raise severity (for example five crashes of one service, or ten corrected WHEA errors). Known-noisy events (DCOM 10016 and similar) are counted but hidden unless `-IncludeInfo`.

Verdict mapping: Critical/High = `ACTION`, Medium = `REVIEW`, Low/Info = `INFO`.

## Running it through ScreenConnect

**sc-console GitHub tab** (preferred): pick `EventLogReview/Invoke-EventLogReview.ps1`, set parameters, run. The console previews the exact commit, runs that commit, and logs it. The findings come back as a table. The script declares a 5 minute timeout with a `# sc-console: timeout=` line.

**Backstage by hand**: the console tab is the tested path (it hands the script to PowerShell as a script block, so `param()` and `-Days 14` work). A raw paste into a `#!ps` command has not been tried; the script runs itself with the defaults (7 days), so parameters cannot be passed that way, and the command needs `#timeout=300000` above it.

As SYSTEM the System and Application logs and `C:\Windows\LiveKernelReports` are all readable, so it sees more than a standard-user run would (for example crash dumps).

## Adding or changing a rule

Rules are hashtables in `Get-ReviewRules`. A rule states what differs from the defaults:

```powershell
@{ Id = 'svc-crashed'; Log = 'System'; Provider = 'Service Control Manager'; EventIds = @(7031, 7034)
   Severity = 'Medium'; Category = 'Services'; EscalateAt = 5; EscalateTo = 'High'
   Title = 'Service terminated unexpectedly'
   Explain = 'What it means.'
   Next = 'What to check next.'
   Key = { param($e) Get-Prop $e 0 } }     # what to count separately: "Spooler x3"
```

- `Provider` is exact; `ProviderRx` is a regex. `EventIds` empty means any ID. `MaxLevel` limits to Critical..N (1 Critical, 2 Error, 3 Warning).
- `LevelSeverity` maps event level to severity (used by WHEA). `Where` is an extra filter.
- A rule that sets `Severity = 'Info'` is treated as noise.
- Event property positions (`Get-Prop $e 0`) follow the Windows event definitions. Check with `(Get-WinEvent ...).Properties` on a real event before relying on an index.
- If the rule needs an event that is not Error/Warning level (an Information event), add its ID to the second query for that log in `Get-ReviewEvents`.

Keep the script ASCII-only (Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI) and avoid PowerShell 7-only syntax. If you use a here-string for large blocks, prefer `@" "@` over `@' '@` when the content allows, because sc-console embeds scripts in a single-quoted here-string and falls back to a larger form when a line starts with `'@`.

Run the self-test after any change:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\EventLogReview.Tests.ps1
pwsh -NoProfile -File .\EventLogReview.Tests.ps1
```

## Limits

- It can only see what the logs still hold. Busy machines can keep days, not weeks; the report says when a log is shorter than requested.
- Explanations are general guidance from well-known event IDs, not a diagnosis. A correlation (for example a watchdog dump a minute before a hard reset) is a lead to follow, not a proof.
- The Security log (logons, audit) is not read.
- One machine per run. Use the console to run it across several.

## Credit

The approach of explaining Event Log entries in plain language, and the Kernel-Power / bugcheck correlation, follow the open-source [Pulse](https://github.com/Regncreative/Pulse) project (MIT). The rules and code here are written independently for PowerShell.
