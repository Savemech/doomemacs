$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\build\payload-maintenance.ps1')
$lockPath=Join-Path $PSScriptRoot '..\build\payloads.lock.json'
$original=[IO.File]::ReadAllText($lockPath)
function New-TestLock { return ($original | ConvertFrom-Json) }
function Assert-Blocked([scriptblock]$Action) {
    $blocked=$false
    try { & $Action } catch { $blocked=$true }
    if (-not $blocked) { throw 'Expected operation to stop.' }
}
$lock=New-TestLock
Test-DoomPayloadLock $lock
$missing=New-TestLock
$missing.payloads=@($missing.payloads | Where-Object id -ne 'git')
Assert-Blocked { Test-DoomPayloadLock $missing }
$badTool=New-TestLock
$badTool.buildTools[0].directory='../outside'
Assert-Blocked { Test-DoomPayloadLock $badTool }
(@($lock.payloads | Where-Object id -eq 'git')[0]).version='different'
Assert-Blocked { Test-DoomPayloadLock $lock }
$lock=New-TestLock
(@($lock.payloads | Where-Object id -eq 'emacs')[0]).installSubdir='../personal-config'
Assert-Blocked { Test-DoomPayloadLock $lock }
$lock=New-TestLock
$release=[pscustomobject]@{tag_name='v99.1';prerelease=$false;draft=$false;assets=@(
    [pscustomobject]@{name='MinGit-99.1-64-bit.zip';browser_download_url='https://example.invalid/MinGit-99.1-64-bit.zip';digest=('sha256:'+('a'*64));size=10},
    [pscustomobject]@{name='PortableGit-99.1-64-bit.7z.exe';browser_download_url='https://example.invalid/PortableGit-99.1-64-bit.7z.exe';digest=('sha256:'+('b'*64));size=20})}
Update-DoomGitHubPayloads $lock git $release
Test-DoomPayloadLock $lock
if (@($lock.payloads | Where-Object { $_.id -in @('git','git-shell-tools') -and $_.version -eq '99.1' }).Count -ne 2) { throw 'Git/tool pairing was not updated together.' }
$release.assets=@($release.assets[0])
Assert-Blocked { Update-DoomGitHubPayloads (New-TestLock) git $release }
$lock=New-TestLock
$fontRelease=[pscustomobject]@{tag_name='v99.2';assets=@(
    [pscustomobject]@{name='Meslo.zip';browser_download_url='https://example.invalid/Meslo.zip';digest=('sha256:'+('c'*64));size=30},
    [pscustomobject]@{name='NerdFontsSymbolsOnly.zip';browser_download_url='https://example.invalid/Symbols.zip';digest=('sha256:'+('d'*64));size=40})}
