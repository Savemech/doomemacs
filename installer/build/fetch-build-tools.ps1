[CmdletBinding()]
param([string]$LockFile, [string]$CacheDir)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'build-context.ps1')
if (-not $LockFile) { $LockFile = Join-Path $PSScriptRoot 'payloads.lock.json' }
if (-not $CacheDir) { $CacheDir = Join-Path $PSScriptRoot '..\cache' }
$lock = [IO.File]::ReadAllText($LockFile) | ConvertFrom-Json
Test-DoomPayloadLock $lock
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($tool in $lock.buildTools) {
    $archive = Join-Path $CacheDir $tool.filename
    $old = Join-Path (Join-Path $PSScriptRoot 'tools') $tool.filename
    if (-not (Test-Path -LiteralPath $archive) -and (Test-Path -LiteralPath $old) -and (Get-FileHash -LiteralPath $old).Hash -eq $tool.sha256) { Copy-Item -LiteralPath $old -Destination $archive }
    if (-not (Test-Path -LiteralPath $archive)) {
        & curl.exe --location --fail --silent --show-error --retry 3 --output $archive $tool.url
        if ($LASTEXITCODE) { throw "Download failed: $($tool.id)" }
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $tool.sha256) { throw "Build-tool hash mismatch; cached file kept for inspection: $archive" }
    $destination = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot 'tools') $tool.directory))
    $toolsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'tools')).TrimEnd('\')
    if (-not $destination.StartsWith($toolsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Build-tool path escapes tools directory.' }
    $marker = Join-Path $destination '.archive.sha256'
    if ((Test-Path -LiteralPath $marker) -and ([IO.File]::ReadAllText($marker)).Trim() -eq $tool.sha256 -and (Test-Path -LiteralPath (Join-Path $destination $tool.command))) {
        Write-Host "Verified build tool: $($tool.id) $($tool.version)"
        continue
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    if ($tool.filename -like '*.zip') {
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $entries = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
            if ($tool.extractMember) {
                $entries = @($entries | Where-Object { $_.FullName -like $tool.extractMember })
                if ($entries.Count -ne 1) { throw "Ambiguous build-tool member: $($tool.id)" }
            }
            foreach ($entry in $entries) {
                $relative = $entry.FullName
                if ($tool.extractMember) { $relative = $tool.command }
                elseif ($tool.stripRoot) { $relative = ($relative -split '/', 2)[1] }
                $target = [IO.Path]::GetFullPath((Join-Path $destination $relative))
                if (-not $target.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive member escapes tool directory.' }
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        } finally { $zip.Dispose() }
    } else { Copy-Item -LiteralPath $archive -Destination (Join-Path $destination $tool.command) -Force }
    if (-not (Test-Path -LiteralPath (Join-Path $destination $tool.command))) { throw "Missing extracted tool: $($tool.id)" }
    [IO.File]::WriteAllText($marker, $tool.sha256)
    Write-Host "Ready: $($tool.id) $($tool.version)"
}
