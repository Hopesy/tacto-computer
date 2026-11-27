[CmdletBinding(DefaultParameterSetName='Bridge')]
param(
    [Parameter(ParameterSetName='Bridge')][string]$InstallDirectory = "$env:LOCALAPPDATA\Tacto",
    [Parameter(Mandatory=$true,ParameterSetName='Local')][string]$DriverPath,
    [Parameter(ParameterSetName='Local')][string]$SocketPath = '\\.\pipe\cua-driver',
    [Parameter(Mandatory=$true,ParameterSetName='Vps')]
    [Parameter(Mandatory=$true,ParameterSetName='Ssh')][string]$ProxyPath,
    [Parameter(Mandatory=$true,ParameterSetName='Ssh')][string]$SshHost,
    [Parameter(ParameterSetName='Ssh')][string]$SshConfig,
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$Name = 'tacto-mcp',
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) { throw '输出文件已存在；请指定新文件名，或使用 -Force 覆盖这个导出文件。' }
switch ($PSCmdlet.ParameterSetName) {
    'Bridge' {
        $root = [IO.Path]::GetFullPath($InstallDirectory)
        $configPath = Join-Path $root 'desktop.json'
        $bridgePath = Join-Path $root 'Invoke-CuaBridge.ps1'
        if (-not (Test-Path -LiteralPath $configPath) -or -not (Test-Path -LiteralPath $bridgePath)) {
            throw "未找到受管安装桥接入口：$root"
        }
        $powershell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        $server = @{
            command=$powershell
            args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$bridgePath,'-ConfigPath',$configPath,'-Local')
            env=@{PSModulePath=([IO.Path]::Combine((Split-Path $powershell),'Modules'))}
        }
    }
    'Local' {
        $driver = (Resolve-Path -LiteralPath $DriverPath).Path
        $server = @{ command=$driver; args=@('mcp','--socket',$SocketPath) }
    }
    'Vps' {
        if (-not $ProxyPath.StartsWith('/') -or $ProxyPath -match '[\r\n\x00]') { throw '代理路径应为 VPS 上的绝对路径。' }
        $server = @{ command=$ProxyPath; args=@() }
    }
    'Ssh' {
        if ($SshHost.StartsWith('-') -or $SshHost -match '[\s\x00]') { throw 'SSH 目标应为已配置的主机别名，或 user@hostname。' }
        $normalizedSsh = $SshHost
        if ($SshHost.Contains('@')) {
            $parts = $SshHost.Split('@', 2)
            $bareHost = if ($parts[1].StartsWith('[') -and $parts[1].EndsWith(']')) { $parts[1].Substring(1, $parts[1].Length - 2) } else { $parts[1] }
            $ip = $null
            if ($parts[0] -notmatch '^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$' -or (-not [Net.IPAddress]::TryParse($bareHost, [ref]$ip) -and $parts[1] -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$')) {
                throw 'SSH 目标应为已配置的主机别名，或 user@hostname。'
            }
            $normalizedSsh = $parts[0] + '@' + $bareHost
        } elseif ($SshHost -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$') {
            $bareHost = if ($SshHost.StartsWith('[') -and $SshHost.EndsWith(']')) { $SshHost.Substring(1, $SshHost.Length - 2) } else { $SshHost }
            $ip = $null
            if (-not [Net.IPAddress]::TryParse($bareHost, [ref]$ip)) { throw 'SSH 目标应为已配置的主机别名，或 user@hostname。' }
            $normalizedSsh = $bareHost
        }
        if (-not $ProxyPath.StartsWith('/') -or $ProxyPath -match '[\r\n\x00]') { throw '代理路径应为 VPS 上的绝对路径。' }
        $sshArgs = @('-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes')
        if ($SshConfig) { $sshArgs += @('-F',(Resolve-Path -LiteralPath $SshConfig).Path) }
        $quoteEscape = "'" + [char]34 + "'" + [char]34 + "'"
        $quoted = "'" + $ProxyPath.Replace("'", $quoteEscape) + "'"
        $sshArgs += @($normalizedSsh,('exec ' + $quoted))
        $server = @{ command='ssh'; args=$sshArgs }
    }
}
$path = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
[IO.File]::WriteAllText($path, (@{ mcpServers=@{ $Name=$server } } | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Write-Host $path
