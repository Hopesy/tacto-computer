param([Parameter(Mandatory=$true)][string]$ConfigPath, [switch]$Local)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$command=if ($Local) { 'cua-mcp' } else { $env:SSH_ORIGINAL_COMMAND }
$root=Split-Path $ConfigPath
$lease=$null
try {
    switch ($command) {
        'cua-status' { & $config.DriverPath status --socket $config.SocketPath --pid-file (Join-Path $root 'cua.pid'); exit $LASTEXITCODE }
        { $_ -in @('cua-mcp','cua-health') } {
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
                $inputCopy=[TactoStream]::Copy([Console]::OpenStandardInput(),$child.StandardInput.BaseStream)
                $outputCopy=[TactoStream]::Copy($child.StandardOutput.BaseStream,[Console]::OpenStandardOutput())
                $errorCopy=[TactoStream]::Copy($child.StandardError.BaseStream,[Console]::OpenStandardError())
                $inputClosed=$false
                while (-not $child.WaitForExit(100)) {
                    if ($inputCopy.IsCompleted -and -not $inputClosed) { $child.StandardInput.Close(); $inputClosed=$true }
                }
                $outputCopy.Wait(); $errorCopy.Wait()
                $code=$child.ExitCode
            } finally {
                if ($started -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
                $child.Dispose()
            }
            exit $code
        }
        default { throw 'Supported commands: cua-status, cua-mcp' }
    }
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
finally { if ($lease -and (Test-Path -LiteralPath $lease)) { Remove-Item -LiteralPath $lease -Force -ErrorAction SilentlyContinue } }
