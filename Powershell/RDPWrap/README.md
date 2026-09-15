# RDP Wrapper Monitor & Auto-Repair

Keeps [RDP Wrapper](https://github.com/stascorp/rdpwrap) multi-session RDP working across Windows Updates, with RMM alerting.

## The problem

RDP Wrapper patches `termsrv.dll` in memory using offsets from `rdpwrap.ini`, keyed by the DLL's version. A cumulative update ships a new `termsrv.dll`; if the ini has no `[10.0.xxxxx.yyyy]` section for it, the service still starts but silently drops back to single-session. Nobody notices until a second user is bounced. The community-maintained ini ([sebaxakerhtc/rdpwrap.ini](https://github.com/sebaxakerhtc/rdpwrap.ini)) often lags the update by days, and sometimes the offsets only exist in an unmerged PR.

## What this does

```
Windows Update → reboot
  └─ +2 min: Test-RdpWrapStatus.ps1 -AutoRepair
       ├─ all good → event 1000
       └─ ini has no section for new termsrv.dll → event 1001
            └─ Repair-RdpWrapIni.ps1
                 ├─ upstream ini has it?  → append it
                 ├─ else run rdpwrap-offset-finder.exe → validate → append
                 ├─ backup rdpwrap.ini.<timestamp>.bak
                 └─ event 1003 "patched, TermService restart required"   ← RMM alerts
                      └─ (after hours) Repair-RdpWrapIni.ps1 -RestartService → event 1005
```

The restart is deliberately **not** automatic: restarting TermService drops every active session.

## Files

| File | Purpose |
|---|---|
| `Test-RdpWrapStatus.ps1` | Health check. Verifies ServiceDll → rdpwrap.dll, DLL loaded in TermService, ini has section for installed termsrv.dll version, listener up, no policy blocking. Writes result to Application log. |
| `Repair-RdpWrapIni.ps1` | Adds the missing ini section from upstream or the offset finder. Idempotent. Optional `-RestartService`. |
| `Build-Installer.ps1` | Generates `Install-RdpWrapMonitor.ps1` from the two scripts above. Run after editing either. |
| `Install-RdpWrapMonitor.ps1` | **Generated.** Single-file deploy for RMM upload: writes scripts to `C:\ProgramData\RDPWrapMonitor`, registers the scheduled task, runs it once. |
| `Build-OffsetFinder.ps1` | Builds a standalone `rdpwrap-offset-finder.exe` from [bobotechnology/RDPWrapOffsetFinder](https://github.com/bobotechnology/RDPWrapOffsetFinder) with PyInstaller so the target needs no Python. |

The EXE is not committed (9+ MB binary). Build it with `Build-OffsetFinder.ps1` and copy it to the install folder on each target.

## Event IDs

All in the **Application** log, source **`RDPWrapMonitor`**.

| ID | Level | Meaning |
|---|---|---|
| 1000 | Information | Check passed |
| 1001 | Error | Check failed (message lists failures and, if `-AutoRepair` ran, its output) |
| 1002 | Error | Check script threw an exception |
| 1003 | Error | ini patched — **TermService restart required** |
| 1004 | Error | Auto-repair failed (no offsets available, validation failed, or post-restart check failed) |
| 1005 | Information | ini already current, or restart done and check passed |

Failures are all Error level on purpose: one RMM rule on `source = RDPWrapMonitor, level = Error` catches everything actionable.

## Deploy

1. `.\Build-OffsetFinder.ps1` on any Windows x64 machine with Python 3.9+ and git (produces `dist\rdpwrap-offset-finder.exe`).
2. Upload `Install-RdpWrapMonitor.ps1` to the RMM; run once on the target as SYSTEM. Output should show a `1000 Information` event.
3. File-transfer `rdpwrap-offset-finder.exe` to `C:\ProgramData\RDPWrapMonitor\` on the target.
4. Add an RMM event-log threshold: Application / source `RDPWrapMonitor` / level Error → Critical.
5. Verify the alert path end to end:
   ```powershell
   Write-EventLog -LogName Application -Source RDPWrapMonitor -EntryType Error -EventId 1001 -Message "TEST - verifying RMM threshold"
   ```
6. Verify the offset finder works on the target without touching anything:
   ```powershell
   New-Item C:\ProgramData\RDPWrapMonitor\empty.ini -ItemType File
   C:\ProgramData\RDPWrapMonitor\Repair-RdpWrapIni.ps1 -DryRun -SkipUpstream -IniPath C:\ProgramData\RDPWrapMonitor\empty.ini
   ```
   Expected: `DRY RUN - would append ... (source: rdpwrap-offset-finder)` followed by sections matching the live ini.

### Atera specifics

Threshold Profile → Add → **Custom** → Category *Events By Source*, Source folder *Application*, Windows Event severity *Error*, Source names or event IDs `RDPWrapMonitor`, Alert severity *Critical*. Atera polls the event log, so expect the alert 5–15 min after the event.

## Runbook: 1003 alert fires

The ini is already patched; only the restart is outstanding. Outside business hours:

```powershell
C:\ProgramData\RDPWrapMonitor\Repair-RdpWrapIni.ps1 -RestartService
```

Restarts TermService, waits 10 s, re-runs the health check, logs 1005 on success / 1004 on failure.

## Runbook: 1004 alert fires

Auto-repair couldn't get offsets. The 1001/1004 message names the termsrv.dll version. Options, in order:

1. Check [sebaxakerhtc/rdpwrap.ini](https://github.com/sebaxakerhtc/rdpwrap.ini) **pull requests** — offsets are often there before they're merged. Append manually, restart.
2. Rebuild the offset finder from the latest upstream commit (`Build-OffsetFinder.ps1`) — pattern fixes land there when Microsoft changes the DLL layout.
3. Run the finder with `--nosymbol` by hand and inspect the output; the script already tries this, but a human can judge a partial result.

## Parameters worth knowing

**Test-RdpWrapStatus.ps1**
- `-AutoRepair` — call the repair script on a missing-section failure (what the scheduled task uses).
- `-RequireMultiSessionPerUser` — treat `fSingleSessionPerUser=1` as a failure. Only needed when several people share one account; with individual accounts the Windows default (one session per user) is correct and does not limit multi-user RDP.

**Repair-RdpWrapIni.ps1**
- `-DryRun` — print what would be appended, change nothing.
- `-SkipUpstream` — skip the GitHub fetch, go straight to the offset finder.
- `-RestartService` — restart TermService after patching and re-check.
- `-IniPath`, `-TermsrvPath`, `-OffsetFinderPath`, `-UpstreamIniUrl` — overrides, mainly for testing against a scratch ini.

## Notes

- Version matching uses the numeric fixed-file-info (`FileMajorPart` etc.), not the `FileVersion` string, which on Windows 11 is frequently stale (e.g. string says `.8115`, actual build is `.9444`). RDP Wrapper and the ini use the numeric version.
- The scheduled task waits 2 min after boot, and the check itself waits up to 3 min for TermService to reach Running, so slow boots don't produce false alarms.
- The offset finder validates the *shape* of its output (required keys, `-SLInit` block), not that the offsets are correct. Only the post-restart check proves that — another reason the restart stays manual.
- PyInstaller one-file binaries are sometimes flagged by AV. `build-info.txt` beside the EXE records the SHA256 for whitelisting.
