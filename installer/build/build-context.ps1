# Shared build inputs. Build directories are disposable workspaces, never installs.
function Get-DoomSha256([string]$Text) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function Write-DoomJson([string]$Path, $Value) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ((ConvertTo-Json -InputObject $Value -Depth 16).Replace("`r`n", "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}
function Test-DoomPayloadLock($Lock) {
    $ids = @{}
    foreach ($p in @($Lock.payloads) + @($Lock.buildTools)) {
        if (-not $p.id -or $ids.ContainsKey($p.id)) { throw "Missing/duplicate payload id: $($p.id)" }
        $ids[$p.id] = $true
        if ($p.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Unpinned SHA256: $($p.id)" }
        if (-not $p.filename -or -not $p.version -or $p.url -notmatch '^https://' -or [IO.Path]::GetFileName($p.filename) -ne $p.filename -or $p.filename -match '[\\/:]|^\.\.?$') { throw "Invalid download location: $($p.id)" }
    }
    foreach ($required in @('emacs','git','git-shell-tools','ripgrep','fd','gcc','libgccjit','binutils','crt','winpthreads','meslo-font','symbols-font','zstd-runtime','xz','7zip','shellcheck','pandoc','nsis','zstd','7zr')) {
        if (-not $ids.ContainsKey($required)) { throw "Missing required component: $required" }
    }
    foreach ($tool in $Lock.buildTools) {
        if (-not $tool.directory -or $tool.directory -match '(^|[/\\])\.\.?($|[/\\])|^[\\/]|:' -or -not $tool.command -or $tool.command -match '[\\/:]|^\.\.?$') { throw "Invalid build-tool destination: $($tool.id)" }
    }
    $git = @($Lock.payloads | Where-Object id -eq 'git')[0]
    $tools = @($Lock.payloads | Where-Object id -eq 'git-shell-tools')[0]
    if ($git.version -ne $tools.version) { throw 'MinGit and PortableGit support tools must use the same release.' }
    $gcc = @($Lock.payloads | Where-Object id -eq 'gcc')[0]
    $jit = @($Lock.payloads | Where-Object id -eq 'libgccjit')[0]
    if ($gcc.version -ne $jit.version) { throw 'GCC and libgccjit must use the same package version.' }
    foreach ($p in $Lock.payloads) {
        if (-not $p.installSubdir -or $p.installSubdir -match '(^|[/\\])\.\.?($|[/\\])|^[\\/]|:') { throw "Invalid payload destination: $($p.id)" }
    }
    foreach ($p in @($Lock.payloads | Where-Object { $_.installSubdir -like 'fonts/*' })) {
        if (-not $p.fontFamily -or -not @($p.files | Where-Object { $_ -like '*.ttf' }).Count) { throw "Font family/files missing: $($p.id)" }
    }
}
function Get-DoomBuildContext {
    param([string]$Repo, [string]$LockFile, [string]$BuildRoot)
    $Repo = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
    if (-not $LockFile) { $LockFile = Join-Path $Repo 'installer\build\payloads.lock.json' }
    $lock = [IO.File]::ReadAllText($LockFile) | ConvertFrom-Json
    Test-DoomPayloadLock $lock
    $tracked = @(& git -C $Repo -c core.quotepath=false ls-files --recurse-submodules)
    if ($LASTEXITCODE) { throw 'Cannot enumerate tracked source files; initialize the module checkout.' }
    $sources = @($tracked | Where-Object { $_ -notmatch '^(installer/|\.github/|justfile$|\.git)' })
    $inputs = @($sources) + @($tracked | Where-Object { $_ -like 'installer/files/*' })
    $hashes = foreach ($relative in ($inputs | Sort-Object -Unique)) {
        $path = Join-Path $Repo $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing tracked input: $relative" }
        "$relative=$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)"
    }
    $lockHash = (Get-FileHash -LiteralPath $LockFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $sourceHash = Get-DoomSha256 ($hashes -join "`n")
    $fingerprint = Get-DoomSha256 ($lockHash + $sourceHash)
    if (-not $BuildRoot) { $BuildRoot = $env:DOOM_BUILD_ROOT }
    if (-not $BuildRoot) { $BuildRoot = Join-Path $env:LOCALAPPDATA 'doom-installer-build' }
    $versionText = [IO.File]::ReadAllText((Join-Path $Repo '.doom'))
    $doomVersion = [regex]::Match($versionText, '"([0-9]+\.[0-9]+\.[0-9]+[^" ]*)"').Groups[1].Value
    if (-not $doomVersion) { throw 'Cannot read the Doom version from .doom.' }
    $release = [IO.File]::ReadAllText((Join-Path $Repo 'installer\build\release.json')) | ConvertFrom-Json
    if ($release.revision -lt 1 -or $release.revision -gt 65535) { throw 'Windows release revision must be between 1 and 65535.' }
    $numbers = [regex]::Match($doomVersion, '^(\d+\.\d+\.\d+)').Value
    return [pscustomobject]@{
        Repo=$Repo; Lock=$lock; LockFile=$LockFile; LockHash=$lockHash; SourceHash=$sourceHash; Fingerprint=$fingerprint
        Sources=$sources; Stage=(Join-Path (Join-Path $BuildRoot ('repo-' + (Get-DoomSha256 $Repo.ToLowerInvariant()).Substring(0,12))) ('staging-' + $fingerprint.Substring(0,16)))
        Version="$doomVersion-win.$($release.revision)"; ProductVersion="$numbers.$($release.revision)"
        EmacsVersion=(@($lock.payloads | Where-Object id -eq 'emacs')[0].version)
    }
}
function Initialize-DoomStage($Context, [string]$Path) {
    $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $marker = Join-Path $Path '.doom-build-stage.json'
    if ($Path -eq $Context.Repo -or $Path.StartsWith($Context.Repo + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Staging must be outside the source checkout.' }
    if (Test-Path -LiteralPath (Join-Path $Path 'install-manifest.json')) { throw 'Refusing to build into an installed Doom tree.' }
    $cursor = $Path
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Redirected build path: $cursor" }
        $cursor = Split-Path -Parent $cursor
    }
    if (Test-Path -LiteralPath $marker) {
        $old = [IO.File]::ReadAllText($marker) | ConvertFrom-Json
        if ($old.schema -ne 1 -or $old.fingerprint -ne $Context.Fingerprint -or $old.repo -ne $Context.Repo) { throw 'Staging belongs to different build inputs. Choose a new directory; the old one was kept.' }
    } elseif ((Test-Path -LiteralPath $Path) -and @(Get-ChildItem -LiteralPath $Path -Force).Count) {
        throw 'Nonempty staging without build ownership metadata. Choose a new directory; nothing was removed.'
    } else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Write-DoomJson $marker @{schema=1;repo=$Context.Repo;fingerprint=$Context.Fingerprint}
    }
    foreach ($name in @('doom\.local','wsl-bridge.json','font-state.json')) {
        if (Test-Path -LiteralPath (Join-Path $Path $name)) { throw "Runtime data found in staging ($name). Use a new build root; data was kept." }
    }
    $inventory=Join-Path $Path '.build-inventory.json'
    if (Test-Path -LiteralPath $inventory) {
        $expected=@(([IO.File]::ReadAllText($inventory) | ConvertFrom-Json).files)
        $actual=@(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Where-Object { $_.FullName -ne $inventory } | ForEach-Object { $_.FullName.Substring($Path.Length+1) })
        if (@(Compare-Object $expected $actual).Count) { throw 'Staging file inventory changed. Use just restage to retain it and create a fresh workspace.' }
    } elseif (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 1) {
        throw 'Incomplete, unsealed staging was kept. Use just restage before retrying.'
    }
}
function Save-DoomStageInventory([string]$Path) {
    $Path=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    $inventory=Join-Path $Path '.build-inventory.json'
    $files=@(Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Where-Object { $_.FullName -ne $inventory } | ForEach-Object { $_.FullName.Substring($Path.Length+1) } | Sort-Object)
    Write-DoomJson $inventory @{schema=1;files=$files}
}
function Retain-DoomStage($Context) {
    $path=[IO.Path]::GetFullPath($Context.Stage).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $path)) { return }
    if (Test-Path -LiteralPath (Join-Path $path 'install-manifest.json')) { throw 'Refusing to rename an installed Doom tree.' }
    if ($path -eq $Context.Repo -or $path.StartsWith($Context.Repo+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to rename a source directory.' }
    $cursor=$path
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Redirected build path: $cursor" }
        $cursor=Split-Path -Parent $cursor
    }
    $marker=Join-Path $path '.doom-build-stage.json'
    if (-not (Test-Path -LiteralPath $marker)) { throw 'Unknown directory: refusing to rename it.' }
    $old=[IO.File]::ReadAllText($marker) | ConvertFrom-Json
    if ($old.schema -ne 1 -or $old.repo -ne $Context.Repo -or $old.fingerprint -ne $Context.Fingerprint) { throw 'Workspace ownership does not match; directory was kept in place.' }
    $name=(Split-Path -Leaf $path)+'.kept-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $destination=[IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $path) $name))
    if ((Split-Path -Parent $destination) -ne (Split-Path -Parent $path)) { throw 'Retention target must be a sibling of staging.' }
    Rename-Item -LiteralPath $path -NewName $name
    Write-Host "Previous workspace retained: $destination"
}
function Get-DoomBuildToolPath([string]$InstallerDir, $Lock, [string]$Id) {
    $tool = @($Lock.buildTools | Where-Object id -eq $Id)[0]
    if (-not $tool) { throw "Build tool is not pinned: $Id" }
    $path = Join-Path (Join-Path $InstallerDir 'build\tools') (Join-Path $tool.directory $tool.command)
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing $Id. Run just bootstrap." }
    return $path
}
