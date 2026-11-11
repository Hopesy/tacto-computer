$ErrorActionPreference = 'Stop'
$exporter = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'Export-McpConfig.ps1'
$fixture = Join-Path (Split-Path $PSScriptRoot) ('export space-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$driver = Join-Path $fixture "quote's cua-driver.exe"
[IO.File]::WriteAllText($driver, '')
$out = Join-Path $fixture 'mcp.json'
& $exporter -DriverPath $driver -SocketPath '\\.\pipe\fixture' -OutputPath $out
$server = (Get-Content $out -Raw | ConvertFrom-Json).mcpServers.'tacto'
if ($server.command -ne $driver -or $server.args[2] -ne '\\.\pipe\fixture') { throw 'Local export changed command or arguments' }
$refused = $false
try { & $exporter -DriverPath $driver -OutputPath $out } catch { $refused = $true }
if (-not $refused) { throw 'Exporter replaced existing file' }
$proxy = "/home/test user's dir/cua-proxy"
& $exporter -ProxyPath $proxy -OutputPath $out -Force
$server = (Get-Content $out -Raw | ConvertFrom-Json).mcpServers.'tacto'
if ($server.command -ne $proxy -or $server.args.Count -ne 0) { throw 'VPS export invalid' }
& $exporter -SshHost my-vps -ProxyPath $proxy -OutputPath $out -Force
$server = (Get-Content $out -Raw | ConvertFrom-Json).mcpServers.'tacto'
if ($server.command -ne 'ssh' -or $server.args[5] -ne 'my-vps') { throw 'SSH export invalid' }
$expected = "exec '/home/test user'" + [char]34 + "'" + [char]34 + "'s dir/cua-proxy'"
if ($server.args[6] -ne $expected) { throw 'SSH shell quoting invalid' }
Write-Host 'PASS: local, VPS, SSH exports; spaces, quotes and existing-output protection'
