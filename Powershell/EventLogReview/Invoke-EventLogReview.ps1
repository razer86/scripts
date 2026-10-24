<#
# =========================================
# ===   Invoke-EventLogReview.ps1       ===
# =========================================
.SYNOPSIS
    Reads the Windows event log history on this device and reports what went
    wrong, ranked, in plain language.

.DESCRIPTION
    Read-only. Looks back over the System and Application logs (plus Microsoft
    Defender if present) and produces:

      - Restarts & crashes: blue screens (with the stop code explained),
        power loss / hard resets, forced power-offs and unexpected shutdowns,
        built by correlating Kernel-Power 41, EventLog 6008 and the bugcheck
        record rather than listing them separately.
      - Findings, ranked by severity then frequency: failing disks, storage
        resets, file-system corruption, WHEA hardware errors, GPU driver resets,
        crashing services and applications, Windows Update failures, and more.
        Each one has a short explanation and a suggested next check.
      - Context: OS, last boot, how far back each log actually goes, and any
        crash dump files in the window.

    Event IDs and bugcheck names are mapped to explanations by a built-in rule
    catalog. Anything it has no rule for that logged at Error/Critical level is
    still counted under "Other error events" with a sample message.

    Built to run unattended as SYSTEM (for example from ScreenConnect Backstage),
    but works the same from an elevated or normal prompt. Without elevation the
    System and Application logs are readable; the Security log is not used.

    Output is plain text on the pipeline. When a function named Emit-Json exists
    (the sc-console defines one) the findings are also emitted as a table.

.PARAMETER Days
    How many days back to review (1-90). Default 7. The review can only see as
    far back as the logs go; the output says when a log is shorter than asked.

.PARAMETER OutDir
    Optional folder. When set, an HTML report and a JSON file are written there.
    Nothing is written to disk otherwise.

.PARAMETER Mask
    Mask user names, the computer name, SIDs, IP and MAC addresses and e-mail
    addresses in the output and any files. Use when the report leaves the
    technician's hands. The paths of the report files are printed as they are,
    so they can be found.

.PARAMETER Top
    How many findings to list in the text output (1-100). Default 12. The HTML
    and JSON always contain every finding.

.PARAMETER IncludeInfo
    Also list low-value findings (known-noisy events such as DCOM 10016). They
    are counted but hidden by default.

.PARAMETER PassThru
    Also return the report object, for use from another script.

.EXAMPLE
    .\Invoke-EventLogReview.ps1
    Review the last 7 days and print the findings.

.EXAMPLE
    .\Invoke-EventLogReview.ps1 -Days 30 -OutDir C:\Temp\Review -Mask
    Review a month, write masked HTML + JSON reports to C:\Temp\Review.

.NOTES
    Author  : Raymond Slater
    Source  : https://github.com/razer86/scripts
    Credit  : The idea of explaining Event Log entries in plain language, and the
              Kernel-Power / bugcheck correlation approach, follow the open-source
              Pulse project (https://github.com/Regncreative/Pulse, MIT).
#>
# sc-console: timeout=300000
[CmdletBinding()]
param (
    [ValidateRange(1, 90)]
    [int]$Days = 7,

    [string]$OutDir,

    [switch]$Mask,

    [ValidateRange(1, 100)]
    [int]$Top = 12,

    [switch]$IncludeInfo,

    [switch]$PassThru
)

# =========================================
# ===   Reference data                  ===
# =========================================

$script:SeverityRank = @{ Critical = 5; High = 4; Medium = 3; Low = 2; Info = 1 }

# Stop code -> "NAME|Class". Keys are lower-case hex without leading zeros.
$script:Bugchecks = @{
    '9'        = 'KMODE_EXCEPTION_NOT_HANDLED_LEGACY|Driver'
    'a'        = 'IRQL_NOT_LESS_OR_EQUAL|Driver'
    '18'       = 'REFERENCE_BY_POINTER|Driver'
    '19'       = 'BAD_POOL_HEADER|Memory'
    '1a'       = 'MEMORY_MANAGEMENT|Memory'
    '1e'       = 'KMODE_EXCEPTION_NOT_HANDLED|Driver'
    '24'       = 'NTFS_FILE_SYSTEM|Storage'
    '2e'       = 'DATA_BUS_ERROR|Hardware'
    '3b'       = 'SYSTEM_SERVICE_EXCEPTION|Driver'
    '3f'       = 'NO_MORE_SYSTEM_PTES|Driver'
    '44'       = 'MULTIPLE_IRP_COMPLETE_REQUESTS|Driver'
    '4e'       = 'PFN_LIST_CORRUPT|Memory'
    '50'       = 'PAGE_FAULT_IN_NONPAGED_AREA|Memory'
    '51'       = 'REGISTRY_ERROR|Storage'
    '5c'       = 'HAL_INITIALIZATION_FAILED|Hardware'
    '5d'       = 'UNSUPPORTED_PROCESSOR|Hardware'
    '6b'       = 'PROCESS1_INITIALIZATION_FAILED|System'
    '77'       = 'KERNEL_STACK_INPAGE_ERROR|Storage'
    '7a'       = 'KERNEL_DATA_INPAGE_ERROR|Storage'
    '7b'       = 'INACCESSIBLE_BOOT_DEVICE|Storage'
    '7e'       = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED|Driver'
    '7f'       = 'UNEXPECTED_KERNEL_MODE_TRAP|Hardware'
    '80'       = 'NMI_HARDWARE_FAILURE|Hardware'
    '8e'       = 'KERNEL_MODE_EXCEPTION_NOT_HANDLED|Driver'
    '9a'       = 'SYSTEM_LICENSE_VIOLATION|System'
    '9c'       = 'MACHINE_CHECK_EXCEPTION|Hardware'
    '9f'       = 'DRIVER_POWER_STATE_FAILURE|Power'
    'a0'       = 'INTERNAL_POWER_ERROR|Power'
    'a5'       = 'ACPI_BIOS_ERROR|Hardware'
    'b8'       = 'ATTEMPTED_SWITCH_FROM_DPC|Driver'
    'be'       = 'ATTEMPTED_WRITE_TO_READONLY_MEMORY|Driver'
    'c1'       = 'SPECIAL_POOL_DETECTED_MEMORY_CORRUPTION|Driver'
    'c2'       = 'BAD_POOL_CALLER|Driver'
    'c4'       = 'DRIVER_VERIFIER_DETECTED_VIOLATION|Driver'
    'c5'       = 'DRIVER_CORRUPTED_EXPOOL|Driver'
    'c9'       = 'DRIVER_VERIFIER_IOMANAGER_VIOLATION|Driver'
    'ce'       = 'DRIVER_UNLOADED_WITHOUT_CANCELLING_PENDING_OPERATIONS|Driver'
    'd1'       = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL|Driver'
    'd5'       = 'DRIVER_PAGE_FAULT_IN_FREED_SPECIAL_POOL|Driver'
    'da'       = 'SYSTEM_PTE_MISUSE|Driver'
    'e2'       = 'MANUALLY_INITIATED_CRASH|Manual'
    'ea'       = 'THREAD_STUCK_IN_DEVICE_DRIVER|Video'
    'ed'       = 'UNMOUNTABLE_BOOT_VOLUME|Storage'
    'ef'       = 'CRITICAL_PROCESS_DIED|System'
    'f4'       = 'CRITICAL_OBJECT_TERMINATION|System'
    'f7'       = 'DRIVER_OVERRAN_STACK_BUFFER|Driver'
    'fc'       = 'ATTEMPTED_EXECUTE_OF_NOEXECUTE_MEMORY|Driver'
    'fe'       = 'BUGCODE_USB_DRIVER|Driver'
    '109'      = 'CRITICAL_STRUCTURE_CORRUPTION|System'
    '10e'      = 'VIDEO_MEMORY_MANAGEMENT_INTERNAL|Video'
    '116'      = 'VIDEO_TDR_FAILURE|Video'
    '117'      = 'VIDEO_TDR_TIMEOUT_DETECTED|Video'
    '119'      = 'VIDEO_SCHEDULER_INTERNAL_ERROR|Video'
    '124'      = 'WHEA_UNCORRECTABLE_ERROR|Hardware'
    '133'      = 'DPC_WATCHDOG_VIOLATION|Driver'
    '139'      = 'KERNEL_SECURITY_CHECK_FAILURE|Driver'
    '13a'      = 'KERNEL_MODE_HEAP_CORRUPTION|Memory'
    '141'      = 'VIDEO_ENGINE_TIMEOUT_DETECTED|Video'
    '144'      = 'BUGCODE_USB3_DRIVER|Driver'
    '154'      = 'UNEXPECTED_STORE_EXCEPTION|Storage'
    '1c8'      = 'MANUALLY_INITIATED_POWER_BUTTON_HOLD|Manual'
    'c000021a' = 'STATUS_SYSTEM_PROCESS_TERMINATED|System'
    'c0000221' = 'STATUS_IMAGE_CHECKSUM_MISMATCH|System'
}

$script:BugcheckClass = @{
    Memory   = @{
        Explain = 'Memory was corrupted or a memory access failed. Faulty RAM is the classic cause; drivers and unstable memory settings (XMP/overclock) are next.'
        Next    = 'Run Windows Memory Diagnostic or MemTest86 overnight, test DIMMs one at a time, and drop any XMP/overclock. If memory is clean, look at recently changed drivers.'
    }
    Driver   = @{
        Explain = 'A kernel-mode driver did something illegal. This is almost always a faulty, outdated or incompatible driver rather than bad hardware.'
        Next    = 'Open the minidump (C:\Windows\Minidump) in WinDbg (!analyze -v) or BlueScreenView to name the driver, then update or roll it back. Check what changed just before the first crash.'
    }
    Storage  = @{
        Explain = 'A disk, controller or file-system problem stopped Windows. The drive itself, its cable/connection or the storage driver are the usual causes.'
        Next    = 'Check SMART/NVMe health, look at the storage findings in this report, run chkdsk /scan, and update storage/chipset drivers and firmware.'
    }
    Video    = @{
        Explain = 'The graphics driver or GPU hung or failed to recover. Driver bugs, overheating and failing graphics hardware all show up like this.'
        Next    = 'Clean-install the latest GPU driver, check GPU temperatures and power, and test with an older driver if it started after an update.'
    }
    Hardware = @{
        Explain = 'The CPU, memory, motherboard or firmware reported a hardware-level fault.'
        Next    = 'Check the WHEA findings, temperatures and fans, update BIOS/firmware, remove any overclock, and test RAM and the PSU.'
    }
    Power    = @{
        Explain = 'A device did not finish a power transition (sleep, hibernate, shutdown or resume) in time, so Windows gave up and crashed.'
        Next    = 'Update chipset, storage, network and GPU drivers and the BIOS. Try disabling Fast Startup; see which device is named in the dump.'
    }
    System   = @{
        Explain = 'A core Windows component failed, was terminated or was corrupted.'
        Next    = 'Run sfc /scannow then DISM /Online /Cleanup-Image /RestoreHealth. Check what updates or software were installed just before. Check disk health.'
    }
    Manual   = @{
        Explain = 'The crash was triggered on purpose (keyboard, NMI or power-button hold). It is not a fault in itself.'
        Next    = 'Find out who triggered it and why; the PC was probably frozen first, so look for what hung.'
    }
    Unknown  = @{
        Explain = 'No built-in explanation for this stop code.'
        Next    = 'Collect the dump (C:\Windows\Minidump or C:\Windows\MEMORY.DMP) and analyse it with WinDbg (!analyze -v), or search the stop code.'
    }
}

# =========================================
# ===   Small helpers                   ===
# =========================================

function Get-Prop {
    # String form of an event property, or '' when absent.
    param($Event, [int]$Index)
    if ($Event.Props -and $Event.Props.Count -gt $Index -and $null -ne $Event.Props[$Index]) {
        return [string]$Event.Props[$Index]
    }
    return ''
}

function ConvertTo-UInt32Safe {
    # Event data arrives as UInt32, Int32, or text depending on the build.
    param($Value)
    if ($null -eq $Value) { return [uint32]0 }
    try {
        if ($Value -is [uint32]) { return $Value }
        if ($Value -is [int]) { return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$Value), 0) }
        $s = ([string]$Value).Trim()
        if ($s -match '^0x([0-9a-fA-F]+)$') { return [Convert]::ToUInt32($Matches[1], 16) }
        if ($s -match '^\d+$') { return [Convert]::ToUInt32($s) }
    } catch { }
    return [uint32]0
}

