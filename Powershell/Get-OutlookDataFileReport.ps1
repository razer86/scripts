<#
# =========================================
# ===   Get-OutlookDataFileReport.ps1   ===
# =========================================
.SYNOPSIS
    Scans a path for Outlook OST/PST data files and reports their size relative
    to the Unicode-format max file size limit.

.DESCRIPTION
    This script:
      - Recursively searches the given path (default C:\) for *.ost and *.pst files
      - Reports FullPath, Type, SizeGB, LastWriteTime, MaxSizeGB, and PercentOfMax
      - Flags files over the WarnPercent threshold
      - Handles long paths (>260 chars) via the \\?\ prefix so deep profile trees
        under AppData don't silently get skipped
      - Shows a progress bar (folders scanned, files found, current folder)
        while scanning, and skips junctions/symlinks rather than following them

    Background: Unicode-format PST/OST files (Outlook 2003+, i.e. everything in use
    today) default to a 50 GB maximum in current Outlook versions (20 GB in Outlook
    2007/2010). Legacy ANSI-format PSTs (Outlook 2002 and earlier) cap at 2 GB. These
    limits are configurable via the MaxLargeFileSize registry value, so -MaxSizeGB
    lets you match whatever policy is actually in effect.

.PARAMETER Path
    Root path to scan. Default is C:\.

.PARAMETER MaxSizeGB
    The maximum file size (in GB) to calculate percentage against. Default is 50
    (the modern Unicode PST/OST default). Use 2 if checking against legacy ANSI
    PSTs, or your configured MaxLargeFileSize value if it's been changed.

.PARAMETER WarnPercent
    Percentage of MaxSizeGB at which a file is flagged as a warning. Default is 80.

.EXAMPLE
    .\Get-OutlookDataFileReport.ps1
    Scans C:\ for OST/PST files using the 50 GB default limit.

.EXAMPLE
    .\Get-OutlookDataFileReport.ps1 -Path 'D:\' -MaxSizeGB 20
    Scans D:\ against a 20 GB limit (e.g. Outlook 2010 environments).

.PARAMETER PassThru
    Also output the result objects (for piping/filtering) after the summary.

.EXAMPLE
    .\Get-OutlookDataFileReport.ps1 -PassThru | Where-Object PercentOfMax -gt 90 | Format-Table -AutoSize
    Scans and filters to files above 90% of the max size.

.NOTES
    Author  : Raymond Slater
    Source  : https://github.com/razer86/scripts
#>

[CmdletBinding()]
param (
    [string]$Path = 'C:\',
    [double]$MaxSizeGB = 50,
    [double]$WarnPercent = 80,
    [switch]$PassThru
)

function Get-OutlookDataFileReport {
    [CmdletBinding()]
    param (
        [string]$Path = 'C:\',
        [double]$MaxSizeGB = 50,
        [double]$WarnPercent = 80
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Path not found: $Path"
        return
    }

    # Use the \\?\ long-path prefix so files buried deep under AppData
    # (a common spot for OST files) aren't skipped due to MAX_PATH.
    $resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath
    $scanPath = if ($resolvedPath -match '^\\\\') { $resolvedPath } else { "\\?\$resolvedPath" }

    Write-Host "Scanning $Path for OST/PST files - this can take several minutes on a large drive..." -ForegroundColor Cyan

    # Walk folders ourselves (rather than Get-ChildItem -Recurse) so progress can be shown while
    # scanning, and so junctions/symlinks are skipped instead of followed into loops or duplicates.
    $activity = "Scanning $Path for Outlook data files"
    $pending = [System.Collections.Generic.Stack[string]]::new()
    $pending.Push($scanPath)
    $files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $foldersScanned = 0
    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    $sinceProgress = [System.Diagnostics.Stopwatch]::StartNew()

    while ($pending.Count -gt 0) {
        $folder = [System.IO.DirectoryInfo]::new($pending.Pop())
        $foldersScanned++

        if ($sinceProgress.ElapsedMilliseconds -ge 250) {
            Write-Progress -Activity $activity -Status "$foldersScanned folders scanned, $($files.Count) OST/PST found" -CurrentOperation ($folder.FullName -replace '^\\\\\?\\', '')
            $sinceProgress.Restart()
        }

        try {
            # '*.?st' can also match other extensions (and 8.3 short names), so check the real extension
            foreach ($file in $folder.EnumerateFiles('*.?st')) {
                if ($file.Extension -in '.ost', '.pst') { $files.Add($file) }
            }
            foreach ($sub in $folder.EnumerateDirectories()) {
                if (-not ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    $pending.Push($sub.FullName)
                }
            }
        }
        catch {
            # Access-denied and vanished folders are expected when scanning a whole drive
            Write-Verbose "Skipped $($folder.FullName): $($_.Exception.Message)"
        }
    }

    Write-Progress -Activity $activity -Completed
    Write-Host ("Scanned {0:N0} folders in {1:N0}s" -f $foldersScanned, $elapsed.Elapsed.TotalSeconds) -ForegroundColor DarkGray

    foreach ($file in $files) {
        $sizeGB = [math]::Round($file.Length / 1GB, 3)
        $percentOfMax = if ($MaxSizeGB -gt 0) { [math]::Round(($sizeGB / $MaxSizeGB) * 100, 1) } else { 0 }

        [pscustomobject]@{
            FullName      = $file.FullName -replace '^\\\\\?\\', ''
            Type          = $file.Extension.TrimStart('.').ToUpper()
            SizeGB        = $sizeGB
            SizeMB        = [math]::Round($file.Length / 1MB, 1)
            LastWriteTime = $file.LastWriteTime
            MaxSizeGB     = $MaxSizeGB
            PercentOfMax  = $percentOfMax
            Warning       = $percentOfMax -ge $WarnPercent
        }
    }
}

# =========================================
# ===   Script Output                   ===
# =========================================

$results = Get-OutlookDataFileReport -Path $Path -MaxSizeGB $MaxSizeGB -WarnPercent $WarnPercent | Sort-Object PercentOfMax -Descending

if (-not $results) {
    Write-Host "No OST/PST files found under $Path" -ForegroundColor Yellow
    return
}

Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ("Scan Path             : {0}" -f $Path) -ForegroundColor Cyan
Write-Host ("Max Size Limit        : {0} GB" -f $MaxSizeGB) -ForegroundColor Cyan
Write-Host ("Files Found           : {0}" -f $results.Count) -ForegroundColor Cyan
Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

foreach ($r in $results) {
    $color = if ($r.Warning) { 'Red' } elseif ($r.PercentOfMax -ge 50) { 'Yellow' } else { 'Green' }
    Write-Host ("{0,6:N1}%  {1,10:N2} GB  {2}  {3}  {4}" -f $r.PercentOfMax, $r.SizeGB, $r.Type, $r.LastWriteTime, $r.FullName) -ForegroundColor $color
}

if ($PassThru) {
    return $results
}
