<#
.SYNOPSIS
    Build the Doom Emacs Windows installer end to end.

.DESCRIPTION
    One command from a clean checkout to a shippable .exe:

        fetch-payloads.ps1  ->  stage-payloads.ps1  ->  makensis  ->  dist\*.exe

    Sources and pins select an isolated staging workspace. Completed payloads
    can be reused; an interrupted workspace is retained by just restage.
    build\state.json records results, but never skips integrity checks.

.PARAMETER Stages
    Run only these stages: fetch, stage, compile. Default is all three.

.PARAMETER Clean
    Reset build history. Does not delete workspaces or force archive extraction.

.PARAMETER SkipCompress
    Build with NSIS compression off. Produces a huge .exe in about a minute
    instead of a normal one in fifteen. For iterating on installer logic.

.EXAMPLE
    .\build-installer.ps1                    # full build
    .\build-installer.ps1 -Stages compile    # just recompile the .exe
    .\build-installer.ps1 -SkipCompress      # fast iteration
#>
[CmdletBinding()]
param(
    [ValidateSet('fetch', 'stage', 'compile')]
    [string[]]$Stages = @('fetch', 'stage', 'compile'),
    [switch]$Clean,
    [switch]$SkipCompress,
    [string]$StagingDir,
    [string]$OutDir,
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._+-]*$')][string]$Version
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$installerDir = (Resolve-Path (Join-Path $scriptDir '..')).Path
$repoRoot     = (Resolve-Path (Join-Path $installerDir '..')).Path
. (Join-Path $scriptDir 'build-context.ps1')
$context = Get-DoomBuildContext -Repo $repoRoot

if (-not $StagingDir) { $StagingDir = $context.Stage }
if (-not $OutDir)     { $OutDir     = Join-Path $installerDir 'dist' }

$stateFile = Join-Path $scriptDir 'state.json'

function Write-Head([string]$m) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host "  $m" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}
function Write-Ok([string]$m)   { Write-Host "    OK    $m" -ForegroundColor Green }
function Write-Info([string]$m) { Write-Host "          $m" -ForegroundColor DarkGray }
function Write-Bad([string]$m)  { Write-Host "    FAIL  $m" -ForegroundColor Red }