function Format-Time {
    param($Date)
    if ($null -eq $Date) { return '' }
    return ([datetime]$Date).ToString('yyyy-MM-dd HH:mm')
}

function Get-EventText {
    # Formatting a message costs a provider lookup, so only done for samples.
    param($Event)
    if ($Event.Msg) { return $Event.Msg }
    $m = $null
    if ($Event.Raw) { try { $m = $Event.Raw.Message } catch { $m = $null } }
    if (-not $m) { $m = '{0} event {1} (no message text available)' -f $Event.Provider, $Event.Id }
    $m = ($m -replace '\s+', ' ').Trim()
    if ($m.Length -gt 300) { $m = $m.Substring(0, 297) + '...' }
    $Event.Msg = $m
    return $m
}

function Get-BugcheckInfo {
    # Takes any numeric form: PowerShell reads 0xC000021A as a negative Int32.
    param($Code)
    $key = '{0:x}' -f (ConvertTo-UInt32Safe $Code)
    $entry = $script:Bugchecks[$key]
    if ($entry) {
        $parts = $entry -split '\|'
        return @{ Name = $parts[0]; Class = $parts[1] }
    }
    return @{ Name = 'UNKNOWN_STOP_CODE'; Class = 'Unknown' }
}

function Get-MaxSeverity {
    param([string]$A, [string]$B)
    if ($script:SeverityRank[$A] -ge $script:SeverityRank[$B]) { return $A }
    return $B
}

function Get-Verdict {
    param([string]$Severity)
    switch ($Severity) {
        'Critical' { return 'ACTION' }
        'High'     { return 'ACTION' }
        'Medium'   { return 'REVIEW' }
        default    { return 'INFO' }
    }
}

# --- masking -----------------------------------------------------------------
$script:MaskOn = $false
$script:MaskUserRx = $null

