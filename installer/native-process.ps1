# ProcessStartInfo.ArgumentList is unavailable in Windows PowerShell 5.1.
# Quote arguments using the Windows argv rules, without invoking cmd.exe.
function ConvertTo-DoomNativeArgument([AllowEmptyString()][string]$Argument) {
    if ($Argument -and $Argument -notmatch '[\s"]') { return $Argument }
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Start-DoomNativeProcess([Diagnostics.ProcessStartInfo]$Info) {
    # .NET Framework has no StandardInputEncoding. Its redirected StreamWriter
    # autoflushes a BOM during Start when Console.InputEncoding includes one.
    $encoding = [Console]::InputEncoding
    try {
        if ($encoding.CodePage -eq 65001) { [Console]::InputEncoding = New-Object Text.UTF8Encoding $false }
        return [Diagnostics.Process]::Start($Info)
    } finally { [Console]::InputEncoding = $encoding }
}

function Invoke-DoomNativeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$Arguments = @(),
        [string]$InputText,
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [Text.Encoding]$OutputEncoding = [Text.Encoding]::UTF8,
        [int]$TimeoutMilliseconds = 60000
    )
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-DoomNativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $OutputEncoding
    $info.StandardErrorEncoding = $OutputEncoding
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    foreach ($name in $Environment.Keys) {
        if ($null -eq $Environment[$name]) { $info.EnvironmentVariables.Remove($name) }
        else { $info.EnvironmentVariables[$name] = [string]$Environment[$name] }
    }
    $process = Start-DoomNativeProcess $info
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $inputStream = $process.StandardInput.BaseStream
        if ($InputText) {
            # Write UTF-8 bytes directly: the framework's stdin StreamWriter
            # inherits the console encoding and may prepend a BOM on Close().
            $inputBytes = [Text.Encoding]::UTF8.GetBytes($InputText)
            $write = $inputStream.WriteAsync($inputBytes, 0, $inputBytes.Length)
            if ($TimeoutMilliseconds -eq 0) { $write.GetAwaiter().GetResult() }
            elseif (-not $write.Wait($TimeoutMilliseconds)) {
                $process.Kill()
                throw "Process stopped accepting input: $File"
            }
        }
        $inputStream.Close()
        if ($TimeoutMilliseconds -eq 0) { $process.WaitForExit() }
        elseif (-not $process.WaitForExit([math]::Max(1, $TimeoutMilliseconds - [int]$timer.ElapsedMilliseconds))) {
            $process.Kill()
            throw "Process timed out: $File. Check that the WSL distribution and its disk are accessible."
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdout.GetAwaiter().GetResult()
            Error = $stderr.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}
