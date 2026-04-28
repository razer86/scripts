#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy plex_dbrepair script + description to Unraid via the SMB flash share.

.DESCRIPTION
    Reads .secrets (KEY=value lines) from this directory, substitutes the
    values into the matching assignment lines at the top of `script`, and
    writes both `script` (with substitutions) and `description` (as-is) to
    the Unraid flash share over SMB so the User Scripts plugin sees them
    as one unit.

    The repo copy of `script` ships with empty values; this script never
    modifies the repo copy. Output is written directly to the remote path.

.PARAMETER Server
    Unraid hostname or IP. Default: Tower.

.PARAMETER Share
    SMB share name for the Unraid flash drive. Default: flash.

.PARAMETER RemotePath
    Path within the share to the `script` file, using forward slashes.
    The description is deployed alongside it (same directory, name `description`).

.PARAMETER SourceScript
    Local script template. Default: ./script (next to this file).

.PARAMETER SourceDescription
    Local description file. Default: ./description (next to this file).

.PARAMETER SecretsFile
    Local secrets file. Default: ./.secrets (next to this file).

.EXAMPLE
    ./deploy.ps1
        Deploy with defaults to \\Tower\flash\config\plugins\user.scripts\scripts\PlexDBRepair\script

.EXAMPLE
    ./deploy.ps1 -Server 192.168.1.50 -WhatIf
        Preview against a different host without writing.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Server            = 'Tower',
    [string]$Share             = 'flash',
    [string]$RemotePath        = 'config/plugins/user.scripts/scripts/PlexDBRepair/script',
    [string]$SourceScript      = (Join-Path $PSScriptRoot 'script'),
    [string]$SourceDescription = (Join-Path $PSScriptRoot 'description'),
    [string]$SecretsFile       = (Join-Path $PSScriptRoot '.secrets')
)

$ErrorActionPreference = 'Stop'

# ---------- Inputs ----------
if (-not (Test-Path -LiteralPath $SourceScript)) {
    throw "Source script not found: $SourceScript"
}
if (-not (Test-Path -LiteralPath $SourceDescription)) {
    throw "Source description not found: $SourceDescription"
}
if (-not (Test-Path -LiteralPath $SecretsFile)) {
    throw "Secrets file not found: $SecretsFile`n  Copy .secrets.example to .secrets and fill in real values."
}

# ---------- Parse .secrets ----------
$secrets = [ordered]@{}
$lineNo  = 0
foreach ($raw in Get-Content -LiteralPath $SecretsFile) {
    $lineNo++
    $line = $raw.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }

    $eq = $line.IndexOf('=')
    if ($eq -lt 1) { throw "Malformed line $lineNo in ${SecretsFile}: $raw" }

    $key = $line.Substring(0, $eq).Trim()
    $val = $line.Substring($eq + 1)

    # Strip a single layer of matching surrounding quotes.
    if ($val.Length -ge 2) {
        $first = $val[0]; $last = $val[$val.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $val = $val.Substring(1, $val.Length - 2)
        }
    }

    $secrets[$key] = $val
}

# ---------- Required keys ----------
$required = @(
    'PLEX_CONTAINER',
    'PLEX_TOKEN',
    'PLEX_PORT',
    'DBREPAIR_HOST_PATH',
    'DBREPAIR_CONTAINER_PATH',
    'DBREPAIR_URL',
    'LOG_FILE',
    'DISCORD_WEBHOOK'  # may be empty, but must be present so we substitute the line
)
$missing = $required | Where-Object { -not $secrets.Contains($_) }
if ($missing) {
    throw "Missing required keys in ${SecretsFile}: $($missing -join ', ')"
}

# ---------- Sanity-check FUSE paths client-side ----------
foreach ($k in @('DBREPAIR_HOST_PATH', 'LOG_FILE')) {
    if ($secrets[$k] -like '/mnt/user/*') {
        Write-Warning "$k is set to '$($secrets[$k])' which is the Unraid FUSE layer. The script will refuse to run."
    }
}

# ---------- Read template (preserve existing line endings) ----------
$content = [System.IO.File]::ReadAllText($SourceScript)

# ---------- Substitute each KEY="" with KEY="value" ----------
foreach ($k in $required) {
    $v = [string]$secrets[$k]
    # Bash double-quoted string escape: backslash, double-quote, backtick, dollar sign.
    $escaped = $v `
        -replace '\\', '\\' `
        -replace '"',  '\"' `
        -replace '`',  '\`' `
        -replace '\$', '\$'

    $pattern = "(?m)^${k}=`"`""
    $regex   = [System.Text.RegularExpressions.Regex]::new($pattern)
    if (-not $regex.IsMatch($content)) {
        throw "Variable '$k' assignment line not found in template (expected literal: ${k}="""")."
    }

    $replacement = "${k}=`"${escaped}`""
    $evaluator   = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $replacement }
    $content     = $regex.Replace($content, $evaluator, 1)
}

# ---------- Compute UNC destinations ----------
$remoteWin     = $RemotePath -replace '/', '\'
$uncScriptPath = "\\${Server}\${Share}\${remoteWin}"
# Note: Split-Path -LiteralPath -Parent throws AmbiguousParameterSet on UNC paths
# in some PowerShell versions; use the .NET API directly.
$uncDir        = [System.IO.Path]::GetDirectoryName($uncScriptPath)
$uncDescPath   = Join-Path $uncDir 'description'

if (-not (Test-Path -LiteralPath $uncDir)) {
    throw @"
Destination directory not reachable: $uncDir
  - Confirm the server is up and the SMB share '$Share' is exported.
  - Try opening '\\${Server}\${Share}' in Explorer first to authenticate.
  - Override with -Server / -Share / -RemotePath if your layout differs.
"@
}

# ---------- Read description as-is (no substitution) ----------
$descContent = [System.IO.File]::ReadAllText($SourceDescription)

# ---------- Write (UTF-8 no BOM, LF preserved from source) ----------
$utf8NoBom   = [System.Text.UTF8Encoding]::new($false)
$scriptBytes = $utf8NoBom.GetByteCount($content)
$descBytes   = $utf8NoBom.GetByteCount($descContent)

if ($PSCmdlet.ShouldProcess($uncScriptPath, "Write $scriptBytes bytes")) {
    [System.IO.File]::WriteAllText($uncScriptPath, $content, $utf8NoBom)
    Write-Host "Deployed $scriptBytes bytes to $uncScriptPath" -ForegroundColor Green
}
if ($PSCmdlet.ShouldProcess($uncDescPath, "Write $descBytes bytes")) {
    [System.IO.File]::WriteAllText($uncDescPath, $descContent, $utf8NoBom)
    Write-Host "Deployed $descBytes bytes to $uncDescPath" -ForegroundColor Green
}
