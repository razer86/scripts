<#
.SYNOPSIS
    Builds a standalone rdpwrap-offset-finder.exe (no Python needed on the target) from
    https://github.com/bobotechnology/RDPWrapOffsetFinder using PyInstaller.

.DESCRIPTION
    Clones the repo at the given ref, creates a throwaway venv, installs runtime deps + PyInstaller,
    builds the console EXE only (the GUI build is skipped), and smoke-tests it against this machine's
    termsrv.dll in both symbol and --nosymbol modes. Writes the EXE and a build-info.txt beside it.

    Copy the resulting EXE to the monitor install folder on the target (default C:\ProgramData\RDPWrapMonitor)
    so Repair-RdpWrapIni.ps1 can use it when the upstream ini is behind.

.PARAMETER OutputDir
    Where to place rdpwrap-offset-finder.exe and build-info.txt. Default: .\dist under this script.

.PARAMETER Ref
    Git ref (branch, tag or commit) to build. Default: main.

.PARAMETER PythonVersion
    Python launcher version tag (py -X.Y). Default 3.13; iced-x86 wheels may lag newest Python releases.

.EXAMPLE
    .\Build-OffsetFinder.ps1
    .\Build-OffsetFinder.ps1 -OutputDir C:\Tools\RDPWrap -Ref 9064109
#>

[CmdletBinding()]
param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist'),
    [string]$Ref = 'main',
    [string]$PythonVersion = '3.13',
    [string]$RepoUrl = 'https://github.com/bobotechnology/RDPWrapOffsetFinder'
)

$ErrorActionPreference = 'Stop'

foreach ($tool in 'git', 'py') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' not found on PATH" }
}

$work = Join-Path ([IO.Path]::GetTempPath()) "rdpwof-build-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$src  = Join-Path $work 'src'
$venv = Join-Path $work 'venv'
New-Item -ItemType Directory -Path $work, $OutputDir -Force | Out-Null

try {
    Write-Host "Cloning $RepoUrl @ $Ref ..."
    git clone --quiet $RepoUrl $src
    git -C $src checkout --quiet $Ref
    $commit  = git -C $src rev-parse --short HEAD
    $version = (Get-Content (Join-Path $src 'version.py') -Raw | Select-String '"([^"]+)"').Matches[0].Groups[1].Value

    Write-Host "Creating venv (Python $PythonVersion) and installing dependencies ..."
    py "-$PythonVersion" -m venv $venv
    $python = Join-Path $venv 'Scripts\python.exe'
    & $python -m pip install --quiet --upgrade pip
    & $python -m pip install --quiet pefile iced-x86 pyinstaller
    $pyiVer = (& $python -m PyInstaller --version).Trim()

    # Module list mirrors build_exe.py in the repo; hidden-imports are needed because modules load dynamically
    $modules = 'symbols','nosymbol','nosymbol_arch','ms_pdb','patches','pe_image','imports',
               'exception_table','disasm','winver','dbghelp','portable_pdb','analysis_log','codescan'
    $hidden  = $modules | ForEach-Object { '--hidden-import'; $_ }

    Write-Host "Building console EXE ..."
    Push-Location $src
    try {
        & $python -m PyInstaller --onefile --console --name rdpwrap-offset-finder `
            --distpath (Join-Path $work 'dist') --workpath (Join-Path $work 'build') --specpath $work `
            --clean --noconfirm @hidden main.py | Out-Null
    } finally { Pop-Location }

    $exe = Join-Path $work 'dist\rdpwrap-offset-finder.exe'
    if (-not (Test-Path $exe)) { throw "PyInstaller did not produce $exe" }

    Write-Host "Smoke testing against local termsrv.dll ..."
    $symOut = & $exe 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $symOut -notmatch '(?m)^\[\d+\.\d+\.\d+\.\d+\]') {
        throw "Symbol-mode smoke test failed:`n$symOut"
    }
    $nosOut = & $exe --nosymbol 2>&1 | Out-String
    $modesAgree = ($symOut.Trim() -eq $nosOut.Trim())
    if (-not $modesAgree) { Write-Warning "--nosymbol output differs from symbol mode on this machine (not fatal; symbol mode is authoritative)" }

    $dest = Join-Path $OutputDir 'rdpwrap-offset-finder.exe'
    Copy-Item $exe $dest -Force
    $hash = (Get-FileHash $dest -Algorithm SHA256).Hash
    @(
        "rdpwrap-offset-finder.exe"
        "Source   : $RepoUrl @ $commit (v$version)"
        "Built    : $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME"
        "Toolchain: Python $PythonVersion, PyInstaller $pyiVer"
        "SHA256   : $hash"
        "Smoke    : symbol OK; --nosymbol $(if ($modesAgree) { 'matches' } else { 'DIFFERS' })"
    ) | Set-Content (Join-Path $OutputDir 'build-info.txt')

    Write-Host "`nDone: $dest"
    Write-Host "SHA256: $hash"
    Write-Host "Local termsrv.dll section (for reference):`n$symOut"
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