function Initialize-Mask {
    $names = @()
    try {
        $skip = 'public', 'default', 'default user', 'all users', 'defaultuser0', 'wdagutilityaccount'
        $names += @(Get-ChildItem -Path (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue |
                Where-Object { $skip -notcontains $_.Name.ToLower() -and $_.Name.Length -ge 3 } |
                ForEach-Object { $_.Name })
    } catch { }
    $script:MaskUserRx = $null
    if ($names.Count -gt 0) {
        $script:MaskUserRx = '(?i)(?<![\w.-])(' + (($names | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?![\w-])'
    }
}

function Protect {
    param([string]$Text)
    if (-not $script:MaskOn -or [string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $Text
    $t = [regex]::Replace($t, '(?i)([A-Z]:\\{1,2}Users\\{1,2})[^\\\s"''<>|]+', '$1<user>')
    $t = [regex]::Replace($t, 'S-1-5-21-\d+-\d+-\d+-\d+', '<SID>')
    $t = [regex]::Replace($t, '[\w.+-]+@[\w-]+(\.[\w-]+)+', '<email>')
    $t = [regex]::Replace($t, '\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b', '<mac>')
    $t = [regex]::Replace($t, '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b', '<ip>')
    if ($env:COMPUTERNAME) {
        $t = [regex]::Replace($t, '(?i)(?<![\w-])' + [regex]::Escape($env:COMPUTERNAME) + '(?![\w-])', '<computer>')
    }
    if ($env:USERDOMAIN -and $env:USERDOMAIN -ne $env:COMPUTERNAME) {
        $t = [regex]::Replace($t, '(?i)(?<![\w-])' + [regex]::Escape($env:USERDOMAIN) + '(?=\\)', '<domain>')
    }
    if ($script:MaskUserRx) { $t = [regex]::Replace($t, $script:MaskUserRx, '<user>') }
    return $t
}

# =========================================
# ===   Rule catalog                    ===
# =========================================
# Fields: Id, Log, Provider | ProviderRx, EventIds, MaxLevel, Where, Severity |
# LevelSeverity, Category, Title, Explain, Next, Key (what to count separately,
# shown as "name x3"), EscalateAt/EscalateTo (raise severity when one key - or
# the total, with no Key - reaches this many).

function Get-ReviewRules {
    $disk = 'Check SMART / NVMe health (CrystalDiskInfo or smartctl), make sure important data is backed up, and plan to replace the drive if the errors continue.'
    $rules = @(
        # ---- storage ----
        @{ Id = 'disk-bad-block'; Log = 'System'; Provider = 'disk'; EventIds = @(7); Severity = 'High'; Category = 'Storage'
           Title = 'Disk reported bad blocks'
           Explain = 'Windows hit unreadable sectors on a disk. This usually means the drive is failing.'
           Next = $disk; Key = { param($e) Get-Prop $e 0 } },
        @{ Id = 'disk-controller'; Log = 'System'; Provider = 'disk'; EventIds = @(11); Severity = 'High'; Category = 'Storage'
           Title = 'Disk controller errors'
           Explain = 'The storage driver reported a controller error talking to a disk. Causes: a failing drive, a loose or bad cable/connector, or a controller/driver problem.'
           Next = "$disk Also reseat or replace the cable and update storage and chipset drivers."; Key = { param($e) Get-Prop $e 0 } },
        @{ Id = 'disk-paging'; Log = 'System'; Provider = 'disk'; EventIds = @(51); Severity = 'High'; Category = 'Storage'
           Title = 'Disk error during paging'
           Explain = 'A disk error happened while Windows was reading or writing virtual memory. Often an early sign of a failing drive or a bad connection.'
           Next = $disk; Key = { param($e) Get-Prop $e 0 } },
        @{ Id = 'disk-predicted-failure'; Log = 'System'; Provider = 'disk'; EventIds = @(52); Severity = 'Critical'; Category = 'Storage'
           Title = 'Disk predicts it will fail'
           Explain = 'The drive reported through SMART that it expects to fail soon.'
           Next = 'Back up now and replace the drive. Do not wait for the next error.'; Key = { param($e) Get-Prop $e 0 } },
        @{ Id = 'disk-retries'; Log = 'System'; Provider = 'disk'; EventIds = @(153); Severity = 'Medium'; Category = 'Storage'
           EscalateAt = 20; EscalateTo = 'High'
           Title = 'Disk I/O had to be retried'
           Explain = 'Windows retried disk operations that failed the first time. An occasional retry is normal; a steady stream points to a failing disk, bad cable or controller problem.'
           Next = $disk },
        @{ Id = 'storage-reset'; Log = 'System'; ProviderRx = '(?i)^(stor|nvme|iaStor|amd_|lsi|megasas|percsas|arcsas|SCSI|ahcipo)'; EventIds = @(129); Severity = 'Medium'; Category = 'Storage'
           EscalateAt = 10; EscalateTo = 'High'
           Title = 'Storage device was reset'
           Explain = 'Windows had to reset a storage device because it stopped responding. Repeated resets are a classic sign of a failing drive, a bad cable, or a power-management/driver problem.'
           Next = "$disk Also update storage firmware/drivers, and try disabling link power management." },
        @{ Id = 'disk-removed'; Log = 'System'; Provider = 'disk'; EventIds = @(157); Severity = 'Medium'; Category = 'Storage'
           Title = 'Disk was surprise-removed'
           Explain = 'A disk disappeared without being ejected. Normal when a USB drive is unplugged; on an internal drive it means a connection or power fault.'
           Next = 'If this was not a USB drive being unplugged, check the drive connection and power, and the drive itself.' },
        @{ Id = 'ntfs-corruption'; Log = 'System'; ProviderRx = '^(Microsoft-Windows-)?Ntfs$'; EventIds = @(55); Severity = 'High'; Category = 'Storage'
           Title = 'File system corruption detected'
           Explain = 'NTFS found its on-disk structures damaged. Causes: unclean shutdowns, a failing disk, or bad memory.'
           Next = 'Run chkdsk /scan (and /f at next boot if needed), check disk health, and look at the unexpected shutdowns in this report.' },
        @{ Id = 'ntfs-delayed-write'; Log = 'System'; ProviderRx = '^(Microsoft-Windows-)?Ntfs$'; EventIds = @(50); Severity = 'Medium'; Category = 'Storage'
           Title = 'Delayed write failed'
           Explain = 'Windows could not save some cached data to disk. Seen with removable or network drives that went away, or with a failing disk.'
           Next = 'Check which volume is affected in the sample message and check that drive.' },
        @{ Id = 'chkdsk-ran'; Log = 'Application'; ProviderRx = '^(Wininit|Chkdsk)$'; EventIds = @(1001, 26212); Severity = 'Medium'; Category = 'Storage'
           Title = 'A disk check ran at startup'
           Explain = 'Windows only runs chkdsk at boot when it believes the file system was not shut down cleanly or found errors.'
           Next = 'Check for unexpected shutdowns in this report and run chkdsk /scan to confirm the volume is healthy.' },
        @{ Id = 'shadow-copy'; Log = 'System'; Provider = 'volsnap'; EventIds = @(36); Severity = 'Medium'; Category = 'Storage'
           Title = 'Shadow copies were aborted'
           Explain = 'The volume shadow copy storage could not grow, so restore points / previous versions / backups that rely on it may be incomplete.'
           Next = 'Check free space on the volume and the shadow storage limit (vssadmin list shadowstorage), and that the backup job completed.' },

        # ---- hardware ----
        @{ Id = 'whea'; Log = 'System'; Provider = 'Microsoft-Windows-WHEA-Logger'; Category = 'Hardware'
           Severity = 'Medium'; LevelSeverity = @{ 1 = 'Critical'; 2 = 'Critical'; 3 = 'Medium'; 4 = 'Low' }
           EscalateAt = 10; EscalateTo = 'High'
           Title = 'Hardware error reports (WHEA)'
           Explain = 'The CPU, memory or a PCIe device reported a hardware error to Windows. Corrected errors are survivable, but repeated ones suggest failing hardware, overheating or an unstable overclock; fatal ones crash the PC.'
           Next = 'Check temperatures and fans, update BIOS/firmware and chipset drivers, remove any overclock/XMP, and test RAM and add-in cards.' },
        @{ Id = 'cpu-throttled'; Log = 'System'; Provider = 'Microsoft-Windows-Kernel-Processor-Power'; EventIds = @(37); Severity = 'Medium'; Category = 'Hardware'
           Title = 'CPU speed limited by firmware'
           Explain = 'Firmware is capping processor speed, usually because of heat, power limits (undersized charger or dock) or a failing fan.'
           Next = 'Check temperatures, fans and dust, the charger/dock wattage, and for a BIOS update.' },
        @{ Id = 'low-memory'; Log = 'System'; Provider = 'Microsoft-Windows-Resource-Exhaustion-Detector'; EventIds = @(2004); Severity = 'Medium'; Category = 'Hardware'
           Title = 'Windows ran low on memory'
           Explain = 'The PC ran short of memory (including the page file). The sample message names the biggest consumers.'
           Next = 'Review the processes named, fix any leaking application, or add RAM.' },
        @{ Id = 'gpu-reset'; Log = 'System'; Provider = 'Display'; EventIds = @(4101); Severity = 'Medium'; Category = 'Hardware'
           EscalateAt = 5; EscalateTo = 'High'
           Title = 'Graphics driver stopped responding and recovered'
           Explain = 'Windows had to reset the graphics driver (a TDR). Repeats point to a driver problem, an overheating GPU or failing graphics hardware.'
           Next = 'Clean-install the latest GPU driver, check GPU temperature and power, and test with an older driver if it began after an update.'
           Key = { param($e) Get-Prop $e 0 } },
        @{ Id = 'kernel-watchdog'; Log = 'Application'; Provider = 'Windows Error Reporting'; EventIds = @(1001); Severity = 'Medium'; Category = 'Hardware'
           Where = { param($e) (Get-Prop $e 0) -eq 'LiveKernelEvent' }
           Title = 'Kernel watchdog report (hang without a crash)'
           Explain = 'Windows caught a driver or device hanging and recovered without a blue screen (GPU, USB and storage drivers are the usual ones).'
           Next = 'Update the driver/firmware for the device named in the sample. Reports are kept in C:\Windows\LiveKernelReports.' },

        # ---- services & applications ----
        @{ Id = 'svc-crashed'; Log = 'System'; Provider = 'Service Control Manager'; EventIds = @(7031, 7034); Severity = 'Medium'; Category = 'Services'
           EscalateAt = 5; EscalateTo = 'High'
           Title = 'Service terminated unexpectedly'
           Explain = 'A Windows service crashed. Windows may have restarted it automatically.'
           Next = 'Look for a matching Application Error for the same service, then update or repair the product that owns it.'
           Key = { param($e) Get-Prop $e 0 } },
        @{ Id = 'svc-failed'; Log = 'System'; Provider = 'Service Control Manager'; EventIds = @(7000, 7001, 7023, 7024); Severity = 'Medium'; Category = 'Services'
           Title = 'Service failed to start or exited with an error'
           Explain = 'A service could not start or stopped with an error: a missing dependency, wrong credentials, or a damaged install are typical.'
           Next = 'Open the service in services.msc, check its dependencies and log-on account, and repair or reinstall the owning product.'
           Key = { param($e) Get-Prop $e 0 } },
        @{ Id = 'svc-timeout'; Log = 'System'; Provider = 'Service Control Manager'; EventIds = @(7009, 7011); Severity = 'Low'; Category = 'Services'
           EscalateAt = 10; EscalateTo = 'Medium'
           Title = 'Service timed out'
           Explain = 'A service did not respond in time, usually during startup on a busy or slow disk.'
           Next = 'Look at startup load and disk health, and at the service named.'
           Key = { param($e) Get-Prop $e 1 } },
        @{ Id = 'app-crash'; Log = 'Application'; Provider = 'Application Error'; EventIds = @(1000); Severity = 'Medium'; Category = 'Applications'
           EscalateAt = 5; EscalateTo = 'High'
           Title = 'Application crashed'
           Explain = 'A program stopped working and Windows closed it. The faulting module (in brackets) is the component that failed: a Windows or driver DLL points at the system, a product DLL points at that product.'
           Next = 'Update or repair the application. If many apps fail in the same Windows module (ntdll.dll, KERNELBASE.dll), suspect memory, drivers or system file corruption: sfc /scannow and a memory test.'
           Key = { param($e) '{0} [{1}]' -f (Get-Prop $e 0), (Get-Prop $e 3) } },
        @{ Id = 'app-hang'; Log = 'Application'; Provider = 'Application Hang'; EventIds = @(1002); Severity = 'Low'; Category = 'Applications'
           EscalateAt = 5; EscalateTo = 'Medium'
           Title = 'Application stopped responding'
           Explain = 'A program froze and had to be closed.'
           Next = 'Check whether it is always the same application or a slow disk/network share behind several.'
           Key = { param($e) Get-Prop $e 0 } },
        @{ Id = 'dotnet-crash'; Log = 'Application'; Provider = '.NET Runtime'; EventIds = @(1026); Severity = 'Medium'; Category = 'Applications'
           Title = 'Unhandled .NET exception'
           Explain = 'A .NET application crashed with an exception it did not handle.'
           Next = 'The sample message names the application and exception. Update or repair that application.'
           Key = { param($e) $t = (Get-Prop $e 0) -split "`r?`n"; if ($t.Count -gt 0) { $t[0] } else { '' } } },
        @{ Id = 'wu-failures'; Log = 'System'; Provider = 'Microsoft-Windows-WindowsUpdateClient'; MaxLevel = 2; Severity = 'Medium'; Category = 'Updates'
           Title = 'Windows Update failures'
           Explain = 'Windows Update failed to check for, download or install an update.'
           Next = 'The sample message has the error code. Free some disk space, run DISM /Online /Cleanup-Image /RestoreHealth, and retry; see whether the same update fails repeatedly.'
           Key = { param($e) 'event {0}' -f $e.Id } },
        @{ Id = 'defender-threat'; Log = 'Microsoft-Windows-Windows Defender/Operational'; EventIds = @(1116, 1119); Severity = 'High'; Category = 'Security'
           Title = 'Microsoft Defender detected malware'
           Explain = 'Defender found a threat (1116) or could not remove/quarantine one (1119).'
           Next = 'Open Windows Security > Protection history for the threat name and the action taken, then run a full scan.' },

        # ---- known noise: counted, hidden unless -IncludeInfo ----
        @{ Id = 'noise-dcom'; Log = 'System'; Provider = 'Microsoft-Windows-DistributedCOM'; EventIds = @(10016); Severity = 'Info'; Category = 'Noise'
           Title = 'DCOM permission warnings (normally harmless)'
           Explain = 'A component asked for DCOM activation permission it does not have. Very common on healthy Windows installs.'
           Next = 'Ignore unless a specific feature is broken.' },
        @{ Id = 'noise-restartmgr'; Log = 'Application'; Provider = 'Microsoft-Windows-RestartManager'; EventIds = @(10010); Severity = 'Info'; Category = 'Noise'
           Title = 'Restart Manager: application could not be restarted'
           Explain = 'Logged when an installer could not restart a program it closed. Not a fault.'
           Next = 'Ignore.' }
    )
    # Defaults, so a rule only states what differs.
    foreach ($r in $rules) {
        if (-not $r.ContainsKey('Severity')) { $r.Severity = 'Medium' }
        if (-not $r.ContainsKey('EventIds')) { $r.EventIds = @() }
    }
    return $rules
}

function Test-RuleMatch {
    param($Rule, $Event)
    if ($Rule.Log -and $Event.Log -ne $Rule.Log) { return $false }
    if ($Rule.Provider -and $Event.Provider -ne $Rule.Provider) { return $false }
    if ($Rule.ProviderRx -and $Event.Provider -notmatch $Rule.ProviderRx) { return $false }
    if ($Rule.EventIds.Count -gt 0 -and $Rule.EventIds -notcontains $Event.Id) { return $false }
    if ($Rule.MaxLevel) {
        $lvl = $Event.Level
        if ($lvl -lt 1 -or $lvl -gt $Rule.MaxLevel) { return $false }
    }
    if ($Rule.Where -and -not (& $Rule.Where $Event)) { return $false }
    return $true
}

# =========================================
# ===   Collection                      ===
# =========================================

$script:Notes = New-Object System.Collections.ArrayList

function ConvertTo-ReviewEvent {
    param($Raw)
    $props = @()
    try { $props = @($Raw.Properties | ForEach-Object { $_.Value }) } catch { $props = @() }
    $level = 0
    if ($null -ne $Raw.Level) { $level = [int]$Raw.Level }
    [pscustomobject]@{
        Time     = $Raw.TimeCreated
        Provider = [string]$Raw.ProviderName
        Id       = [int]$Raw.Id
        Level    = $level
        Log      = [string]$Raw.LogName
        RecordId = $Raw.RecordId
        Props    = $props
        Raw      = $Raw
        Msg      = $null
    }
}

function Get-LogEvents {
    param([string]$LogName, [datetime]$Since, [hashtable]$Extra, [int]$Max = 40000)
    $filter = @{ LogName = $LogName; StartTime = $Since }
    foreach ($k in $Extra.Keys) { $filter[$k] = $Extra[$k] }
    try {
        $found = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $Max -ErrorAction Stop)
        if ($found.Count -ge $Max) {
            [void]$script:Notes.Add("$LogName query hit the $Max event cap; the oldest matching events were not read.")
        }
        return $found
    } catch {
        $id = [string]$_.FullyQualifiedErrorId
        if ($id -like 'NoMatchingEventsFound*') { return @() }
        if ($_.Exception.Message -match 'not an event log|no event log|channel') {
            return @()   # e.g. Defender's log on a machine without it
        }
        [void]$script:Notes.Add("Could not read $LogName : $($_.Exception.Message)")
        return @()
    }
}

function Get-ReviewEvents {
    param([datetime]$Since)
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    $queries = @(
        @{ Log = 'System';      Extra = @{ Level = 1, 2, 3 } },
        @{ Log = 'System';      Extra = @{ Id = 41, 1001, 1074, 6005, 6008 } },
        @{ Log = 'Application'; Extra = @{ Level = 1, 2, 3 } },
        @{ Log = 'Application'; Extra = @{ Id = 1001, 26212 } },
        @{ Log = 'Microsoft-Windows-Windows Defender/Operational'; Extra = @{ Id = 1116, 1119 } }
    )
    foreach ($q in $queries) {
        foreach ($raw in (Get-LogEvents -LogName $q.Log -Since $Since -Extra $q.Extra)) {
            $key = '{0}|{1}' -f $raw.LogName, $raw.RecordId
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$out.Add((ConvertTo-ReviewEvent $raw))
        }
    }
    return , @($out)
}

function Get-LogCoverage {
    # How far back each log really goes. A busy log can be shorter than asked.
    $cov = @()
    foreach ($log in 'System', 'Application') {
        $oldest = $null
        try { $oldest = (Get-WinEvent -LogName $log -Oldest -MaxEvents 1 -ErrorAction Stop).TimeCreated } catch { }
        $cov += [pscustomobject]@{ Log = $log; Oldest = $oldest }
    }
    return $cov
}

# =========================================
# ===   Restarts & crashes              ===
# =========================================

function ConvertFrom-ShutdownTime {
    # EventLog 6008 carries the time the PC went down as two locale-formatted
    # strings. Accepted only if it lands shortly before the event: a wrong
    # locale guess must not produce a confident wrong time.
    param($Event)
    $time = ((Get-Prop $Event 0) -replace '[\u200e\u200f]', '').Trim()
    $date = ((Get-Prop $Event 1) -replace '[\u200e\u200f]', '').Trim()
    if (-not $time -or -not $date) { return $null }
    $text = "$date $time"
    foreach ($culture in @([System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.CultureInfo]::GetCultureInfo('en-US'), [System.Globalization.CultureInfo]::InvariantCulture)) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($text, $culture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $gap = ($Event.Time - $parsed).TotalHours
            if ($gap -ge -0.1 -and $gap -le 72) { return $parsed }
        }
    }
    return $null
}

function Get-RestartIncidents {
    param([object[]]$Events)
    $watch = @($Events | Where-Object {
            ($_.Provider -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41) -or
            ($_.Provider -eq 'EventLog' -and $_.Id -eq 6008) -or
            ($_.Provider -eq 'Microsoft-Windows-WER-SystemErrorReporting' -and $_.Id -eq 1001)
        } | Sort-Object Time)

    $clusters = New-Object System.Collections.ArrayList
    $current = $null
    $last = $null
    foreach ($e in $watch) {
        if ($null -eq $current -or ($e.Time - $last).TotalMinutes -gt 20) {
            $current = New-Object System.Collections.ArrayList
            [void]$clusters.Add($current)
        }
        [void]$current.Add($e)
        $last = $e.Time
    }

    $incidents = @()
    foreach ($cluster in $clusters) {
        $events = @($cluster)
        $k41 = $events | Where-Object { $_.Provider -eq 'Microsoft-Windows-Kernel-Power' } | Select-Object -First 1
        $e6008 = $events | Where-Object { $_.Provider -eq 'EventLog' } | Select-Object -First 1
        $ser = $events | Where-Object { $_.Provider -eq 'Microsoft-Windows-WER-SystemErrorReporting' } | Select-Object -First 1

        $code = [uint32]0
        $params = ''
        if ($k41) {
            $code = ConvertTo-UInt32Safe $k41.Props[0]
            if ($code -ne 0) {
                $params = ((1..4 | ForEach-Object { '0x{0:x}' -f (ConvertTo-UInt32Safe (Get-Prop $k41 $_)) }) -join ', ')
            }
        }
        if ($code -eq 0 -and $ser) {
            $m = [regex]::Match((Get-Prop $ser 0), '0x([0-9a-fA-F]+)')
            if ($m.Success) {
                $code = [Convert]::ToUInt32($m.Groups[1].Value, 16)
                $p = [regex]::Matches((Get-Prop $ser 0), '\(([^)]*)\)')
                if ($p.Count -gt 0) { $params = $p[0].Groups[1].Value }
            }
        }

        $duringSleep = $false
        $powerButton = $false
        if ($k41) {
            $duringSleep = ((ConvertTo-UInt32Safe (Get-Prop $k41 5)) -ne 0)
            $pb = 0
            try { $pb = [uint64](Get-Prop $k41 6) } catch { $pb = 0 }
            $powerButton = ($pb -ne 0)
        }

        $info = $null
        if ($code -ne 0) {
            $info = Get-BugcheckInfo $code
            $kind = 'BlueScreen'
            $sev = 'Critical'
            if ($info.Class -eq 'Manual') { $sev = 'Medium' }
            $title = 'Blue screen: {0} (0x{1:X})' -f $info.Name, $code
        } elseif ($k41 -and $powerButton) {
            $kind = 'ForcedPowerOff'; $sev = 'High'
            $title = 'Forced power-off (power button held)'
        } elseif ($k41) {
            $kind = 'PowerLoss'; $sev = 'High'
            $title = 'Unexpected power loss or hard reset'
        } else {
            $kind = 'UnexpectedShutdown'; $sev = 'Medium'
            $title = 'Unexpected shutdown (no crash or power record)'
        }

        $downAt = $null
        if ($e6008) { $downAt = ConvertFrom-ShutdownTime $e6008 }

        $incidents += [pscustomobject]@{
            Time        = ($events | Sort-Object Time | Select-Object -First 1).Time
            Kind        = $kind
            Severity    = $sev
            Title       = $title
            StopCode    = if ($code -ne 0) { '0x{0:X}' -f $code } else { '' }
            StopName    = if ($info) { $info.Name } else { '' }
            Class       = if ($info) { $info.Class } else { '' }
            Parameters  = $params
            DuringSleep = $duringSleep
            WentDownAt  = $downAt
        }
    }
    return , @($incidents | Sort-Object Time -Descending)
}

function Get-PlannedRestarts {
    param([object[]]$Events)
    $out = @()
    foreach ($e in @($Events | Where-Object { $_.Provider -eq 'User32' -and $_.Id -eq 1074 } | Sort-Object Time -Descending)) {
        $process = Get-Prop $e 0
        if ($process -match '\\([^\\]+?)(\.exe)?\s*(\(|$)') { $process = $Matches[1] }
        $out += [pscustomobject]@{
            Time    = $e.Time
            Action  = (Get-Prop $e 4)
            Reason  = (Get-Prop $e 2)
            Process = $process
            User    = (Get-Prop $e 6)
        }
    }
    return , $out
}

function ConvertTo-IncidentFindings {
    param([object[]]$Incidents)
    $findings = @()
    $explain = @{
        PowerLoss          = 'Windows restarted without shutting down and no crash was recorded: the power was cut, the PC was reset, or it froze hard.'
        ForcedPowerOff     = 'The power button was held to force the PC off, usually because it had frozen.'
        UnexpectedShutdown = 'Windows recorded that the previous shutdown was unexpected, but there is no crash or power-loss record to say why.'
    }
    $next = @{
        PowerLoss          = 'Rule out power (PSU, power strip/UPS, battery), overheating (temperatures, dust) and unstable overclocks. Check the hardware and GPU findings, and whether the PC froze beforehand.'
        ForcedPowerOff     = 'Work out what froze: look for GPU resets, disk errors and hangs in this report. If it repeats, treat it like a crash.'
        UnexpectedShutdown = 'Treat it like a power loss: check power, heat and hardware findings.'
    }
    foreach ($group in @($Incidents | Group-Object Title)) {
        $items = @($group.Group | Sort-Object Time)
        $first = $items[0]
        $sev = $first.Severity
        if ($items.Count -ge 3 -and $sev -eq 'Medium') { $sev = 'High' }
        if ($first.Kind -eq 'BlueScreen') {
            $cls = $script:BugcheckClass[$first.Class]
            if (-not $cls) { $cls = $script:BugcheckClass['Unknown'] }
            $why = $cls.Explain; $nxt = $cls.Next
            if ($first.Parameters) { $why = "$why Stop code parameters: $($first.Parameters)." }
        } else {
            $why = $explain[$first.Kind]; $nxt = $next[$first.Kind]
        }
        if (@($items | Where-Object { $_.DuringSleep }).Count -gt 0) {
            $why = "$why At least one happened while entering or leaving sleep."
        }
        $findings += [pscustomobject]@{
            RuleId   = 'restart-' + $first.Kind.ToLower()
            Severity = $sev
            Category = 'Stability'
            Title    = $first.Title
            Count    = $items.Count
            First    = $items[0].Time
            Last     = $items[-1].Time
            Detail   = ''
            Explain  = $why
            Next     = $nxt
            Sample   = ''
        }
    }
    return , $findings
}

# =========================================
# ===   Rule evaluation                 ===
# =========================================

function Get-RuleFindings {
    param([object[]]$Events, [object[]]$Rules)

    $buckets = @{}
    foreach ($r in $Rules) { $buckets[$r.Id] = New-Object System.Collections.ArrayList }
    $otherCounts = @{}
    $otherEvents = @{}

    foreach ($e in $Events) {
        # The restart cluster owns these; counting them again here would triple-report.
        if (($e.Provider -eq 'Microsoft-Windows-Kernel-Power' -and $e.Id -eq 41) -or
            ($e.Provider -eq 'EventLog' -and $e.Id -in 6005, 6008) -or
            ($e.Provider -eq 'Microsoft-Windows-WER-SystemErrorReporting') -or
            ($e.Provider -eq 'User32' -and $e.Id -eq 1074)) { continue }

        $matched = $false
        foreach ($r in $Rules) {
            if (Test-RuleMatch $r $e) {
                [void]$buckets[$r.Id].Add($e)
                $matched = $true
                break
            }
        }
        if (-not $matched -and $e.Level -ge 1 -and $e.Level -le 2) {
            $k = '{0} {1}' -f $e.Provider, $e.Id
            if ($otherCounts.ContainsKey($k)) { $otherCounts[$k]++ } else { $otherCounts[$k] = 1 }
            $otherEvents[$k] = $e
        }
    }

    $findings = @()
    foreach ($r in $Rules) {
        $hits = @($buckets[$r.Id])
        if ($hits.Count -eq 0) { continue }
        $hits = @($hits | Sort-Object Time)

        $sev = $r.Severity
        if ($r.LevelSeverity) {
            $sev = 'Info'
            foreach ($h in $hits) {
                $s = $r.LevelSeverity[[int]$h.Level]
                if (-not $s) { $s = $r.Severity }
                $sev = Get-MaxSeverity $sev $s
            }
        }

        $detail = ''
        $maxKey = $hits.Count
        if ($r.Key) {
            $counts = @{}
            foreach ($h in $hits) {
                $k = [string](& $r.Key $h)
                if (-not $k) { continue }
                if ($counts.ContainsKey($k)) { $counts[$k]++ } else { $counts[$k] = 1 }
            }
            if ($counts.Count -gt 0) {
                $ordered = @($counts.GetEnumerator() | Sort-Object @{ Expression = 'Value'; Descending = $true }, Name)
                $maxKey = $ordered[0].Value
                $shown = @($ordered | Select-Object -First 4 | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Value })
                $detail = $shown -join '; '
                if ($ordered.Count -gt 4) { $detail += '; +{0} more' -f ($ordered.Count - 4) }
            }
        }
        if ($r.EscalateAt -and $maxKey -ge $r.EscalateAt) {
            $sev = Get-MaxSeverity $sev $r.EscalateTo
        }

        $findings += [pscustomobject]@{
            RuleId    = $r.Id
            Severity  = $sev
            Category  = $r.Category
            Title     = $r.Title
            Count     = $hits.Count
            First     = $hits[0].Time
            Last      = $hits[-1].Time
            Detail    = $detail
            Explain   = $r.Explain
            Next      = $r.Next
            Sample    = ''
            LastEvent = $hits[-1]
        }
    }

    if ($otherCounts.Count -gt 0) {
        $ordered = @($otherCounts.GetEnumerator() | Sort-Object @{ Expression = 'Value'; Descending = $true }, Name)
        $total = ($ordered | Measure-Object -Property Value -Sum).Sum
        $shown = @($ordered | Select-Object -First 4 | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Value })
        $detail = $shown -join '; '
        if ($ordered.Count -gt 4) { $detail += '; +{0} more kinds' -f ($ordered.Count - 4) }
        $lastEvent = $otherEvents[$ordered[0].Name]
        $findings += [pscustomobject]@{
            RuleId    = 'other-errors'
            Severity  = 'Low'
            Category  = 'Other'
            Title     = 'Other error events (no built-in rule)'
            Count     = $total
            First     = $null
            Last      = $lastEvent.Time
            Detail    = $detail
            Explain   = 'Error or Critical events this tool has no explanation for. The sample is the most frequent kind.'
            Next      = 'Search the provider and event ID if the machine has a symptom that matches.'
            Sample    = ''
            LastEvent = $lastEvent
        }
    }
    return , $findings
}

