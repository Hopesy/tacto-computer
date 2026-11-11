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
    $sshExe = (Get-Command ssh.exe -ErrorAction Stop).Source
    $retrySeconds = 10
    while ($true) {
        $sshArguments = @('-NT', '-p', "$VpsPort", '-i', $IdentityFile,
            '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=10',
            '-o', 'ServerAliveInterval=20', '-o', 'ServerAliveCountMax=3',
            '-R', "127.0.0.1:${ReversePort}:127.0.0.1:${LocalSshPort}")
        if ($KnownHostsFile) { $sshArguments += @('-o', "UserKnownHostsFile=$KnownHostsFile") }
        $sshArguments += "${VpsUser}@${VpsHost}"
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
            $stdout = $connection.StandardOutput.ReadToEndAsync()
            $stderr = $connection.StandardError.ReadToEndAsync()
            Write-TunnelLog "SSH started; PID=$($connection.Id); destination=${VpsUser}@${VpsHost}:${VpsPort}; reverse=127.0.0.1:${ReversePort}"
            while (-not $connection.WaitForExit(1000)) { }
            $detail = ($stderr.Result + $stdout.Result).Trim()
            if ($detail.Length -gt 4096) { $detail = $detail.Substring($detail.Length - 4096) }
            Write-TunnelLog "SSH exited; code=$($connection.ExitCode); $detail"
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
