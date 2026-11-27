$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exporter = Join-Path $repo 'install/windows/Export-McpConfig.ps1'
$fixture = Join-Path (Join-Path $repo '.Tacto-temp') ('export space-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$driver = Join-Path $fixture "quote's cua-driver.exe"
[IO.File]::WriteAllText($driver, '')
$out = Join-Path $fixture 'mcp.json'
& $exporter -DriverPath $driver -SocketPath '\\.\pipe\fixture' -OutputPath $out
$server = (Get-Content $out -Raw | ConvertFrom-Json).mcpServers.'tacto-mcp'
if ($server.command -ne $driver -or $server.args[2] -ne '\\.\pipe\fixture') { throw 'Local export changed command or arguments' }
$refused = $false
try { & $exporter -DriverPath $driver -OutputPath $out } catch { $refused = $true }
if (-not $refused) { throw 'Exporter replaced existing file' }
$proxy = "/home/test user's dir/cua-proxy"
& $exporter -ProxyPath $proxy -OutputPath $out -Force
$server = (Get-Content $out -Raw | ConvertFrom-Json).mcpServers.'tacto-mcp'
if ($server.command -ne $proxy -or $server.args.Count -ne 0) { throw 'VPS export invalid' }
& $exporter -SshHost my-vps -ProxyPath $proxy -OutputPath $out -Force
$server = (Get-Content $out -Raw | ConvertFrom-Json).mcpServers.'tacto-mcp'
if ($server.command -ne 'ssh' -or $server.args[5] -ne 'my-vps') { throw 'SSH export invalid' }
$expected = "exec '/home/test user'" + [char]34 + "'" + [char]34 + "'s dir/cua-proxy'"
if ($server.args[6] -ne $expected) { throw 'SSH shell quoting invalid' }
& $exporter -SshHost 'agent@[2001:db8::1]' -ProxyPath $proxy -OutputPath $out -Force
$ipv6Server = (Get-Content $out -Raw | ConvertFrom-Json).mcpServers.'tacto-mcp'
if ($ipv6Server.args[5] -ne 'agent@2001:db8::1') { throw 'IPv6 SSH export invalid' }
[IO.File]::WriteAllText((Join-Path $fixture 'desktop.json'), '{"Phase":"complete"}')
[IO.File]::WriteAllText((Join-Path $fixture 'Invoke-CuaBridge.ps1'), '# bridge fixture')
& $exporter -InstallDirectory $fixture -Name 'tacto-office' -OutputPath $out -Force
$bridgeServer = (Get-Content $out -Raw | ConvertFrom-Json).mcpServers.'tacto-office'
if (-not ($bridgeServer.args -contains (Join-Path $fixture 'Invoke-CuaBridge.ps1')) -or -not $bridgeServer.env.PSModulePath) { throw 'Bridge export invalid' }
Write-Host 'PASS: local, bridge, VPS, SSH exports; IPv6, spaces, quotes and existing-output protection'