function Complete-Findings {
    # Samples need message formatting, so they are filled in after ranking.
    param([object[]]$Findings)
    foreach ($f in $Findings) {
        if ($f.PSObject.Properties['LastEvent'] -and $f.LastEvent -and -not $f.Sample) {
            $f.Sample = '{0} - {1}' -f (Format-Time $f.LastEvent.Time), (Get-EventText $f.LastEvent)
        }
    }
}

function Sort-Findings {
    param([object[]]$Findings)
    # The catch-all bucket sorts after real findings of its severity: it is a
    # sum of unrelated events, so its count says nothing about importance.
    return , @($Findings | Sort-Object `
        @{ Expression = { $script:SeverityRank[$_.Severity] }; Descending = $true }, `
        @{ Expression = { if ($_.RuleId -eq 'other-errors') { 0 } else { 1 } }; Descending = $true }, `
        @{ Expression = 'Count'; Descending = $true }, `
        @{ Expression = 'Last'; Descending = $true })
}

# =========================================
# ===   Context                         ===
# =========================================

function Get-ReviewContext {
    $ctx = [ordered]@{ Computer = $env:COMPUTERNAME }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $ctx.OS = '{0} (build {1})' -f $os.Caption, $os.BuildNumber
        $ctx.Model = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
        $ctx.LoggedOnUser = [string]$cs.UserName
        $ctx.LastBoot = Format-Time $os.LastBootUpTime
        $up = (Get-Date) - $os.LastBootUpTime
        $ctx.Uptime = '{0}d {1}h {2}m' -f [int]$up.TotalDays, $up.Hours, $up.Minutes
    } catch {
        [void]$script:Notes.Add("Could not read system details: $($_.Exception.Message)")
    }
    return $ctx
}

