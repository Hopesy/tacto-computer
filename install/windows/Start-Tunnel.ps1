param(
    [Parameter(Mandatory = $true)][string]$VpsHost,
    [Parameter(Mandatory = $true)][string]$VpsUser,
    [int]$VpsPort = 22,
    [int]$ReversePort = 22222,
    [int]$LocalSshPort = 22,
    [string]$IdentityFile = "$env:USERPROFILE\.ssh\computer_use_tunnel",
    [string]$KnownHostsFile,
    [string]$InstanceName = 'TactoTunnel',
    [string]$LogDirectory = "$env:LOCALAPPDATA\Tacto\logs"
)
$ErrorActionPreference = 'Stop'
$mutex = [System.Threading.Mutex]::new($false, ('Local\' + $InstanceName))
$acquired = $false
$connection = $null
function Write-TunnelLog([string]$Message) {
    $logFile = Join-Path $LogDirectory 'desktop-tunnel.log'
    if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 1MB) {
        Move-Item -LiteralPath $logFile -Destination "$logFile.1" -Force
    }
    Add-Content -LiteralPath $logFile -Encoding UTF8 -Value "[$([DateTimeOffset]::Now.ToString('o'))] $Message"
}
function Quote-ProcessArgument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}
try {
    try { $acquired = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { exit 0 }
    if (-not (Test-Path -LiteralPath $IdentityFile)) { throw "Missing SSH key: $IdentityFile" }
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $systemSsh = Join-Path "$env:WINDIR\System32\OpenSSH" 'ssh.exe'
    $sshExe = if (Test-Path -LiteralPath $systemSsh) { $systemSsh } else { (Get-Command ssh.exe -ErrorAction Stop).Source }
    $normalizedHost = if ($VpsHost.StartsWith('[') -and $VpsHost.EndsWith(']')) { $VpsHost.Substring(1, $VpsHost.Length - 2) } else { $VpsHost }
    $retrySeconds = 10
    while ($true) {
        $sshArguments = @('-NT', '-p', "$VpsPort", '-i', $IdentityFile,
            '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=10',
            '-o', 'ServerAliveInterval=20', '-o', 'ServerAliveCountMax=3',
            '-R', "127.0.0.1:${ReversePort}:127.0.0.1:${LocalSshPort}")
        if ($KnownHostsFile) { $sshArguments += @('-o', "UserKnownHostsFile=$KnownHostsFile") }
        $sshArguments += "${VpsUser}@${normalizedHost}"
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $sshExe
        $startInfo.Arguments = ($sshArguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $connection = [System.Diagnostics.Process]::new()
        $connection.StartInfo = $startInfo
        $started = [DateTimeOffset]::Now
        $launched = $false
        try {
            $connection.Start() | Out-Null
            $launched = $true
            $outTask = $connection.StandardOutput.ReadLineAsync()
            $errTask = $connection.StandardError.ReadLineAsync()
            Write-TunnelLog "SSH started; PID=$($connection.Id); destination=${VpsUser}@${normalizedHost}:${VpsPort}; reverse=127.0.0.1:${ReversePort}"
            while (-not $connection.WaitForExit(250)) {
                while ($outTask -and $outTask.IsCompleted) {
                    if (-not $outTask.IsFaulted -and -not $outTask.IsCanceled -and $null -ne $outTask.Result) {
                        if ($outTask.Result.Trim()) { Write-TunnelLog ('SSH: ' + $outTask.Result.Trim()) }
                        $outTask = $connection.StandardOutput.ReadLineAsync()
                    } else { $outTask = $null }
                }
                while ($errTask -and $errTask.IsCompleted) {
                    if (-not $errTask.IsFaulted -and -not $errTask.IsCanceled -and $null -ne $errTask.Result) {
                        if ($errTask.Result.Trim()) { Write-TunnelLog ('SSH: ' + $errTask.Result.Trim()) }
                        $errTask = $connection.StandardError.ReadLineAsync()
                    } else { $errTask = $null }
                }
            }
            foreach ($pair in @(@('out',$outTask,$connection.StandardOutput),@('err',$errTask,$connection.StandardError))) {
                $task = $pair[1]; $stream = $pair[2]
                while ($task) {
                    if (-not $task.Wait(500)) { break }
                    if ($null -eq $task.Result) { break }
                    if ($task.Result.Trim()) { Write-TunnelLog ('SSH: ' + $task.Result.Trim()) }
                    $task = $stream.ReadLineAsync()
                }
            }
            Write-TunnelLog "SSH exited; code=$($connection.ExitCode)"
        } catch {
            Write-TunnelLog "SSH error: $($_.Exception.Message)"
        } finally {
            if ($launched -and -not $connection.HasExited) { $connection.Kill() }
            $connection.Dispose()
            $connection = $null
        }
        if (([DateTimeOffset]::Now - $started).TotalSeconds -ge 60) { $retrySeconds = 10 }
        Write-TunnelLog "Reconnecting in $retrySeconds seconds"
        Start-Sleep -Seconds $retrySeconds
        $retrySeconds = [Math]::Min(60, $retrySeconds * 2)
    }
} finally {
    if ($null -ne $connection) {
        if (-not $connection.HasExited) { $connection.Kill() }
        $connection.Dispose()
    }
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
