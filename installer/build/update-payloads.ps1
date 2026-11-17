[CmdletBinding()]
param(
    [ValidateSet('all','emacs','git','ripgrep','fd','fonts','toolchain')][string]$Component='all',
    [string]$Version='latest', [switch]$Check, [string]$LockFile, [string]$CacheDir
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'payload-maintenance.ps1')
if (-not $LockFile) { $LockFile=Join-Path $PSScriptRoot 'payloads.lock.json' }
if (-not $CacheDir) { $CacheDir=Join-Path $PSScriptRoot '..\cache' }
if ($Version -notmatch '^[A-Za-z0-9._-]+$') { throw 'Invalid release version/tag.' }
if ($Component -in @('all','toolchain') -and $Version -ne 'latest') { throw 'Use latest for an entire coherent toolchain/all update.' }
$original=[IO.File]::ReadAllText($LockFile)
$before=$original | ConvertFrom-Json
$candidate=$original | ConvertFrom-Json
$components=if ($Component -eq 'all') { @('emacs','git','ripgrep','fd','fonts','toolchain') } else { @($Component) }
foreach ($item in $components) {
    Write-Host "Checking $item..."
    switch ($item) {
        'emacs' {
            $release=Get-DoomEmacsRelease $Version
            $p=@($candidate.payloads | Where-Object id -eq 'emacs')[0]
            Set-DoomPayload $p $release.version $release.url $release.filename ''
            $p.publishedDigestUrl=$release.url+'.sig'; $p.publishedDigestKind='gpg'
        }
        'toolchain' {
            New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
            $database=Join-Path $CacheDir ('ucrt64-'+[guid]::NewGuid().ToString('N')+'.db')
            & curl.exe --location --fail --silent --show-error --output $database 'https://repo.msys2.org/mingw/ucrt64/ucrt64.db'
            if ($LASTEXITCODE) { throw 'Cannot download the MSYS2 repository snapshot.' }
            $packages=@(Get-DoomMsysToolchain $database)
            $candidate.payloads=@($candidate.payloads | Where-Object { $_.id -notin @('gcc','libgccjit','binutils','crt','winpthreads') -and $_.id -notlike 'ucrt-*' })+$packages
        }
        default {
            $repository=@{git='git-for-windows/git';ripgrep='BurntSushi/ripgrep';fd='sharkdp/fd';fonts='ryanoasis/nerd-fonts'}[$item]
            $tag=$Version
            if ($tag -ne 'latest') {
                if ($item -eq 'git' -and $tag -match '^(\d+\.\d+\.\d+)(?:\.(\d+))?$') {
                    $revision=if ($Matches[2]) { $Matches[2] } else { '1' }; $tag="v$($Matches[1]).windows.$revision"
                } elseif ($item -in @('fd','fonts') -and -not $tag.StartsWith('v')) { $tag='v'+$tag }
            }
            Update-DoomGitHubPayloads $candidate $item (Get-DoomGitHubRelease $repository $tag)
        }
    }
}
$report=foreach ($p in $candidate.payloads) {
    $old=@($before.payloads | Where-Object id -eq $p.id)
    [pscustomobject]@{component=$p.id;pinned=$(if ($old.Count) { $old[0].version } else { '(new dependency)' });available=$p.version}
}
$report | Format-Table -AutoSize
if ($Check) { Write-Host 'Pins were not changed. Use just update COMPONENT to prepare a reviewed update.'; exit 0 }
foreach ($p in $candidate.payloads) {
    $old=@($before.payloads | Where-Object id -eq $p.id)
    if (-not $p.sha256 -or -not $old.Count -or $p.url -ne $old[0].url -or $p.sha256 -ne $old[0].sha256) { Get-DoomPinnedDownload $p $CacheDir }
}
Test-DoomPayloadLock $candidate
if ([IO.File]::ReadAllText($LockFile) -cne $original) { throw 'Lock changed during update; candidate was not applied.' }
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $CacheDir ('pins-before-'+[guid]::NewGuid().ToString('N')+'.json')),$original,(New-Object Text.UTF8Encoding $false))
Write-DoomJson $LockFile $candidate
Write-Host 'Pins updated. Review git diff, then run just build-fast, just test and just test-runtime.'