Update-DoomGitHubPayloads $lock fonts $fontRelease
if (@($lock.payloads | Where-Object { $_.fontFamily -and $_.installSubdir -match 'v99.2$' }).Count -ne 2) { throw 'Font paths retained an old version.' }
Write-Host 'PASS: coupled Git releases, font paths, hashes and path guards.'
$scratch=Join-Path $env:TEMP ('doom-maintenance-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $context=[pscustomobject]@{Repo=(Join-Path $scratch 'repo');Fingerprint=('a'*64)}
    $stage=Join-Path $scratch 'stage'
    $context | Add-Member NoteProperty Stage $stage
    Initialize-DoomStage $context $stage
    Save-DoomStageInventory $stage
    Initialize-DoomStage $context $stage
    [IO.File]::WriteAllText((Join-Path $stage 'unexpected.txt'),'keep')
    Assert-Blocked { Initialize-DoomStage $context $stage }
    Retain-DoomStage $context
    $retained=@(Get-ChildItem -LiteralPath $scratch -Directory -Filter 'stage.kept-*')
    if ($retained.Count -ne 1 -or [IO.File]::ReadAllText((Join-Path $retained[0].FullName 'unexpected.txt')) -ne 'keep') { throw 'Restaging did not retain unexpected files.' }
    Initialize-DoomStage $context $stage
    $changed=[pscustomobject]@{Repo=$context.Repo;Fingerprint=('b'*64)}
    Assert-Blocked { Initialize-DoomStage $changed $stage }
    $data=Join-Path $stage 'doom\.local'
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $data 'precious.txt'),'keep')
    Assert-Blocked { Initialize-DoomStage $context $stage }
    if ([IO.File]::ReadAllText((Join-Path $data 'precious.txt')) -ne 'keep') { throw 'Build guard changed runtime data.' }
    $unknown=Join-Path $scratch 'unknown'
    New-Item -ItemType Directory -Path $unknown | Out-Null
    [IO.File]::WriteAllText((Join-Path $unknown 'personal.txt'),'keep')
    Assert-Blocked { Initialize-DoomStage $context $unknown }
    $unknownContext=[pscustomobject]@{Repo=$context.Repo;Fingerprint=$context.Fingerprint;Stage=$unknown}
    Assert-Blocked { Retain-DoomStage $unknownContext }
    Write-Host 'PASS: changed build inputs, unknown folders and runtime data are preserved.'
    $metadata=Join-Path $scratch 'metadata'
    New-Item -ItemType Directory -Path $metadata | Out-Null
    $names=@()
    foreach ($suffix in @('gcc','libgccjit','binutils','crt','winpthreads','zstd')) {
        $name='mingw-w64-ucrt-x86_64-'+$suffix
        $directory=$name+'-99.1-1'
        $names+=$directory
        $directoryPath=Join-Path $metadata $directory
        New-Item -ItemType Directory -Path $directoryPath | Out-Null
        $deps=if ($suffix -eq 'libgccjit') { "mingw-w64-ucrt-x86_64-gcc=99.1-1`nmingw-w64-ucrt-x86_64-zstd=99.1" } else { '' }
        $text="%FILENAME%`n$name-99.1-1-any.pkg.tar.zst`n`n%NAME%`n$name`n`n%VERSION%`n99.1-1`n`n%SHA256SUM%`n$('a'*64)`n`n%CSIZE%`n123`n`n%DEPENDS%`n$deps`n"
        [IO.File]::WriteAllText((Join-Path $directoryPath 'desc'),$text)
    }
    $database=Join-Path $scratch 'repo.db'
    & "$env:SystemRoot\System32\tar.exe" -cf $database -C $metadata @names
    if ($LASTEXITCODE) { throw 'Cannot create repository fixture.' }
    $packages=@(Get-DoomMsysToolchain $database)
    if ($packages.Count -ne 6 -or @($packages | Where-Object id -eq 'ucrt-zstd').Count -ne 1) { throw 'Dependency closure was incomplete.' }
    $lock=New-TestLock
    $lock.payloads=@($lock.payloads | Where-Object { $_.id -notin @('gcc','libgccjit','binutils','crt','winpthreads') })+$packages
    Test-DoomPayloadLock $lock
    Write-Host 'PASS: native repository snapshot resolves matching compiler/CRT roots and transitive runtime dependencies.'
    $file=Join-Path $scratch 'cache.zip'
    [IO.File]::WriteAllText($file,'preserve corrupt cache for inspection')
    $payload=[pscustomobject]@{id='fixture';filename='cache.zip';url='https://example.invalid/cache.zip';sha256=('0'*64);expectedBytes=0}
    Assert-Blocked { Get-DoomPinnedDownload $payload $scratch }
    if (-not (Test-Path -LiteralPath $file)) { throw 'Checksum failure deleted the cached file.' }
    if ([IO.File]::ReadAllText($lockPath) -cne $original) { throw 'Self-test modified real pins.' }
    Write-Host 'PASS: checksum failures preserve downloads and tests leave real pins unchanged.'
} finally {
    if ((Split-Path -Parent ([IO.Path]::GetFullPath($scratch))) -eq [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')) {
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
