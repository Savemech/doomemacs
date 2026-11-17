<#
.SYNOPSIS
    Extract verified payloads into the final install layout.

.DESCRIPTION
    Unpacks pinned archives from installer/cache/ into an input-specific workspace
    outside the checkout, arranged as it will appear under the install root.

    Archive roots are auto-detected rather than trusted from the lockfile: if every
    entry in a zip shares one top-level directory, that directory is stripped. The
    lockfile's stripRoot field is treated as advisory and a disagreement is reported,
    because hand-maintained flags drift (the Emacs entry was wrong on first writing).

    Completed workspaces reuse payloads recorded in .staged.json. Changed source
    or lock inputs select a fresh workspace; interrupted workspaces are retained.

.PARAMETER Force
    Re-extract everything, ignoring .staged.json.

.PARAMETER Only
    Stage just these payload ids.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string[]]$Only,
    [string]$LockFile,
    [string]$CacheDir,
    [string]$StagingDir
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $LockFile)   { $LockFile   = Join-Path $scriptDir 'payloads.lock.json' }
if (-not $CacheDir)   { $CacheDir   = Join-Path $scriptDir '..\cache' }
. (Join-Path $scriptDir 'build-context.ps1')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir '..\..'))
$context = Get-DoomBuildContext -Repo $repoRoot -LockFile $LockFile

# Staging deliberately lives OUTSIDE the repo. Staged inside it, `doom version`
# reported our own dev branch: git discovery walked up out of staging/doom and
# found the parent checkout, so the staged tree inherited a repo it will not ship
# with. That is precisely the "passes because of contamination" failure the test
# harness exists to prevent, so the default keeps 1.4GB of payload out of the
# working tree entirely.
if (-not $StagingDir) { $StagingDir = $context.Stage }
Initialize-DoomStage $context $StagingDir

function Write-Stage([string]$m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)    { Write-Host "    OK    $m" -ForegroundColor Green }
function Write-Info([string]$m)  { Write-Host "          $m" -ForegroundColor DarkGray }
function Write-Warn([string]$m)  { Write-Host "    WARN  $m" -ForegroundColor Yellow }
function Write-Bad([string]$m)   { Write-Host "    FAIL  $m" -ForegroundColor Red }

function Format-Size([long]$b) {
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    return ('{0:N1} KB' -f ($b / 1KB))
}

function Get-ZipCommonRoot {
    param([System.IO.Compression.ZipArchive]$Zip)
    $roots = @{}
    foreach ($e in $Zip.Entries) {
        $first = ($e.FullName -split '/')[0]
        if ($first) { $roots[$first] = $true }
    }
    if ($roots.Count -eq 1) {
        $root = @($roots.Keys)[0]
        if (-not @($Zip.Entries | Where-Object { $_.FullName -ne ($root + '/') -and -not $_.FullName.StartsWith($root + '/') }).Count) { return $root }
    }
    return $null
}

