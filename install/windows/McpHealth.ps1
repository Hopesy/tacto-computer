function Read-McpResponse($Process, [int]$Id) {
    $deadline = [DateTime]::UtcNow.AddSeconds($(if ($Id -eq 3) { 60 } else { 25 }))
    while ([DateTime]::UtcNow -lt $deadline) {
        $read = $Process.StandardOutput.ReadLineAsync()
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $read.Wait($remaining)) { throw 'MCP response timed out.' }
        if ($null -eq $read.Result) { throw 'MCP process exited before replying.' }
        if (-not $read.Result.Trim()) { continue }
        $message = $read.Result | ConvertFrom-Json
        if ((Property $message 'jsonrpc') -ne '2.0') { throw 'Invalid MCP JSON-RPC response.' }
        if ((Property $message 'method') -and (Property $message 'id')) {
            $Process.StandardInput.WriteLine((@{jsonrpc='2.0';id=$message.id;result=@{}} | ConvertTo-Json -Compress)); continue
        }
        if ((Property $message 'id') -eq $Id) {
            if (Property $message 'error') { throw ('MCP request failed: ' + ($message.error | ConvertTo-Json -Compress)) }
            return $message.result
        }
    }
    throw 'MCP response timed out.'
}
function Send-McpRequest($Process, [int]$Id, [string]$Method, $Params) {
    $Process.StandardInput.WriteLine((@{jsonrpc='2.0';id=$Id;method=$Method;params=$Params} | ConvertTo-Json -Depth 20 -Compress))
    return Read-McpResponse $Process $Id
}
function Invoke-McpHealth($Config, [switch]$CoreOnly) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Config.DriverPath
    $info.Arguments=(@('mcp','--socket',$Config.SocketPath) | ForEach-Object { Quote-Argument $_ }) -join ' '
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info; $started=$false
    try {
        $process.Start() | Out-Null
        $started=$true
        $stderr=$process.StandardError.ReadToEndAsync()
        $hello=Send-McpRequest $process 1 'initialize' @{protocolVersion='2025-06-18';capabilities=@{};clientInfo=@{name='tacto-check';version='1'}}
        if ($hello.protocolVersion -notin @('2024-11-05','2025-03-26','2025-06-18')) { throw 'Unsupported MCP protocol version.' }
        $process.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}')
        $listed=Send-McpRequest $process 2 'tools/list' @{}
        if (@($listed.tools | Where-Object { $_.name -eq 'health_report' }).Count -eq 0) { throw 'This Driver does not advertise health_report. Update the matched runtime.' }
        $arguments=if ($CoreOnly) { @{include=@('binary_version','platform_supported','session_active','screen_capture_capability')} } else { @{} }
        $result=Send-McpRequest $process 3 'tools/call' @{name='health_report';arguments=$arguments}
        if (Property $result 'isError' $false) { throw 'Driver health_report returned an error.' }
        $health=Property $result 'structuredContent'
        if (-not $health -or -not (Property $health 'schema_version')) {
            foreach ($content in $result.content) {
                if ($content.type -eq 'text') { try { $candidate=$content.text | ConvertFrom-Json; if (Property $candidate 'schema_version') { $health=$candidate; break } } catch { } }
            }
        }
        Assert-Health $health
        return $health
    } finally {
        if ($started) {
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(2000)) { $process.Kill(); $process.WaitForExit() }
        }
        $process.Dispose()
    }
}
function Assert-Health($Health) {
    if (-not $Health -or (Property $Health 'schema_version') -ne '1' -or (Property $Health 'platform') -ne 'win32') { throw 'Unexpected health report schema or controlled platform.' }
    foreach ($name in @('binary_version','platform_supported','session_active')) {
        $check=@($Health.checks | Where-Object { $_.name -eq $name })
        if ($check.Count -ne 1 -or $check[0].status -ne 'pass') {
            $detail=if ($check.Count) { $check[0].message + ' ' + (Property $check[0] 'hint' '') } else { 'Missing check' }
            throw "Desktop health failed: $name. $detail"
        }
    }
    if ($Health.overall -notin @('ok','degraded')) { throw ('Desktop health: ' + $Health.overall) }
    if ($Health.overall -eq 'degraded') {
        foreach ($check in @($Health.checks | Where-Object { $_.status -eq 'fail' })) {
            Write-Warning ('Desktop capability degraded: ' + $check.name + '. ' + $check.message + ' ' + (Property $check 'hint' ''))
        }
    }
}
