[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InstallRoot, [string]$PackageRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\native-process.ps1')
. (Join-Path $PSScriptRoot '..\files\bridge\environment.ps1')
$InstallRoot=[IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ($PackageRoot -and -not (Test-Path -LiteralPath (Join-Path $PackageRoot 'repos\undo-fu-session\undo-fu-session.el'))) { throw 'PackageRoot must be a synced straight directory containing undo-fu-session.' }
$scratch=Join-Path $env:TEMP ('doom-default-runtime-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$environment=Get-DoomBridgeEnvironment -Root $InstallRoot -DoomDir (Join-Path $scratch 'config')
# Keep only bundled paths and Windows prerequisites. A host Git, Chocolatey
# shim, Python or WSL bash must not make a broken bundle appear to work.
$environment.PATH=(@($environment.PATH -split ';' | Where-Object { $_.StartsWith($InstallRoot+'\',[StringComparison]::OrdinalIgnoreCase) }) + @(
    (Join-Path $env:SystemRoot 'System32'), (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')
)) -join ';'
foreach ($name in @('USERPROFILE','HOME','LOCALAPPDATA','TEMP','TMP')) { $environment[$name]=$scratch }
$environment['DOOM_DEFAULT_TEST']=$scratch
$environment['DOOM_BUNDLE_ROOT']=$InstallRoot
$environment['DOOM_TEST_PACKAGES']=$PackageRoot
$probe=Join-Path $PSScriptRoot 'default-runtime.el'
$result=Invoke-DoomNativeProcess -File (Join-Path $InstallRoot 'emacs\bin\emacs.exe') -Arguments @('-Q','--batch','--init-directory',$scratch,'--load',$probe) -Environment $environment -WorkingDirectory $scratch -TimeoutMilliseconds 180000
if ($result.Output) { Write-Host $result.Output.Trim() }
if ($result.Error) { Write-Host $result.Error.Trim() }
Write-Host "Runtime test artifacts retained: $scratch"
if ($result.ExitCode) { throw "Default runtime checks failed with exit $($result.ExitCode)." }