function Expand-ZipPayload {
    param([string]$Archive, [string]$Dest, [bool]$LockSaysStrip, [string[]]$Files)

    $zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $root = Get-ZipCommonRoot -Zip $zip
        $strip = [bool]$root
        if ($strip -ne $LockSaysStrip) {
            Write-Warn "lockfile stripRoot=$LockSaysStrip but archive says $strip (root='$root') - trusting the archive"
        }
        if ($strip) { Write-Info "stripping common root '$root/'" }

        $n = 0
        foreach ($e in $zip.Entries) {
            $rel = $e.FullName
            if ($strip) {
                $rel = $rel.Substring($root.Length)
                $rel = $rel.TrimStart('/')
            }
            if (-not $rel) { continue }
            if ($Files -and $Files -cnotcontains $rel) { continue }
            $out = [IO.Path]::GetFullPath((Join-Path $Dest ($rel -replace '/', '\')))
            if (-not $out.StartsWith([IO.Path]::GetFullPath($Dest).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'ZIP member escapes its destination.' }

            if ($e.Length -eq 0 -and $e.FullName.EndsWith('/')) {
                if (-not (Test-Path $out)) { New-Item -ItemType Directory -Force -Path $out | Out-Null }
                continue
            }
            $dir = Split-Path -Parent $out
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
            $n++
        }
        return $n
    } finally {
        $zip.Dispose()
    }
}

function Expand-Msys2Payload {
    param([string]$Archive, [string]$Dest, [string]$Zstd)

    # MSYS2 packages carry .BUILDINFO/.MTREE/.PKGINFO metadata beside the real
    # ucrt64/ tree. Extract only ucrt64/ and strip it.
    #
    # Decompress to a plain .tar first rather than using tar's --use-compress-program.
    # That flag resolves through whichever tar is first on PATH, and MSYS's GNU tar
    # mangles the Windows path to zstd.exe into "C\:Users..." before exec'ing it.
    # Two steps with an explicitly-resolved native bsdtar sidesteps the whole mess.
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Force -Path $Dest | Out-Null }
    $before = (Get-ChildItem $Dest -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count

    $sysTar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path $sysTar)) { throw "native bsdtar not found at $sysTar" }

    $tmpTar = Join-Path ([System.IO.Path]::GetTempPath()) ("doomstage-" + [guid]::NewGuid().ToString('N') + '.tar')
    try {
        & $Zstd -d -q -f -o $tmpTar $Archive
        if ($LASTEXITCODE -ne 0) { throw "zstd failed with exit code $LASTEXITCODE" }
        $entries=@(& $sysTar -tf $tmpTar)
        if ($LASTEXITCODE) { throw 'Cannot inspect native package archive.' }
        if (-not @($entries | Where-Object { $_ -match '^ucrt64/' }).Count) { return 0 }
        & $sysTar -xf $tmpTar -C $Dest --strip-components=1 ucrt64
        if ($LASTEXITCODE -ne 0) { throw "bsdtar failed with exit code $LASTEXITCODE" }
    } finally {
        if (Test-Path $tmpTar) { Remove-Item $tmpTar -Force -ErrorAction SilentlyContinue }
    }

    $after = (Get-ChildItem $Dest -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    return ($after - $before)
}

function Expand-7ZipPayload {
    param([string]$Archive, [string]$Dest, [string[]]$Files)
    $exe = Get-DoomBuildToolPath -InstallerDir (Split-Path -Parent $scriptDir) -Lock $lock -Id '7zr'
    # Extract as an archive; never execute PortableGit's self-extracting program.
    & $exe x -y -bso0 -bsp0 "-o$Dest" $Archive @Files
    if ($LASTEXITCODE) { throw "PortableGit support extraction failed ($LASTEXITCODE)." }
    foreach ($file in $Files) {
        if (-not (Test-Path -Path (Join-Path $Dest $file))) { throw "Archive member missing: $file" }
    }
    return $Files.Count
}

# ---------------------------------------------------------------------- main

Write-Stage 'Doom Emacs installer - stage payloads'

if (-not (Test-Path $LockFile)) { throw "Lockfile not found: $LockFile" }
$lock = Get-Content $LockFile -Raw | ConvertFrom-Json
$CacheDir = (Resolve-Path $CacheDir).Path

$zstd = Get-DoomBuildToolPath -InstallerDir (Split-Path -Parent $scriptDir) -Lock $lock -Id 'zstd'
$needZstd = @($lock.payloads | Where-Object { $_.filename -like '*.zst' }).Count -gt 0
if ($needZstd -and -not (Test-Path $zstd)) {
    throw "zstd.exe not found at $zstd. Run just bootstrap first."
}

if (-not (Test-Path $StagingDir)) { New-Item -ItemType Directory -Force -Path $StagingDir | Out-Null }
$StagingDir = (Resolve-Path $StagingDir).Path
Write-Info "cache   : $CacheDir"
Write-Info "staging : $StagingDir"

$markerFile = Join-Path $StagingDir '.staged.json'
$staged = @{}
if ((Test-Path $markerFile) -and -not $Force) {
    $m = Get-Content $markerFile -Raw | ConvertFrom-Json
    foreach ($p in $m.PSObject.Properties) { $staged[$p.Name] = $p.Value }
}

$failed = @()
foreach ($p in $lock.payloads) {
    if ($Only -and $Only -notcontains $p.id) { continue }

    $dest = Join-Path $StagingDir ($p.installSubdir -replace '/', '\')
    Write-Stage "$($p.id) -> $($p.installSubdir)"

    if (-not $Force -and $staged[$p.id] -eq $p.sha256 -and (Test-Path $dest)) {
        Write-Ok 'already staged at this hash'
        continue
    }

    $archive = Join-Path $CacheDir $p.filename
    if (-not (Test-Path $archive)) {
        Write-Bad "payload missing from cache: $($p.filename) - run fetch-payloads.ps1"
        $failed += $p.id
        continue
    }

    try {
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }

        if ($p.filename -like '*.zip') {
            $n = Expand-ZipPayload -Archive $archive -Dest $dest -LockSaysStrip ([bool]$p.stripRoot) -Files $p.files
        } elseif ($p.filename -like '*.7z.exe' -or $p.filename -like '*.7z') {
            $n = Expand-7ZipPayload -Archive $archive -Dest $dest -Files $p.files
        } elseif ($p.filename -like '*.pkg.tar.zst') {
            $n = Expand-Msys2Payload -Archive $archive -Dest $dest -Zstd $zstd
        } else {
            throw "don't know how to extract $($p.filename)"
        }

        $staged[$p.id] = $p.sha256
        Write-Ok "$n files"
    } catch {
        Write-Bad "$($p.id): $($_.Exception.Message)"
        $failed += $p.id
    }
}

$staged | ConvertTo-Json -Depth 4 | Set-Content -Path $markerFile -Encoding utf8

# ------------------------------------------------- Doom itself, and the shims

Write-Stage 'doom -> doom (working tree)'
$repoRoot = (Resolve-Path (Join-Path $scriptDir '..\..')).Path
$doomDest = Join-Path $StagingDir 'doom'

$moduleRevision = & git -C (Join-Path $repoRoot 'sources\doom+') rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $moduleRevision -ne $lock.doom.submodule.sha) {
    throw 'The Doom module checkout does not match payloads.lock.json. Initialize the pinned submodule before building.'
}

# Copy tracked sources, including the module checkout. New inputs get a new
# workspace; never mirror-delete an existing directory or ship ignored caches.
foreach ($relative in $context.Sources) {
    $target = Join-Path $doomDest $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $target -Force
}
Write-Ok "$($context.Sources.Count) tracked source files"

Write-Stage 'shims -> bin'
foreach ($source in @(& git -C $repoRoot -c core.quotepath=false ls-files installer/files)) {
    $target = Join-Path $StagingDir $source.Substring('installer/files/'.Length)
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot $source) -Destination $target -Force
}
if ($LASTEXITCODE) { throw 'Cannot enumerate installer assets.' }
$fonts = foreach ($p in @($lock.payloads | Where-Object fontFamily)) {
    foreach ($file in @($p.files | Where-Object { $_ -like '*.ttf' })) {
        $relative = $p.installSubdir.Substring('fonts/'.Length) + '/' + $file
        $path = Join-Path $StagingDir ($p.installSubdir + '/' + $file)
        [pscustomobject]@{file=$relative;family=$p.fontFamily;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
}
Write-DoomJson (Join-Path $StagingDir 'fonts\manifest.json') @{schema=1;fonts=@($fonts)}
Write-DoomJson (Join-Path $StagingDir 'build-info.json') @{schema=1;fingerprint=$context.Fingerprint;lock=$lock}

# These programs select decompression mode by argv[0]. Dired invokes the
# traditional names directly, and its 7z commands do not look for 7za.
foreach ($alias in @(
    @('deps/git/usr/bin/bzip2.exe','deps/git/usr/bin/bunzip2.exe'),
    @('deps/git/usr/bin/gzip.exe','deps/git/usr/bin/gunzip.exe'),
    @('deps/git/usr/bin/gzip.exe','deps/git/usr/bin/uncompress.exe'),
    @('deps/xz/bin_x86-64/xz.exe','deps/xz/bin_x86-64/unxz.exe'),
    @('deps/zstd/zstd.exe','deps/zstd/unzstd.exe'),
    @('deps/7zip/x64/7za.exe','deps/7zip/x64/7z.exe')
)) {
    Copy-Item -LiteralPath (Join-Path $StagingDir $alias[0]) -Destination (Join-Path $StagingDir $alias[1]) -Force
}

Write-Stage 'Configuring bundled git'

# The deepest path in a real install came from a git clone, not from our own
# layout: a test fixture inside the flycheck repo, 150 characters below the
# install root. straight.el clones a couple of hundred repos and any of them may
# nest arbitrarily, so this is unbounded and cannot be designed around.
#
# core.longpaths makes git use the \\?\ prefix internally, which lifts the 260
# character limit for git's own file operations regardless of the machine's
# LongPathsEnabled setting or any manifest. It is the one lever here that fixes
# the unbounded half of the problem.
$gitCfg = Join-Path $StagingDir 'deps\git\etc\gitconfig'
if (Test-Path $gitCfg) {
    $gitExe = Join-Path $StagingDir 'deps\git\cmd\git.exe'
    & $gitExe config --file $gitCfg core.longpaths true
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "core.longpaths=true (lifts git's 260-char limit when cloning packages)"
    } else {
        Write-Warn "could not set core.longpaths (git exit $LASTEXITCODE)"
    }
} else {
    Write-Warn "bundled gitconfig not found at $gitCfg"
}

Write-Stage 'Branding executables'

foreach ($name in @('emacsclient.exe', 'emacsclientw.exe', 'emacs.exe', 'runemacs.exe', "emacs-$($context.EmacsVersion).exe")) {
    & (Join-Path $scriptDir 'set-client-utf8.ps1') -ExePath (Join-Path $StagingDir ('emacs\bin\' + $name))
}
foreach ($proxy in @(Get-ChildItem -LiteralPath (Join-Path $StagingDir 'emacs\libexec') -Recurse -Filter 'cmdproxy.exe' -File)) {
    & (Join-Path $scriptDir 'set-client-utf8.ps1') -ExePath $proxy.FullName
}
foreach ($name in @('zstd.exe','unzstd.exe')) {
    & (Join-Path $scriptDir 'set-client-utf8.ps1') -ExePath (Join-Path $StagingDir ('deps\zstd\'+$name))
}

# A shortcut's IconLocation only styles the shortcut. Once Emacs is running, the
# taskbar button, Alt-Tab entry and window all use the icon compiled into the
# binary, so those have to be patched too or the Doom icon vanishes the moment
# the user actually launches it.
#
# Runs on every stage, not just a fresh unpack: the payload-level skip in
# .staged.json would otherwise leave a re-staged emacs.exe wearing the stock icon.
$icoSrc = Join-Path (Resolve-Path (Join-Path $scriptDir '..')).Path 'files\doom.ico'

if (Test-Path $icoSrc) {
    $setIcon = Join-Path $scriptDir 'set-exe-icon.ps1'
    $emacsVersion = @($lock.payloads | Where-Object id -eq 'emacs')[0].version
    foreach ($exe in @('emacs\bin\emacs.exe', 'emacs\bin\runemacs.exe', "emacs\bin\emacs-$emacsVersion.exe")) {
        $full = Join-Path $StagingDir $exe
        if (Test-Path $full) {
            try {
                & $setIcon -ExePath $full -IconPath $icoSrc | Out-Null
                Write-Ok "branded $exe"
            } catch {
                Write-Warn "could not brand ${exe}: $($_.Exception.Message)"
            }
        }
    }
} else {
    Write-Warn "no doom.ico at $icoSrc - executables keep the stock Emacs icon"
}

Write-Stage 'Staging layout'
foreach ($d in (Get-ChildItem $StagingDir -Directory -ErrorAction SilentlyContinue)) {
    $sz = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $ct = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host ("    {0,-12} {1,10}  {2,7} files" -f $d.Name, (Format-Size $sz), $ct)
}
$total = (Get-ChildItem $StagingDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Info "total uncompressed: $(Format-Size $total)"

Write-Stage 'Sanity checks'
$checks = @(
    @{ path = 'emacs\bin\emacs.exe';        why = 'the editor' },
    @{ path = 'emacs\bin\runemacs.exe';     why = 'GUI launcher (no console window)' },
    @{ path = 'emacs\bin\libgccjit-0.dll';  why = 'native-comp JIT' },
    @{ path = 'emacs\bin\gcc.exe';          why = 'native-comp driver' },
    @{ path = 'emacs\bin\as.exe';           why = 'native-comp assembler' },
    @{ path = 'emacs\lib\dllcrt2.o';        why = 'native-comp link would fail without it' },
    @{ path = 'deps\rg\rg.exe';             why = 'doom-doctor hard dependency' },
    @{ path = 'deps\fd\fd.exe';             why = 'doom-doctor soft dependency' },
    @{ path = 'deps\git\cmd\git.exe';       why = 'doom-doctor hard dependency' },
    @{ path = 'deps\git\usr\bin\sh.exe';    why = 'lets bin/doom run without Git Bash installed' },
    @{ path = 'deps\git\usr\bin\which.exe'; why = 'Magit Git for Windows executable discovery' },
    @{ path = 'deps\git\usr\bin\cygpath.exe'; why = 'Magit Windows/MSYS path conversion' },
    @{ path = 'deps\git\usr\bin\bash.exe'; why = 'native Bash, not the Windows WSL launcher' },
    @{ path = 'deps\git\usr\bin\gzip.exe'; why = 'compressed files and persistent undo fallback' },
    @{ path = 'deps\zstd\zstd.exe';          why = 'persistent undo .zst files' },
    @{ path = 'deps\xz\bin_x86-64\xz.exe';  why = 'compressed .xz/.lzma files' },
    @{ path = 'deps\7zip\x64\7za.exe';      why = 'Archive mode extraction and updates' },
    @{ path = 'deps\shellcheck\shellcheck.exe'; why = 'default shell diagnostics' },
    @{ path = 'deps\pandoc\pandoc.exe';     why = 'default Markdown preview/export' },
    @{ path = 'fonts\manifest.json';        why = 'font inventory generated from pinned archives' },
    @{ path = 'doom\bin\doom';              why = 'the Doom CLI itself' },
    @{ path = 'doom\lisp\doom.el';          why = 'Doom core' },
    @{ path = 'doom\sources\doom+\modules'; why = 'the module tree (submodule)' },
    @{ path = 'bin\doom.cmd';               why = 'PATH shim - the only thing added to PATH' },
    @{ path = 'bin\doom-emacs.cmd';         why = 'GUI launcher' }
)
$missing = 0
foreach ($c in $checks) {
    $full = Join-Path $StagingDir $c.path
    if (Test-Path $full) {
        Write-Ok ("{0,-30} {1}" -f $c.path, $c.why)
    } else {
        Write-Bad ("{0,-30} MISSING - {1}" -f $c.path, $c.why)
        $missing++
    }
}

if ($failed.Count -gt 0) { Write-Bad "failed to stage: $($failed -join ', ')"; exit 1 }
if ($missing -gt 0)      { Write-Bad "$missing expected file(s) missing from staging"; exit 1 }
Save-DoomStageInventory $StagingDir

Write-Host ''
Write-Ok 'Staging complete and sane.'
exit 0
