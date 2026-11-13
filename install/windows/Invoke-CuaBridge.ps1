param([Parameter(Mandatory=$true)][string]$ConfigPath, [switch]$Local, [switch]$Cli)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -eq 'Desktop') { $env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules') }
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$command=if ($Local) { if ($Cli) { 'cua-cli' } else { 'cua-mcp' } } else { $env:SSH_ORIGINAL_COMMAND }
$root=Split-Path $ConfigPath
$lease=$null
function Quote-DriverArgument([string]$Value) { '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"' }
function Save-CliSession($Request) {
    if ($Request.command -ne 'call' -or -not $Request.args.PSObject.Properties['session']) { return }
    $session=[string]$Request.args.session
    if (-not $session -or $session -eq 'default') { return }
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($session)))).Replace('-','').ToLower() } finally { $sha.Dispose() }
    $folder=Join-Path $root 'cli-sessions'; $path=Join-Path $folder ($key + '.json')
    if ($Request.tool -eq 'end_session') { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }; return }
    New-Item -ItemType Directory -Force $folder | Out-Null
    $temp=$path + '.' + [guid]::NewGuid().ToString('N') + '.new'
    [IO.File]::WriteAllText($temp,(@{kind='cli-session';session=$session;expires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp,$path,[NullString]::Value) } else { [IO.File]::Move($temp,$path) }
}
try {
    switch ($command) {
        'cua-status' { & $config.DriverPath status --socket $config.SocketPath --pid-file (Join-Path $root 'cua.pid'); exit $LASTEXITCODE }
        { $_ -in @('cua-mcp','cua-health','cua-cli') } {
            if ($config.Phase -notin @('complete','connecting')) { throw 'Tacto is under maintenance. Reconnect after update or repair.' }
            $folder=Join-Path $root 'connections'
            New-Item -ItemType Directory -Force $folder | Out-Null
            $lease=Join-Path $folder ([guid]::NewGuid().ToString('N') + '.json')
            $process=Get-Process -Id $PID
            [IO.File]::WriteAllText(($lease + '.new'),(@{pid=$PID;started=$process.StartTime.ToUniversalTime().Ticks.ToString()} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
            [IO.File]::Move(($lease + '.new'),$lease)
            $config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($config.Phase -notin @('complete','connecting')) { throw 'Tacto is under maintenance.' }
            if ((Test-Path -LiteralPath (Join-Path $root 'transaction.json')) -and $command -ne 'cua-health') { throw 'Tacto is switching versions. Reconnect shortly.' }
            $info=[Diagnostics.ProcessStartInfo]::new()
            $info.FileName=$config.DriverPath
            $info.Arguments='mcp --socket "' + $config.SocketPath + '"'
            $request=$null; $toolInput=$null
            if ($command -eq 'cua-cli') {
                $reader=[IO.StreamReader]::new([Console]::OpenStandardInput(),[Text.Encoding]::UTF8)
                $request=$reader.ReadToEnd() | ConvertFrom-Json
                if ($request.command -notin @('call','list-tools','describe','doctor','status','version')) { throw 'Unsupported Driver CLI command.' }
                if ($request.command -in @('call','describe') -and $request.tool -notmatch '^[a-z][a-z0-9_]*$') { throw 'Invalid tool name.' }
                $driverArgs=switch ($request.command) {
                    'call' { if ($request.args -isnot [pscustomobject]) { throw 'Tool arguments must be a JSON object.' }; $toolInput=$request.args | ConvertTo-Json -Depth 100 -Compress; @('call',$request.tool,'--socket',$config.SocketPath) }
                    'describe' { @('describe',$request.tool) }
                    'list-tools' { @('list-tools') }
                    'version' { @('--version') }
                    'status' { @('status','--socket',$config.SocketPath,'--pid-file',(Join-Path $root 'cua.pid')) }
                    'doctor' { @('doctor','--json','--socket',$config.SocketPath) }
                }
                $info.Arguments=($driverArgs | ForEach-Object { Quote-DriverArgument $_ }) -join ' '
            }
            $info.UseShellExecute=$false; $info.CreateNoWindow=$true
            $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
            $child=[Diagnostics.Process]::new(); $child.StartInfo=$info; $started=$false
            try {
                $child.Start() | Out-Null
                $started=$true
                # Copy raw streams. PowerShell's native pipeline buffers MCP input/output.
                Add-Type -TypeDefinition @'
using System.IO;
using System.Threading.Tasks;
public static class TactoStream {
    public static async Task Copy(Stream source, Stream target) {
        byte[] bytes=new byte[8192];
        int count;
        while ((count=await source.ReadAsync(bytes,0,bytes.Length).ConfigureAwait(false))>0) {
            await target.WriteAsync(bytes,0,count).ConfigureAwait(false);
            await target.FlushAsync().ConfigureAwait(false);
        }
    }
}
'@
                $inputCopy=$null
                if ($command -eq 'cua-cli') {
                    if ($toolInput) { $bytes=[Text.Encoding]::UTF8.GetBytes($toolInput); $child.StandardInput.BaseStream.Write($bytes,0,$bytes.Length); $child.StandardInput.BaseStream.Flush() }
                    $child.StandardInput.BaseStream.Close()
                } else { $inputCopy=[TactoStream]::Copy([Console]::OpenStandardInput(),$child.StandardInput.BaseStream) }
                $outputCopy=[TactoStream]::Copy($child.StandardOutput.BaseStream,[Console]::OpenStandardOutput())
                $errorCopy=[TactoStream]::Copy($child.StandardError.BaseStream,[Console]::OpenStandardError())
                $inputClosed=$false
                while (-not $child.WaitForExit(100)) {
                    if ($inputCopy -and $inputCopy.IsCompleted -and -not $inputClosed) { $child.StandardInput.BaseStream.Close(); $inputClosed=$true }
                }
                $outputCopy.Wait(); $errorCopy.Wait()
                $code=$child.ExitCode
                if ($code -eq 0 -and $request) { Save-CliSession $request }
            } finally {
                if ($started -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
                $child.Dispose()
            }
            exit $code
        }
        default { throw 'Supported commands: cua-status, cua-mcp, cua-cli. Update Tacto on the controlled PC for CLI access.' }
    }
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
finally { if ($lease -and (Test-Path -LiteralPath $lease)) { Remove-Item -LiteralPath $lease -Force -ErrorAction SilentlyContinue } }
