. (Join-Path $PSScriptRoot 'build-context.ps1')

function Get-DoomGitHubRelease([string]$Repository, [string]$Tag='latest') {
    $endpoint = if ($Tag -eq 'latest') { 'latest' } else { 'tags/' + $Tag }
    if (Get-Command gh.exe -ErrorAction SilentlyContinue) {
        $json = @(& gh api "repos/$Repository/releases/$endpoint") -join "`n"
        if ($LASTEXITCODE -eq 0) { return ($json | ConvertFrom-Json) }
    }
    return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/$endpoint" -Headers @{'User-Agent'='DoomEmacsWindowsBuild'}
}
function Set-DoomPayload($Payload, [string]$Version, [string]$Url, [string]$Filename, [string]$Digest, [long]$Size=0) {
    $oldUrl = $Payload.url
    $Payload.version=$Version; $Payload.url=$Url; $Payload.filename=$Filename
    if ($Size -gt 0 -or $oldUrl -ne $Url) { $Payload.expectedBytes=$Size }
    if ($Digest -match '^(?:sha256:)?([a-fA-F0-9]{64})$') { $digestHash=$Matches[1].ToLowerInvariant() }
    else { $digestHash=$null }
    if ($digestHash -or $oldUrl -ne $Url) { $Payload.sha256=$digestHash }
    $Payload.publishedDigestUrl=$null; $Payload.publishedDigestKind=$null
}
function Get-DoomReleaseAsset($Release, [string]$Pattern) {
    $assets=@($Release.assets | Where-Object { $_.name -match $Pattern })
    if ($assets.Count -ne 1) { throw "Expected exactly one release asset matching $Pattern; found $($assets.Count)." }
    return $assets[0]
}
function Update-DoomGitHubPayloads($Lock, [string]$Component, $Release) {
    if ($Release.prerelease -or $Release.draft) { throw 'A draft/prerelease must be reviewed manually before pinning.' }
    switch ($Component) {
        'git' {
            $asset=Get-DoomReleaseAsset $Release '^MinGit-[0-9.]+-64-bit\.zip$'
            $version=[regex]::Match($asset.name,'^MinGit-([0-9.]+)-').Groups[1].Value
            $support=Get-DoomReleaseAsset $Release ('^PortableGit-'+[regex]::Escape($version)+'-64-bit\.7z\.exe$')
            foreach ($pair in @(@('git',$asset),@('git-shell-tools',$support))) {
                $p=@($Lock.payloads | Where-Object id -eq $pair[0])[0]
                Set-DoomPayload $p $version $pair[1].browser_download_url $pair[1].name $pair[1].digest $pair[1].size
            }
        }
        'ripgrep' {
            $a=Get-DoomReleaseAsset $Release '^ripgrep-[0-9.]+-x86_64-pc-windows-msvc\.zip$'
            $p=@($Lock.payloads | Where-Object id -eq 'ripgrep')[0]
            Set-DoomPayload $p $Release.tag_name.TrimStart('v') $a.browser_download_url $a.name $a.digest $a.size
        }
        'fd' {
            $a=Get-DoomReleaseAsset $Release '^fd-v[0-9.]+-x86_64-pc-windows-msvc\.zip$'
            $p=@($Lock.payloads | Where-Object id -eq 'fd')[0]
            Set-DoomPayload $p $Release.tag_name.TrimStart('v') $a.browser_download_url $a.name $a.digest $a.size
        }
        'fonts' {
            $version=$Release.tag_name.TrimStart('v')
            foreach ($spec in @(@('meslo-font','Meslo','Meslo.zip'),@('symbols-font','Symbols','NerdFontsSymbolsOnly.zip'))) {
                $a=Get-DoomReleaseAsset $Release ('^'+[regex]::Escape($spec[2])+'$')
                $p=@($Lock.payloads | Where-Object id -eq $spec[0])[0]
                $cacheName=[IO.Path]::GetFileNameWithoutExtension($a.name)+"-v$version.zip"
                Set-DoomPayload $p $version $a.browser_download_url $cacheName $a.digest $a.size
                $p.installSubdir="fonts/$($spec[1])-v$version"
            }
        }
        { $_ -in @('zstd','xz','7zip','shellcheck','pandoc') } {
            $patterns=@{
                zstd='^zstd-v[0-9.]+-win64\.zip$'; xz='^xz-[0-9.]+-windows\.7z$'
                '7zip'='^7z[0-9]+-extra\.7z$'; shellcheck='^shellcheck-v[0-9.]+\.zip$'
                pandoc='^pandoc-[0-9.]+-windows-x86_64\.zip$'
            }
            $asset=Get-DoomReleaseAsset $Release $patterns[$Component]
            $id=if ($Component -eq 'zstd') { 'zstd-runtime' } else { $Component }
            $payload=@($Lock.payloads | Where-Object id -eq $id)[0]
            Set-DoomPayload $payload $Release.tag_name.TrimStart('v') $asset.browser_download_url $asset.name $asset.digest $asset.size
        }
    }
}
function Get-DoomEmacsRelease([string]$Version='latest') {
    if ($Version -eq 'latest') {
        $index=(Invoke-WebRequest -UseBasicParsing -Uri 'https://ftp.gnu.org/gnu/emacs/windows/').Content
        $majors=@([regex]::Matches($index,'href="emacs-(\d+)/"') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Descending -Unique)
        foreach ($major in $majors) {
            $page=(Invoke-WebRequest -UseBasicParsing -Uri "https://ftp.gnu.org/gnu/emacs/windows/emacs-$major/").Content
            $versions=@([regex]::Matches($page,'emacs-(\d+\.\d+(?:\.\d+)?)-UCRT64\.zip') | ForEach-Object { $_.Groups[1].Value } | Where-Object { ([version]$_).Minor -gt 0 } | Sort-Object { [version]$_ } -Descending -Unique)
            if ($versions.Count) { $Version=$versions[0]; break }
        }
        if ($Version -eq 'latest') { throw 'No stable UCRT64 Emacs archive found at GNU.' }
    }
    if ($Version -notmatch '^\d+\.\d+(?:\.\d+)?$') { throw 'Use an Emacs release number, for example 31.1.' }
    $major=($Version -split '\.')[0]
    return [pscustomobject]@{version=$Version;filename="emacs-$Version-UCRT64.zip";url="https://ftp.gnu.org/gnu/emacs/windows/emacs-$major/emacs-$Version-UCRT64.zip"}
}
function Read-DoomPacmanDescription([string]$Text) {
    $fields=@{}; $key=$null
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^%([A-Z0-9]+)%$') { $key=$Matches[1]; $fields[$key]=@() }
        elseif ($key -and $line) { $fields[$key]+=$line }
    }
    return $fields
}
function Get-DoomMsysToolchain([string]$Database, [scriptblock]$ReadDescription) {
    $prefix='mingw-w64-ucrt-x86_64-'
    $tar=Join-Path $env:SystemRoot 'System32\tar.exe'
    $entries=@(& $tar -tf $Database)
    if ($LASTEXITCODE) { throw 'Cannot read the MSYS2 repository database.' }
    $index=@{}
    foreach ($entry in $entries) { if ($entry -match '^(.+)-[^/-]+-[^/]+/desc$') { $index[$Matches[1]]=$entry } }
    if (-not $ReadDescription) {
        $ReadDescription={ param($Entry) $text=(& $tar -xOf $Database $Entry) -join "`n"; if ($LASTEXITCODE) { throw "Cannot read $Entry" }; Read-DoomPacmanDescription $text }
    }
    $roots=@{libgccjit='libgccjit';gcc='gcc';binutils='binutils';crt='crt';winpthreads='winpthreads'}
    $queue=New-Object 'Collections.Generic.Queue[string]'
    $rootIds=@{}
    foreach ($id in @($roots.Keys | Sort-Object)) {
        $name=$prefix+$roots[$id]
        if (-not $index.ContainsKey($name)) { $name+='-git' }
        if (-not $index.ContainsKey($name)) { throw "Missing native toolchain root: $id" }
        $rootIds[$name]=$id; $queue.Enqueue($name)
    }
    $packages=@{}
    while ($queue.Count) {
        $requirement=$queue.Dequeue()
        $parts=[regex]::Match($requirement,'^([^<>=]+)(?:(=)(.+))?$')
        if (-not $parts.Success) { throw "Unsupported pacman constraint; lock unchanged: $requirement" }
        $name=$parts.Groups[1].Value
        if (-not $name.StartsWith($prefix)) { throw "Non-UCRT dependency requires manual review: $name" }
        if (-not $index.ContainsKey($name)) {
            if ($index.ContainsKey($name+'-git')) { $name+='-git' }
            else { throw "Unresolved MSYS2 dependency: $name" }
        }
        if ($packages.ContainsKey($name)) { $p=$packages[$name] }
        else {
            $p=& $ReadDescription $index[$name]
            if ($p.NAME[0] -ne $name -or $p.SHA256SUM[0] -notmatch '^[a-f0-9]{64}$') { throw "Invalid repository record: $name" }
            $packages[$name]=$p
            foreach ($dependency in @($p.DEPENDS)) { if ($dependency) { $queue.Enqueue($dependency) } }
        }
        if ($parts.Groups[2].Success) {
            $expected=$parts.Groups[3].Value
            $actual=$p.VERSION[0]
            # Pacman dependencies may constrain pkgver without constraining pkgrel.
            if ($expected -notmatch '-[^-]+$') { $actual=$actual -replace '-[^-]+$','' }
            if ($actual -ne $expected) { throw "Inconsistent repository dependency: $requirement" }
        }
    }
    foreach ($name in ($packages.Keys | Sort-Object)) {
        $p=$packages[$name]
        $id=if ($rootIds.ContainsKey($name)) { $rootIds[$name] } else { 'ucrt-'+$name.Substring($prefix.Length) }
        [pscustomobject][ordered]@{
            id=$id;description=($p.DESC -join ' ');version=$p.VERSION[0]
            url=('https://repo.msys2.org/mingw/ucrt64/'+$p.FILENAME[0]);filename=$p.FILENAME[0]
            expectedBytes=[long]$p.CSIZE[0];sha256=$p.SHA256SUM[0]
            publishedDigestUrl='https://repo.msys2.org/mingw/ucrt64/ucrt64.db';publishedDigestKind='msys2-repository'
            stripRoot=$true;installSubdir='emacs'
        }
    }
}
function Get-DoomPinnedDownload($Payload, [string]$CacheDir) {
    if (-not $Payload.filename -or $Payload.filename -match '[\\/:]|^\.\.?$' -or $Payload.url -notmatch '^https://') { throw 'Invalid payload download path/URL.' }
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    $target=Join-Path $CacheDir $Payload.filename
    $temporary=$target+'.download-'+[guid]::NewGuid().ToString('N')
    $source=$target
    if (-not (Test-Path -LiteralPath $target)) {
        & curl.exe --location --fail --silent --show-error --retry 3 --output $temporary $Payload.url
        if ($LASTEXITCODE) { throw "Download failed; pins unchanged: $($Payload.id)" }
        $source=$temporary
    }
    $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Payload.sha256 -and $hash -ne $Payload.sha256) { throw "Hash mismatch; pins unchanged and download kept: $source" }
    if (-not $Payload.sha256) { Write-Warning "Pinning calculated SHA256 for $($Payload.id); publisher signature authentication is not implemented." }
    $Payload.sha256=$hash; $Payload.expectedBytes=(Get-Item -LiteralPath $source).Length
    if ($source -ne $target) { [IO.File]::Move($source,$target) }
}