function Get-DumpFiles {
    param([datetime]$Since)
    $found = @()
    $root = $env:SystemRoot
    if (-not $root) { return $found }
    $locations = @(
        @{ Path = (Join-Path $root 'Minidump');           Filter = '*.dmp'; Recurse = $false; Kind = 'Minidump' },
        @{ Path = (Join-Path $root 'MEMORY.DMP');         Filter = $null;   Recurse = $false; Kind = 'Full dump' },
        @{ Path = (Join-Path $root 'LiveKernelReports');  Filter = '*.dmp'; Recurse = $true;  Kind = 'Live kernel' }
    )
    foreach ($loc in $locations) {
        if (-not (Test-Path -LiteralPath $loc.Path)) { continue }
        try {
            if ($loc.Filter) {
                $files = Get-ChildItem -LiteralPath $loc.Path -Filter $loc.Filter -Recurse:$loc.Recurse -File -ErrorAction SilentlyContinue
            } else {
                $files = Get-Item -LiteralPath $loc.Path -ErrorAction SilentlyContinue
            }
            foreach ($f in @($files)) {
                if ($f.LastWriteTime -ge $Since) {
                    $found += [pscustomobject]@{
                        Kind     = $loc.Kind
                        Path     = $f.FullName
                        SizeMB   = [math]::Round($f.Length / 1MB, 1)
                        Modified = $f.LastWriteTime
                    }
                }
            }
        } catch { }
    }
    return , @($found | Sort-Object Modified -Descending)
}

