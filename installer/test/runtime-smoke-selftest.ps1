[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$InstallRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\native-process.ps1')
$scratch=Join-Path $env:TEMP ('doom-native-smoke-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$source=Join-Path $scratch 'smoke.el'
$probe=Join-Path $scratch 'probe.el'
[IO.File]::WriteAllText($source,";;; smoke.el -*- lexical-binding: t; -*-`n(defun doom-build-smoke () 42)`n")
[IO.File]::WriteAllText($probe,@'
(unless (native-comp-available-p) (error "Native compiler unavailable"))
(require 'comp)
(let* ((source (getenv "DOOM_SMOKE_SOURCE"))
       (native-comp-eln-load-path (list (getenv "DOOM_SMOKE_CACHE")))
       (output (native-compile source)))
  (unless (and output (file-exists-p output)) (error "No native artifact produced"))
  (load output nil t)
  (unless (= (doom-build-smoke) 42) (error "Compiled function failed"))
  (princ (format "PASS: Emacs %s, native ABI %s, compiled Lisp executes correctly\n" emacs-version comp-native-version-dir)))
'@)
$environment=@{
    USERPROFILE=$scratch;HOME=$scratch;LOCALAPPDATA=$scratch;TEMP=$scratch;TMP=$scratch
    DOOM_SMOKE_SOURCE=$source;DOOM_SMOKE_CACHE=(Join-Path $scratch 'eln')
    PATH=((Join-Path $InstallRoot 'emacs\bin')+';'+$env:SystemRoot+'\System32')
}
$result=Invoke-DoomNativeProcess -File (Join-Path $InstallRoot 'emacs\bin\emacs.exe') -Arguments @('-Q','--batch','--init-directory',$scratch,'--load',$probe) -Environment $environment -WorkingDirectory $scratch -TimeoutMilliseconds 120000
if ($result.Output) { Write-Host $result.Output.Trim() }
if ($result.ExitCode) { throw "Native compiler smoke failed; artifacts kept at $scratch`n$($result.Error)" }
Write-Host "Native smoke artifacts retained at $scratch"
