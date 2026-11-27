param([Parameter(Mandatory=$true)][string]$ConfigPath, [switch]$Local, [switch]$Cli, [switch]$Health)
$ErrorActionPreference='Stop'
if ($PSVersionTable.PSEdition -eq 'Desktop') { $env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules') }
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$config=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$command=if ($Local) { if ($Cli) { 'cua-cli' } elseif ($Health) { 'cua-health' } else { 'cua-mcp' } } else { $env:SSH_ORIGINAL_COMMAND }
$root=Split-Path $ConfigPath
$lease=$null
function Quote-DriverArgument([string]$Value) { '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"' }
function Update-SessionLease([string]$Session, [bool]$Remove) {
    if (-not $Session -or $Session -eq 'default') { return }
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Session)))).Replace('-','').ToLower() } finally { $sha.Dispose() }
    $folder=Join-Path $root 'cli-sessions'; $path=Join-Path $folder ($key + '.json')
    if ($Remove) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }; return }
    New-Item -ItemType Directory -Force $folder | Out-Null
    $temp=$path + '.' + [guid]::NewGuid().ToString('N') + '.new'
    [IO.File]::WriteAllText($temp,(@{kind='cli-session';session=$Session;expires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temp,$path,[NullString]::Value) } else { [IO.File]::Move($temp,$path) }
}
function Save-CliSession($Request, [string]$ResponseText) {
    if ($Request.command -ne 'call' -or -not $Request.args) { return }
    $isError=$false
    if ($ResponseText) {
        try {
            $parsed=$ResponseText | ConvertFrom-Json
            if ($parsed -and $parsed.PSObject.Properties['isError'] -and [bool]$parsed.isError) { $isError=$true }
        } catch { }
    }
    $states=@{}
    $topSession=if ($Request.args.PSObject.Properties['session']) { [string]$Request.args.session } else { '' }
    if ($topSession -and $topSession -ne 'default') {
        $states[$topSession]=($Request.tool -eq 'end_session' -and -not $isError)
    }
    if ($Request.tool -eq 'run_steps' -and $Request.args.PSObject.Properties['steps'] -and $Request.args.steps -is [Array]) {
        foreach ($step in $Request.args.steps) {
            if (-not $step) { continue }
            $stepSession=if ($step.PSObject.Properties['args'] -and $step.args -and $step.args.PSObject.Properties['session']) { [string]$step.args.session } else { $topSession }
            if (-not $stepSession -or $stepSession -eq 'default') { continue }
            $stepTool=if ($step.PSObject.Properties['tool']) { [string]$step.tool } else { '' }
            $states[$stepSession]=($stepTool -eq 'end_session' -and -not $isError)
        }
    }
    foreach ($entry in $states.GetEnumerator()) { Update-SessionLease $entry.Key ([bool]$entry.Value) }
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
            $info.Arguments=(@('mcp','--socket',$config.SocketPath) | ForEach-Object { Quote-DriverArgument $_ }) -join ' '
            $request=$null; $toolInput=$null
            if ($command -eq 'cua-cli') {
                $stdin=[Console]::OpenStandardInput()
                $ms=[IO.MemoryStream]::new()
                try {
                    $buf=New-Object byte[] 8192
                    while (($count=$stdin.Read($buf,0,$buf.Length)) -gt 0) {
                        if ($ms.Length + $count -gt 8388608) { throw 'Tool input exceeds 8 MiB.' }
                        $ms.Write($buf,0,$count)
                    }
                    $rawRequest=[Text.Encoding]::UTF8.GetString($ms.ToArray())
                } finally { $ms.Dispose() }
                $request=$rawRequest | ConvertFrom-Json
                if ($request.command -notin @('call','list-tools','describe','doctor','status','version')) { throw 'Unsupported Driver CLI command.' }
                $blockedTools=@('stop','serve','revoke','config','telemetry','recording','update','check-update','diagnose','permissions','autostart','skills','manifest','extension','perception','channel','cursor','sessions','history','connect','test','mcp')
                if ($request.command -in @('call','describe') -and ($request.tool -in $blockedTools -or $request.tool -notmatch '^[a-z][a-z0-9_]*$')) { throw 'Invalid tool name.' }
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
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
public static class TactoStream {
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters {
        public ulong ReadOperations, WriteOperations, OtherOperations;
        public ulong ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits limits, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);

    public static IntPtr BindKillOnCloseJob(IntPtr process) {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return IntPtr.Zero;
        var limits = new ExtendedLimits();
        limits.Basic.Flags = 0x2000;
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(limits)) || !AssignProcessToJobObject(job, process)) {
            CloseHandle(job);
            return IntPtr.Zero;
        }
        return job;
    }
    public static async Task Copy(Stream source, Stream target, MemoryStream capture = null, int maxCapture = 2097152) {
        byte[] bytes=new byte[8192];
        int count;
        while ((count=await source.ReadAsync(bytes,0,bytes.Length).ConfigureAwait(false))>0) {
            if (capture != null && capture.Length < maxCapture) {
                int take = Math.Min(count, maxCapture - (int)capture.Length);
                if (take > 0) capture.Write(bytes, 0, take);
            }
            await target.WriteAsync(bytes,0,count).ConfigureAwait(false);
            await target.FlushAsync().ConfigureAwait(false);
        }
    }
}
'@
            $child=[Diagnostics.Process]::new(); $child.StartInfo=$info; $started=$false; $job=[IntPtr]::Zero
            $capture=if ($command -eq 'cua-cli') { [IO.MemoryStream]::new() } else { $null }
            try {
                $child.Start() | Out-Null
                $started=$true
                $job=[TactoStream]::BindKillOnCloseJob($child.Handle)
                $inputCopy=$null
                if ($command -eq 'cua-cli') {
                    if ($toolInput) { $bytes=[Text.Encoding]::UTF8.GetBytes($toolInput); $child.StandardInput.BaseStream.Write($bytes,0,$bytes.Length); $child.StandardInput.BaseStream.Flush() }
                    $child.StandardInput.BaseStream.Close()
                } else { $inputCopy=[TactoStream]::Copy([Console]::OpenStandardInput(),$child.StandardInput.BaseStream,$null,0) }
                $outputCopy=[TactoStream]::Copy($child.StandardOutput.BaseStream,[Console]::OpenStandardOutput(),$capture,2097152)
                $errorCopy=[TactoStream]::Copy($child.StandardError.BaseStream,[Console]::OpenStandardError(),$null,0)
                $inputClosed=$false
                $eofDeadline=[DateTime]::MaxValue
                while (-not $child.WaitForExit(100)) {
                    if ($inputCopy -and $inputCopy.IsCompleted -and -not $inputClosed) {
                        $child.StandardInput.BaseStream.Close()
                        $inputClosed=$true
                        $eofDeadline=[DateTime]::UtcNow.AddSeconds(10)
                    }
                    if ($inputClosed -and [DateTime]::UtcNow -ge $eofDeadline) {
                        $child.Kill()
                        $child.WaitForExit()
                        break
                    }
                }
                [Threading.Tasks.Task]::WaitAll(@($outputCopy,$errorCopy),2000) | Out-Null
                $code=$child.ExitCode
                if ($code -eq 0 -and $request) {
                    $capturedText=if ($capture -and $capture.Length -gt 0 -and $capture.Length -lt 2097152) { [Text.Encoding]::UTF8.GetString($capture.ToArray()) } else { '' }
                    Save-CliSession $request $capturedText
                }
            } finally {
                if ($capture) { $capture.Dispose() }
                if ($started -and -not $child.HasExited) { $child.Kill(); $child.WaitForExit() }
                if ($job -ne [IntPtr]::Zero) { [TactoStream]::CloseHandle($job) | Out-Null }
                $child.Dispose()
            }
            exit $code
        }
        default { throw 'Supported commands: cua-status, cua-mcp, cua-cli. Update Tacto on the controlled PC for CLI access.' }
    }
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
finally { if ($lease -and (Test-Path -LiteralPath $lease)) { Remove-Item -LiteralPath $lease -Force -ErrorAction SilentlyContinue } }
