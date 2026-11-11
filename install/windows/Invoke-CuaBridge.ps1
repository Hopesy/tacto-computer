param([Parameter(Mandatory=$true)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
switch ($env:SSH_ORIGINAL_COMMAND) {
    'cua-status' { & $config.DriverPath status --socket $config.SocketPath; exit $LASTEXITCODE }
    'cua-mcp' { & $config.DriverPath mcp --socket $config.SocketPath; exit $LASTEXITCODE }
    default { [Console]::Error.WriteLine('Supported commands: cua-status, cua-mcp'); exit 64 }
}
