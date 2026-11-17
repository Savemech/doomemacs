[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('doctor','versions','init','upstream-fetch','upstream-merge','pin-modules','bump-release','release-check','restage','test','test-runtime','test-defaults','test-wsl','verify','artifacts')][string]$Task,
    [string]$Ref='origin/master', [string]$Distribution, [string]$PackageRoot
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$installer=Join-Path $repo 'installer'
. (Join-Path $PSScriptRoot 'build-context.ps1')
function Invoke-MaintenanceGit([string[]]$Arguments) {
    $output=@(& git -C $repo @Arguments)
    if ($LASTEXITCODE) { throw "Git failed: $($Arguments -join ' ')" }
    return $output
}
function Test-ModuleWorktree {
    $module=Join-Path $repo 'sources\doom+'
    if (Test-Path -LiteralPath (Join-Path $module '.git')) {
        $changes=@(& git -C $module status --porcelain)
        if ($LASTEXITCODE -or $changes.Count) { throw 'Module checkout has changes; preserve them before updating.' }
    }
}
function Invoke-Check([string]$Name, [string[]]$Arguments=@()) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installer ("test\$Name.ps1")) @Arguments
    if ($LASTEXITCODE) { throw "Check failed: $Name" }
}
function Get-FullSevenZip {
    $command=Get-Command 7z.exe -ErrorAction SilentlyContinue
    $path=if ($command) { $command.Source } else { Join-Path $env:ProgramFiles '7-Zip\7z.exe' }
    if (-not (Test-Path -LiteralPath $path)) { throw 'Full 7-Zip is required to verify NSIS archives; 7zr supports only 7z archives.' }
    return $path
}
switch ($Task) {
    'release-check' {
        if (@(Invoke-MaintenanceGit @('status','--porcelain')).Count) { throw 'Commit reviewed changes before building a release; use just build-fast for a working tree.' }
        [void](Get-FullSevenZip)
        return
    }
    'init' {
        Test-ModuleWorktree
        Invoke-MaintenanceGit @('submodule','update','--init','sources/doom+')
        return
    }
    'upstream-fetch' { Invoke-MaintenanceGit @('fetch','origin'); return }
    'upstream-merge' {
        if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { throw 'Use an explicit branch or tag ref.' }
        if (@(Invoke-MaintenanceGit @('status','--porcelain')).Count) { throw 'Commit or preserve working-tree changes before merging upstream.' }
        if (-not (Invoke-MaintenanceGit @('branch','--show-current'))) { throw 'Check out your maintenance branch first.' }
        Test-ModuleWorktree
        [void](Invoke-MaintenanceGit @('rev-parse','--verify',"$Ref^{commit}"))
        $backup='backup/windows-'+(Get-Date).ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
        Invoke-MaintenanceGit @('branch',$backup)
        Write-Host "Previous HEAD retained at $backup"
        Invoke-MaintenanceGit @('merge','--no-edit','--',$Ref)
        Invoke-MaintenanceGit @('submodule','update','--init','sources/doom+')
        Write-Host 'Review the merge, then run just pin-modules and just doctor.'
        return
    }
    'pin-modules' {
        $line=(Invoke-MaintenanceGit @('ls-tree','HEAD','sources/doom+')) -join ''
        if ($line -notmatch '^160000 commit ([a-f0-9]{40})\s') { throw 'Module gitlink not found in HEAD.' }
        $pin=$Matches[1]
        $path=Join-Path $PSScriptRoot 'payloads.lock.json'
        $lock=[IO.File]::ReadAllText($path) | ConvertFrom-Json
        $lock.doom.submodule.sha=$pin
        Write-DoomJson $path $lock
        Write-Host "Pinned module gitlink: $pin"
        return
    }
    'bump-release' {
        $path=Join-Path $PSScriptRoot 'release.json'
        $release=[IO.File]::ReadAllText($path) | ConvertFrom-Json
        $release.revision=[int]$release.revision+1
        if ($release.revision -gt 65535) { throw 'Windows revision exceeds the PE version field.' }
        Write-DoomJson $path $release
        Write-Host "Windows build revision: $($release.revision)"
        return
    }
    'test' {
        $lock=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'payloads.lock.json')) | ConvertFrom-Json
        $actionlint=Get-DoomBuildToolPath $installer $lock 'actionlint'
        $workflows=@(Get-ChildItem -LiteralPath (Join-Path $repo '.github\workflows') -File -Filter '*.yml' | ForEach-Object { $_.FullName })
        & $actionlint @workflows
        if ($LASTEXITCODE) { throw 'GitHub Actions workflow validation failed.' }
        $issues=@()
        Get-ChildItem -LiteralPath $installer -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notlike '*\test\results\*' } | ForEach-Object {
            $tokens=$null; $errors=$null
            [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$errors)
            $issues+=@($errors)
        }
        if ($issues.Count) { throw ($issues | Out-String) }
        foreach ($name in @('maintenance-selftest','env-path-selftest','install-guard-selftest','uninstall-plan-selftest','diff-selftest','wsl-bridge-selftest','wsl-selection-selftest','package-sync-selftest','font-integration-selftest')) { Invoke-Check $name }
        Invoke-Check 'snapshot' @('-SelfTest')
        Invoke-Check 'installer-selftest' @('-MakeNsis',(Get-DoomBuildToolPath $installer $lock 'nsis'))
        return
    }
}
$context=Get-DoomBuildContext -Repo $repo
switch ($Task) {
    'restage' {
        Retain-DoomStage $context
        & (Join-Path $PSScriptRoot 'build-installer.ps1') -Stages stage
        if ($LASTEXITCODE) { throw 'Restaging failed; previous workspace was retained.' }
    }
    'versions' {
        $context.Lock.payloads | Select-Object id,version | Format-Table -AutoSize
        Write-Host "Installer: $($context.Version)"
        Write-Host "Staging: $($context.Stage)"
    }
    'doctor' {
        if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'Windows 10 or later is required.' }
        foreach ($tool in @('git.exe','curl.exe','powershell.exe','tar.exe')) { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing command: $tool" } }
        foreach ($tool in $context.Lock.buildTools) { Write-Host (Get-DoomBuildToolPath $installer $context.Lock $tool.id) }
        $revision=(& git -C (Join-Path $repo 'sources\doom+') rev-parse HEAD)
        if ($LASTEXITCODE -or $revision -ne $context.Lock.doom.submodule.sha) { throw 'Module revision and lock differ. Run just init / just pin-modules as appropriate.' }
        $gitlink=(Invoke-MaintenanceGit @('ls-tree','HEAD','sources/doom+')) -join ''
        if ($gitlink -notmatch ('^160000 commit '+[regex]::Escape($revision)+'\s')) { throw 'Module checkout and committed gitlink differ. Run just init after reviewing the module pin.' }
        Write-Host "Pins and prerequisites OK. Staging: $($context.Stage)"
    }
    'test-runtime' {
        Initialize-DoomStage $context $context.Stage
        Invoke-Check 'runtime-smoke-selftest' @('-InstallRoot',$context.Stage)
        Invoke-Check 'git-tools-selftest' @('-InstallRoot',$context.Stage)
        Invoke-Check 'default-runtime-selftest' @('-InstallRoot',$context.Stage)
        Invoke-Check 'windows-client-selftest' @('-EmacsRoot',(Join-Path $context.Stage 'emacs'))
    }
    'test-defaults' {
        Initialize-DoomStage $context $context.Stage
        $arguments=@('-InstallRoot',$context.Stage)
        if ($PackageRoot) { $arguments+=@('-PackageRoot',$PackageRoot) }
        Invoke-Check 'default-runtime-selftest' $arguments
    }
    'test-wsl' {
        if (-not $Distribution) { throw 'Choose a WSL distribution: just test-wsl Ubuntu' }
        Initialize-DoomStage $context $context.Stage
        $copy=Join-Path (Split-Path -Parent $context.Stage) ('wsl-test-'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $copy | Out-Null
        foreach ($name in @('emacs','deps','doom','bin','bridge','native-process.ps1','wsl-integration.ps1')) { Copy-Item -LiteralPath (Join-Path $context.Stage $name) -Destination $copy -Recurse }
        Write-Host "Isolated runtime copy retained for inspection: $copy"
        Invoke-Check 'wsl-bridge-selftest' @('-Distribution',$Distribution)
        Invoke-Check 'windows-client-selftest' @('-EmacsRoot',(Join-Path $context.Stage 'emacs'),'-Distribution',$Distribution)
        Invoke-Check 'wsl-cli-selftest' @('-InstallRoot',$copy,'-Distribution',$Distribution)
    }
    'verify' {
        $file=Join-Path $installer ("dist\DoomEmacs-$($context.Version)-x86_64-setup.exe")
        $sevenZip=Get-FullSevenZip
        & $sevenZip t $file
        if ($LASTEXITCODE) { throw 'Installer archive integrity check failed.' }
    }
    'artifacts' {
        Get-ChildItem -LiteralPath (Join-Path $installer 'dist') -File -Filter '*.exe' | ForEach-Object {
            Write-Host "$($_.FullName)`nSHA256 $((Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant())"
        }
    }
}
