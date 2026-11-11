[CmdletBinding(DefaultParameterSetName='Local')]
param(
    [Parameter(Mandatory=$true,ParameterSetName='Local')][string]$DriverPath,
    [Parameter(ParameterSetName='Local')][string]$SocketPath = '\\.\pipe\cua-driver',
    [Parameter(Mandatory=$true,ParameterSetName='Vps')]
    [Parameter(Mandatory=$true,ParameterSetName='Ssh')][string]$ProxyPath,
    [Parameter(Mandatory=$true,ParameterSetName='Ssh')][string]$SshHost,
    [Parameter(ParameterSetName='Ssh')][string]$SshConfig,
    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$Name = 'tacto',
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if ((Test-Path -LiteralPath $OutputPath) -and -not $Force) { throw '输出文件已存在；请指定新文件名，或使用 -Force 覆盖这个导出文件。' }
switch ($PSCmdlet.ParameterSetName) {
    'Local' {
        $driver = (Resolve-Path -LiteralPath $DriverPath).Path
        $server = @{ command=$driver; args=@('mcp','--socket',$SocketPath) }
    }
    'Vps' {
        if (-not $ProxyPath.StartsWith('/') -or $ProxyPath -match '[\r\n\x00]') { throw '代理路径应为 VPS 上的绝对路径。' }
        $server = @{ command=$ProxyPath; args=@() }
    }
    'Ssh' {
        if ($SshHost -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.@:-]*$') { throw 'SSH 目标应为已配置的主机别名，或 user@hostname。' }
        if (-not $ProxyPath.StartsWith('/') -or $ProxyPath -match '[\r\n\x00]') { throw '代理路径应为 VPS 上的绝对路径。' }
        $sshArgs = @('-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes')
        if ($SshConfig) { $sshArgs += @('-F',(Resolve-Path -LiteralPath $SshConfig).Path) }
        $quoteEscape = "'" + [char]34 + "'" + [char]34 + "'"
        $quoted = "'" + $ProxyPath.Replace("'", $quoteEscape) + "'"
        $sshArgs += @($SshHost,('exec ' + $quoted))
        $server = @{ command='ssh'; args=$sshArgs }
    }
}
$path = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null
[IO.File]::WriteAllText($path, (@{ mcpServers=@{ $Name=$server } } | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
Write-Host $path