function Get-State {
    if ($Clean -or -not (Test-Path $stateFile)) { return @{} }
    $h = @{}
    (Get-Content $stateFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
    return $h
}
function Save-State($s) { $s | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding utf8 }

function Find-MakeNsis {
    return Get-DoomBuildToolPath -InstallerDir $installerDir -Lock $context.Lock -Id 'nsis'
}

# ---------------------------------------------------------------------- main

Write-Head 'Doom Emacs Windows installer - build'

$state = Get-State
Write-Info "repo      : $repoRoot"
Write-Info "staging   : $StagingDir"
Write-Info "output    : $OutDir"
Write-Info "stages    : $($Stages -join ', ')"
if ($Clean) { Write-Info 'clean build (ignoring state.json)' }

if (-not $Version) {
    # The version lives in the .doom file at the repo root, not in a defconst --
    # upstream replaced the doom-version variable with a function that reads it
    # from there. Matching on lisp/doom.el silently yielded 0.0.0 for every build.
    $Version = $context.Version
}
Write-Info "version   : $Version"

# ------------------------------------------------------------- stage: fetch

if ($Stages -contains 'fetch') {
    Write-Head 'Stage 1/3  fetch payloads'
    & (Join-Path $scriptDir 'fetch-build-tools.ps1')
    & (Join-Path $scriptDir 'fetch-payloads.ps1')
    if ($LASTEXITCODE -ne 0) { Write-Bad 'payload fetch failed'; exit 1 }
    $state['fetch'] = @{ at = (Get-Date).ToUniversalTime().ToString('o') }
    Save-State $state
    Write-Ok 'payloads verified'
}

# ------------------------------------------------------------- stage: stage

if ($Stages -contains 'stage') {
    Write-Head 'Stage 2/3  unpack into install layout'
    & (Join-Path $scriptDir 'stage-payloads.ps1') -StagingDir $StagingDir
    if ($LASTEXITCODE -ne 0) { Write-Bad 'staging failed'; exit 1 }

    # The install engine and uninstaller ship INSIDE the payload, so the installed
    # copy can remove itself and so a standalone user has both to hand.
    foreach ($f in @('install-doom.ps1', 'uninstall-doom.ps1', 'env-path.ps1', 'repair-doom.ps1', 'native-process.ps1', 'wsl-integration.ps1', 'package-sync.ps1', 'font-integration.ps1')) {
        Copy-Item (Join-Path $installerDir $f) (Join-Path $StagingDir $f) -Force
    }
    Write-Ok 'install/uninstall scripts and shared PATH helper staged alongside payload'
    Save-DoomStageInventory $StagingDir

    $sz = (Get-ChildItem $StagingDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $state['stage'] = @{ at = (Get-Date).ToUniversalTime().ToString('o'); bytes = $sz }
    Save-State $state
    Write-Ok ('staged {0:N2} GB' -f ($sz / 1GB))
}

# ----------------------------------------------------------- stage: compile

if ($Stages -contains 'compile') {
    Write-Head 'Stage 3/3  compile installer'

    if (-not (Test-Path $StagingDir)) { Write-Bad "nothing staged at $StagingDir - run the stage step first"; exit 1 }
    Initialize-DoomStage $context $StagingDir
    $nsi = Join-Path $installerDir 'doom.nsi'
    if (-not (Test-Path $nsi)) { Write-Bad "NSIS script not found: $nsi"; exit 1 }

    $makensis = Find-MakeNsis
    Write-Info "makensis  : $makensis"
    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

    # Uncompressed builds get their own name. They share a filename otherwise, and
    # a -SkipCompress run will happily truncate a finished release .exe to 0 bytes
    # and spend the next ten minutes refilling it -- which looks exactly like a
    # corrupt build if you check the size at the wrong moment.
    if ($SkipCompress) {
        $outFile = Join-Path $OutDir "DoomEmacs-$Version-x86_64-setup-uncompressed.exe"
    } else {
        $outFile = Join-Path $OutDir "DoomEmacs-$Version-x86_64-setup.exe"
    }

    # NSIS flags use / on Windows, but if this script is ever driven from an MSYS
    # shell those get mangled into paths (/VERSION becomes C:/Program Files/Git/VERSION).
    # Calling makensis directly from PowerShell with -D form avoids it entirely.
    $nsisArgs = @(
        "-DVERSION=$Version",
        "-DEMACS_VERSION=$($context.EmacsVersion)",
        "-DPRODUCT_VERSION=$($context.ProductVersion)",
        "-DSTAGING=$StagingDir",
        "-DOUTFILE=$outFile"
    )
    if ($SkipCompress) {
        $nsisArgs += '-DNOCOMPRESS=1'
        Write-Info 'compression disabled (-SkipCompress): large .exe, fast build'
    }
    $nsisArgs += $nsi

    if (-not $SkipCompress) { Write-Info 'compressing - this is the slow part, expect 10+ minutes' }
    & $makensis @nsisArgs
    if ($LASTEXITCODE -ne 0) { Write-Bad "makensis failed with exit code $LASTEXITCODE"; exit 1 }

    if (-not (Test-Path $outFile)) { Write-Bad "makensis reported success but $outFile is missing"; exit 1 }

    $exe = Get-Item $outFile
    $hash = (Get-FileHash $outFile -Algorithm SHA256).Hash.ToLower()
    $state['compile'] = @{
        at = (Get-Date).ToUniversalTime().ToString('o')
        file = $outFile; bytes = $exe.Length; sha256 = $hash
    }
    Save-State $state

    Write-Ok ('{0}  ({1:N1} MB)' -f $exe.Name, ($exe.Length / 1MB))
    Write-Info "sha256: $hash"
}

$sw.Stop()
Write-Head 'Build complete'
Write-Info "elapsed: $([math]::Round($sw.Elapsed.TotalMinutes,1)) min"
if (($Stages -contains 'compile') -and $state['compile']) {
    Write-Host ''
    Write-Host "  $($state['compile'].file)" -ForegroundColor Green
    Write-Host ''
}
exit 0