# =========================================
# ===   Rendering                       ===
# =========================================

function New-ReviewReport {
    param([int]$Days, [bool]$IncludeInfo)

    $script:Notes.Clear()
    $since = (Get-Date).AddDays(-$Days)

    $context = Get-ReviewContext
    $coverage = Get-LogCoverage
    $events = Get-ReviewEvents -Since $since

    $incidents = Get-RestartIncidents -Events $events
    $planned = Get-PlannedRestarts -Events $events
    $boots = @($events | Where-Object { $_.Provider -eq 'EventLog' -and $_.Id -eq 6005 }).Count

    $all = @()
    $all += Get-RuleFindings -Events $events -Rules (Get-ReviewRules)
    $all += ConvertTo-IncidentFindings -Incidents $incidents
    $all = Sort-Findings $all

    $shown = @($all | Where-Object { $IncludeInfo -or $_.Severity -ne 'Info' })
    $hidden = @($all | Where-Object { -not ($IncludeInfo -or $_.Severity -ne 'Info') })

    $dumps = Get-DumpFiles -Since $since

    # A log that does not reach back as far as asked is a limit on the review,
    # not evidence that nothing happened earlier.
    $limits = @()
    foreach ($c in $coverage) {
        if ($c.Oldest -and $c.Oldest -gt $since.AddHours(12)) {
            $limits += '{0} log only goes back to {1}, so this review covers {2} day(s), not {3}.' -f `
                $c.Log, (Format-Time $c.Oldest), [math]::Max(0, [int]((Get-Date) - $c.Oldest).TotalDays), $Days
        }
    }

    Complete-Findings $shown

    [pscustomobject]@{
        Computer    = $env:COMPUTERNAME
        Generated   = Get-Date
        Days        = $Days
        Since       = $since
        Context     = $context
        Coverage    = $coverage
        EventsRead  = $events.Count
        Boots       = $boots
        Incidents   = $incidents
        Planned     = $planned
        Findings    = $shown
        Hidden      = $hidden
        Dumps       = $dumps
        Limits      = $limits
        Notes       = @($script:Notes)
    }
}

function Get-ReviewVerdictText {
    param($Report)
    $action = @($Report.Findings | Where-Object { (Get-Verdict $_.Severity) -eq 'ACTION' }).Count
    $review = @($Report.Findings | Where-Object { (Get-Verdict $_.Severity) -eq 'REVIEW' }).Count
    if ($action -eq 0 -and $review -eq 0) { return 'Nothing needing action found.' }
    $parts = @()
    if ($action -gt 0) { $parts += "$action needing action" }
    if ($review -gt 0) { $parts += "$review to review" }
    return ($parts -join ', ') + '.'
}

function Format-ReviewText {
    param($Report, [int]$Top)
    $L = New-Object System.Collections.ArrayList
    $add = { param($s) [void]$L.Add([string]$s) }

    & $add ('EVENT LOG REVIEW  {0}  -  last {1} day(s), generated {2}' -f $Report.Computer, $Report.Days, (Format-Time $Report.Generated))
    $c = $Report.Context
    $bits = @()
    if ($c.OS) { $bits += $c.OS }
    if ($c.Model) { $bits += $c.Model }
    if ($c.LastBoot) { $bits += "last boot $($c.LastBoot) (up $($c.Uptime))" }
    if ($bits.Count) { & $add ($bits -join '; ') }
    & $add ('Read {0} events; {1} boot(s) in the window.' -f $Report.EventsRead, $Report.Boots)
    foreach ($l in $Report.Limits) { & $add "NOTE: $l" }
    foreach ($n in $Report.Notes) { & $add "NOTE: $n" }
    & $add ''
    & $add ('VERDICT: ' + (Get-ReviewVerdictText $Report))

    & $add ''
    $inc = @($Report.Incidents)
    if ($inc.Count -eq 0) {
        & $add 'RESTARTS & CRASHES: no unexpected restarts or crashes recorded.'
    } else {
        & $add ('RESTARTS & CRASHES: {0} unexpected' -f $inc.Count)
        foreach ($i in ($inc | Select-Object -First 8)) {
            $line = '  {0}  {1}' -f (Format-Time $i.Time), $i.Title
            if ($i.WentDownAt) { $line += ' (went down about {0})' -f (Format-Time $i.WentDownAt) }
            if ($i.DuringSleep) { $line += ' [during sleep/resume]' }
            & $add $line
        }
        if ($inc.Count -gt 8) { & $add ('  ... and {0} more (see -OutDir report)' -f ($inc.Count - 8)) }
    }
    $pl = @($Report.Planned)
    if ($pl.Count -gt 0) {
        $last = $pl[0]
        & $add ('  Planned restarts/shutdowns: {0} (latest {1}: {2}, {3})' -f $pl.Count, (Format-Time $last.Time), $last.Reason, $last.Process)
    }

    & $add ''
    $findings = @($Report.Findings)
    if ($findings.Count -eq 0) {
        & $add 'FINDINGS: none.'
    } else {
        $take = [math]::Min($Top, $findings.Count)
        & $add ('FINDINGS (top {0} of {1})' -f $take, $findings.Count)
        $n = 0
        foreach ($f in ($findings | Select-Object -First $take)) {
            $n++
            $range = if ($f.First -and $f.First -ne $f.Last) { '{0} .. {1}' -f (Format-Time $f.First), (Format-Time $f.Last) } else { 'last ' + (Format-Time $f.Last) }
            & $add ('{0,2}. [{1}] {2}  x{3}  ({4})' -f $n, $f.Severity.ToUpper(), $f.Title, $f.Count, $range)
            if ($f.Detail) { & $add ('      {0}' -f $f.Detail) }
            if ((Get-Verdict $f.Severity) -ne 'INFO' -and $n -le 6) {
                & $add ('      why : {0}' -f $f.Explain)
                & $add ('      next: {0}' -f $f.Next)
            }
        }
    }

    if (@($Report.Hidden).Count -gt 0) {
        $h = @($Report.Hidden)
        $events = ($h | Measure-Object -Property Count -Sum).Sum
        & $add ''
        & $add ('Hidden as low value: {0} events in {1} kind(s) (use -IncludeInfo to list).' -f $events, $h.Count)
    }

    $d = @($Report.Dumps)
    if ($d.Count -gt 0) {
        & $add ''
        & $add ('CRASH DUMPS in window: {0}' -f $d.Count)
        foreach ($x in ($d | Select-Object -First 5)) {
            & $add ('  {0}  {1}  {2} MB  {3}' -f (Format-Time $x.Modified), $x.Kind, $x.SizeMB, $x.Path)
        }
    }
    return ($L -join [Environment]::NewLine)
}

function ConvertTo-FindingRows {
    param($Report, [int]$Top)
    $rows = @()
    foreach ($f in ($Report.Findings | Select-Object -First $Top)) {
        $rows += [pscustomobject]@{
            Verdict   = Get-Verdict $f.Severity
            Severity  = $f.Severity
            Finding   = Protect $f.Title
            Count     = $f.Count
            LastSeen  = Format-Time $f.Last
            Detail    = Protect $f.Detail
            NextStep  = Protect $f.Next
        }
    }
    return , $rows
}

function ConvertTo-ReviewHtml {
    param($Report)
    $h = { param($s) [System.Net.WebUtility]::HtmlEncode((Protect ([string]$s))) }
    $sb = New-Object System.Text.StringBuilder
    # A double-quoted here-string: the CSS has no $ or backticks to expand, and
    # sc-console embeds scripts in a single-quoted one, which a '@ line would end.
    $css = @"
body{font:14px/1.45 Segoe UI,Arial,sans-serif;margin:24px;color:#1b1f24;background:#fff}
h1{font-size:20px;margin:0 0 4px}h2{font-size:15px;margin:26px 0 8px;border-bottom:1px solid #d0d7de;padding-bottom:4px}
.sub{color:#57606a;font-size:12.5px}.v{padding:10px 14px;border-radius:6px;margin:14px 0;font-weight:600}
.v.bad{background:#ffebe9;color:#a40e26}.v.warn{background:#fff8c5;color:#7d4e00}.v.ok{background:#dafbe1;color:#1a7f37}
table{border-collapse:collapse;width:100%;margin:6px 0}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eaeef2;vertical-align:top}
th{font-size:11px;text-transform:uppercase;color:#57606a;letter-spacing:.4px}
.sev{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11.5px;font-weight:600;color:#fff}
.Critical{background:#a40e26}.High{background:#d1242f}.Medium{background:#bf8700}.Low{background:#6e7781}.Info{background:#8c959f}
.why{color:#33393f}.next{color:#0a3069}.smp{font:11.5px Consolas,monospace;color:#57606a;word-break:break-word}
.note{background:#ddf4ff;border-radius:6px;padding:8px 12px;margin:6px 0;font-size:13px}
footer{margin-top:30px;color:#6e7781;font-size:12px}
"@
    [void]$sb.AppendLine('<!doctype html><html><head><meta charset="utf-8"><title>Event log review</title><style>' + $css + '</style></head><body>')
    [void]$sb.AppendLine(('<h1>Event log review - {0}</h1>' -f (& $h $Report.Computer)))
    $c = $Report.Context
    $sub = @("Last $($Report.Days) day(s)", "generated $(Format-Time $Report.Generated)")
    if ($c.OS) { $sub += $c.OS }
    if ($c.Model) { $sub += $c.Model }
    if ($c.LastBoot) { $sub += "last boot $($c.LastBoot)" }
    [void]$sb.AppendLine(('<div class="sub">{0}</div>' -f (& $h ($sub -join ' | '))))
    foreach ($l in (@($Report.Limits) + @($Report.Notes))) { [void]$sb.AppendLine(('<div class="note">{0}</div>' -f (& $h $l))) }

    $verdict = Get-ReviewVerdictText $Report
    $cls = 'ok'
    if (@($Report.Findings | Where-Object { (Get-Verdict $_.Severity) -eq 'ACTION' }).Count -gt 0) { $cls = 'bad' }
    elseif (@($Report.Findings | Where-Object { (Get-Verdict $_.Severity) -eq 'REVIEW' }).Count -gt 0) { $cls = 'warn' }
    [void]$sb.AppendLine(('<div class="v {0}">{1}</div>' -f $cls, (& $h $verdict)))

    [void]$sb.AppendLine('<h2>Restarts &amp; crashes</h2>')
    $inc = @($Report.Incidents)
    if ($inc.Count -eq 0) {
        [void]$sb.AppendLine('<p>No unexpected restarts or crashes recorded.</p>')
    } else {
        [void]$sb.AppendLine('<table><tr><th>Logged</th><th>What happened</th><th>Went down about</th><th>Notes</th></tr>')
        foreach ($i in $inc) {
            $notes = @()
            if ($i.DuringSleep) { $notes += 'during sleep/resume' }
            if ($i.Parameters) { $notes += "parameters: $($i.Parameters)" }
            [void]$sb.AppendLine(('<tr><td>{0}</td><td><span class="sev {1}">{1}</span> {2}</td><td>{3}</td><td>{4}</td></tr>' -f `
                (& $h (Format-Time $i.Time)), $i.Severity, (& $h $i.Title), (& $h (Format-Time $i.WentDownAt)), (& $h ($notes -join '; '))))
        }
        [void]$sb.AppendLine('</table>')
    }
    $pl = @($Report.Planned)
    if ($pl.Count -gt 0) {
        [void]$sb.AppendLine(('<h2>Planned restarts &amp; shutdowns ({0})</h2><table><tr><th>Time</th><th>Action</th><th>Reason</th><th>Process</th><th>User</th></tr>' -f $pl.Count))
        foreach ($p in ($pl | Select-Object -First 25)) {
            [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f `
                (& $h (Format-Time $p.Time)), (& $h $p.Action), (& $h $p.Reason), (& $h $p.Process), (& $h $p.User)))
        }
        [void]$sb.AppendLine('</table>')
    }

    [void]$sb.AppendLine(('<h2>Findings ({0})</h2>' -f @($Report.Findings).Count))
    if (@($Report.Findings).Count -eq 0) {
        [void]$sb.AppendLine('<p>None.</p>')
    } else {
        [void]$sb.AppendLine('<table><tr><th>Severity</th><th>Finding</th><th>Count</th><th>First</th><th>Last</th></tr>')
        foreach ($f in $Report.Findings) {
            [void]$sb.AppendLine(('<tr><td><span class="sev {0}">{0}</span></td><td><b>{1}</b> <span class="sub">({2})</span>' -f $f.Severity, (& $h $f.Title), (& $h $f.Category)))
            if ($f.Detail) { [void]$sb.AppendLine(('<div>{0}</div>' -f (& $h $f.Detail))) }
            [void]$sb.AppendLine(('<div class="why">{0}</div><div class="next">Next: {1}</div>' -f (& $h $f.Explain), (& $h $f.Next)))
            if ($f.Sample) { [void]$sb.AppendLine(('<div class="smp">{0}</div>' -f (& $h $f.Sample))) }
            [void]$sb.AppendLine(('</td><td>{0}</td><td>{1}</td><td>{2}</td></tr>' -f $f.Count, (& $h (Format-Time $f.First)), (& $h (Format-Time $f.Last))))
        }
        [void]$sb.AppendLine('</table>')
    }

    if (@($Report.Hidden).Count -gt 0) {
        [void]$sb.AppendLine('<h2>Hidden as low value</h2><table><tr><th>Finding</th><th>Count</th></tr>')
        foreach ($x in $Report.Hidden) { [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td></tr>' -f (& $h $x.Title), $x.Count)) }
        [void]$sb.AppendLine('</table>')
    }
    if (@($Report.Dumps).Count -gt 0) {
        [void]$sb.AppendLine('<h2>Crash dump files in the window</h2><table><tr><th>Modified</th><th>Kind</th><th>Size</th><th>Path</th></tr>')
        foreach ($x in $Report.Dumps) {
            [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2} MB</td><td class="smp">{3}</td></tr>' -f (& $h (Format-Time $x.Modified)), (& $h $x.Kind), $x.SizeMB, (& $h $x.Path)))
        }
        [void]$sb.AppendLine('</table>')
    }
    [void]$sb.AppendLine(('<h2>Log coverage</h2><table><tr><th>Log</th><th>Oldest event</th></tr>'))
    foreach ($x in $Report.Coverage) { [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td></tr>' -f (& $h $x.Log), (& $h (Format-Time $x.Oldest)))) }
    [void]$sb.AppendLine('</table>')
    [void]$sb.AppendLine('<footer>Generated by Invoke-EventLogReview.ps1 (read-only). Explanations are general guidance, not a diagnosis.</footer></body></html>')
    return $sb.ToString()
}

function Export-ReviewReport {
    param($Report, [string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $name = $Report.Computer
    if ($script:MaskOn) { $name = 'HOST' }
    $stamp = $Report.Generated.ToString('yyyyMMdd-HHmm')
    $base = Join-Path $Directory ('EventLogReview_{0}_{1}' -f $name, $stamp)
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText("$base.html", (ConvertTo-ReviewHtml $Report), $utf8)

    $json = [pscustomobject]@{
        Computer  = $Report.Computer
        Generated = Format-Time $Report.Generated
        Days      = $Report.Days
        Context   = $Report.Context
        Limits    = $Report.Limits
        Notes     = $Report.Notes
        Incidents = @($Report.Incidents | ForEach-Object {
                [pscustomobject]@{ Time = Format-Time $_.Time; Severity = $_.Severity; Title = $_.Title; StopCode = $_.StopCode
                                   StopName = $_.StopName; Class = $_.Class; Parameters = $_.Parameters
                                   DuringSleep = $_.DuringSleep; WentDownAt = Format-Time $_.WentDownAt } })
        Findings  = @($Report.Findings | ForEach-Object {
                [pscustomobject]@{ Severity = $_.Severity; Category = $_.Category; Title = $_.Title; Count = $_.Count
                                   First = Format-Time $_.First; Last = Format-Time $_.Last; Detail = $_.Detail
                                   Explain = $_.Explain; Next = $_.Next; Sample = $_.Sample } })
        Dumps     = @($Report.Dumps | ForEach-Object {
                [pscustomobject]@{ Kind = $_.Kind; Path = $_.Path; SizeMB = $_.SizeMB; Modified = Format-Time $_.Modified } })
    } | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText("$base.json", (Protect $json), $utf8)
    return @("$base.html", "$base.json")
}

# =========================================
# ===   Entry point                     ===
# =========================================

function Invoke-EventLogReview {
    [CmdletBinding()]
    param (
        [int]$Days = 7,
        [string]$OutDir,
        [switch]$Mask,
        [int]$Top = 12,
        [switch]$IncludeInfo,
        [switch]$PassThru
    )
    $script:MaskOn = [bool]$Mask
    if ($script:MaskOn) { Initialize-Mask }

    $report = New-ReviewReport -Days $Days -IncludeInfo ([bool]$IncludeInfo)

    Protect (Format-ReviewText -Report $report -Top $Top)

    if ($OutDir) {
        try {
            $files = Export-ReviewReport -Report $report -Directory $OutDir
            ''
            'Reports written:'
            $files | ForEach-Object { '  ' + $_ }
        } catch {
            "Could not write reports to ${OutDir}: $($_.Exception.Message)"
        }
    }

    # Under sc-console an Emit-Json function exists, and the findings become a table.
    if (Get-Command Emit-Json -ErrorAction SilentlyContinue) {
        Emit-Json (ConvertTo-FindingRows -Report $report -Top $Top)
    }
    if ($PassThru) { $report }
}

# Dot-sourcing (the self-test does this) only loads the functions.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-EventLogReview -Days $Days -OutDir $OutDir -Mask:$Mask -Top $Top -IncludeInfo:$IncludeInfo -PassThru:$PassThru
}
