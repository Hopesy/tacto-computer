param([ValidateSet('Local','Remote')][string]$TestMode='Remote')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fixture = Join-Path (Join-Path $repo '.Tacto-temp') ('lifecycle ' + [guid]::NewGuid().ToString('N'))
. "$repo\install\windows\Setup-Tacto.ps1" -LibraryOnly -NoSkills -Mode $TestMode -VpsHost example.test -VpsUser tester -DeviceName lifecycle-pc -InstallDirectory $fixture
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$Unattended = $true
Assert ((Read-Setting 'device' '' 'default-device') -eq 'default-device') 'Unattended mode failed to use default'
$missingRejected = $false
try { Read-Setting 'required' '' '' } catch { $missingRejected = $true }
Assert $missingRejected 'Unattended mode must report missing required settings'
$script:tasks = @{}
$script:remoteActions = @()
$script:clientIds = @()
$script:healthFails=$false
$script:offline=$false
$env:LOCALAPPDATA=Join-Path (Split-Path $fixture) ('receipt-' + [guid]::NewGuid().ToString('N'))
function Register-Uninstaller($Config) { }
function Restore-OpenSshSettings($Config) { }
function Invoke-McpHealth($Config) {
    if ($script:healthFails -and $Config.RuntimePath -ne $script:healthyRuntime) { throw 'Injected health failure' }
    [pscustomobject]@{schema_version='1';platform='win32';driver_version='0.46.1';overall='ok';checks=@('binary_version','platform_supported','session_active','ax_capability','screen_capture_capability') | ForEach-Object { [pscustomobject]@{name=$_;status='pass';message='fixture'} }}
}
function Protect-Directory($Path) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
function Ensure-OpenSsh($Config) {
    $Config.AuthorizedKeysFile = Join-Path $fixture 'authorized_keys'
    if (-not (Test-Path $Config.AuthorizedKeysFile)) { Write-Utf8 $Config.AuthorizedKeysFile "ssh-ed25519 AAAA retained`nssh-ed25519 AQID tacto:lifecycle-pc:another-install`n" }
    $Config.WindowsHostKey = 'ssh-ed25519 AQID host'
}
function Install-Cua($Config) { $Config.DriverPath = Join-Path $fixture 'cua-driver.exe' }
function Invoke-Vps($Config,$RemoteAction,[switch]$Bootstrap) {
    if ($script:offline) { throw 'Injected VPS offline' }; $script:remoteActions += $RemoteAction
    $script:clientIds += $Config.ClientId
    switch ($RemoteAction) {
        'prepare' { [pscustomobject]@{managementVersion=2;reversePort=22227;windowsKey='ssh-ed25519 AQID callback';mcpName='computer-lifecycle-pc';mcp=@{command='/fixture/cua-proxy';args=@()}} }
        'check' { [pscustomobject]@{status='MCP healthy';health=(Invoke-McpHealth $Config)} }
        'remove' { [pscustomobject]@{removed=$true} }
    }
}
function Get-ScheduledTask($TaskName) { if ($script:tasks.ContainsKey($TaskName)) { $script:tasks[$TaskName] } }
function New-ScheduledTaskTrigger { param([switch]$AtLogOn,$User,[switch]$Daily,$At,$RandomDelay) @{User=$User} }
function New-ScheduledTaskSettingsSet { param($MultipleInstances,$ExecutionTimeLimit,$RestartCount,$RestartInterval,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$StartWhenAvailable,[switch]$RunOnlyIfNetworkAvailable) @{MultipleInstances=$MultipleInstances} }
function New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory) @{Execute=$Execute;Argument=$Argument} }
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) @{UserId=$UserId} }
function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Settings,$Principal,$Xml,[switch]$Force) $script:tasks[$TaskName]=[pscustomobject]@{State='Ready';Action=$Action} }
function Start-ScheduledTask($TaskName) { $script:tasks[$TaskName].State='Running' }
function Stop-ScheduledTask($TaskName) { $script:tasks[$TaskName].State='Ready' }
function Export-ScheduledTask($TaskName) { '<Task />' }
function Unregister-ScheduledTask { param($TaskName,[switch]$Confirm) $script:tasks.Remove($TaskName) }
function Start-Sleep { param($Seconds,$Milliseconds) }
$native = ${function:Invoke-Native}
function Invoke-Native($Executable,$Arguments) {
    if ($Executable -eq 'icacls.exe' -or $Executable.EndsWith('cua-driver.exe')) { return }
    & $native $Executable $Arguments
}
$realProcess = ${function:Invoke-ProcessResult}
function Invoke-ProcessResult($Executable,$Arguments) {
    if ($Executable.EndsWith('cua-driver.exe')) { return @{Code=0;Output='Cua Driver daemon is running'} }
    & $realProcess $Executable $Arguments
}
Install-Desktop
$first = Get-Config
Assert ($first.Phase -eq 'complete') 'Initial install incomplete'
if ($TestMode -eq 'Remote') { Assert (Test-Path (Join-Path $fixture 'keys\tunnel.pub')) 'Real SSH key generation failed' }
Assert (Test-Path (Join-Path $fixture 'mcp-local.json')) 'Local MCP config missing'
$exported = Get-Content (Join-Path $fixture 'mcp-local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert ($exported.mcpServers.'computer-lifecycle-pc'.args -contains $script:ConfigPath) 'Export must use stable installation bridge'
Assert ($first.SocketPath -ne '\\.\pipe\cua-driver') 'Install reused global pipe'
if ($TestMode -eq 'Remote') { Assert (Test-Path (Join-Path $fixture 'mcp-vps.json')) 'VPS MCP config missing' }
Install-Desktop
Assert ((Get-Config).ClientId -eq $first.ClientId) 'Update changed installation identity'
Assert ((Get-Config).SocketPath -eq $first.SocketPath) 'Update changed daemon pipe'
Assert ($script:tasks.Count -eq $(if ($TestMode -eq 'Local') { 1 } else { 2 })) 'Wrong task count after update'
if ($TestMode -eq 'Remote') {
    Assert (@((Get-Content $first.AuthorizedKeysFile) | Where-Object { $_.EndsWith(':' + $first.ClientId) }).Count -eq 1) 'Duplicate callback authorization'
    Assert ($script:tasks[$first.TunnelTask].Action.Argument.Contains($first.TunnelTask)) 'Tunnel mutex must use installation identity'
}
else { Assert ($script:remoteActions.Count -eq 0) 'Local mode contacted VPS'; Assert (-not (Test-Path (Join-Path $fixture 'authorized_keys'))) 'Local mode configured SSH' }
$AutoUpdate='on'
Install-Desktop
Assert ($script:tasks.ContainsKey('Tacto-Update-' + $first.ClientId)) 'Opt-in updater task missing'
$AutoUpdate='off'
Install-Desktop
Assert (-not $script:tasks.ContainsKey('Tacto-Update-' + $first.ClientId)) 'Disabled updater task remains'
$beforeFailure=Get-Config
$script:healthyRuntime=$beforeFailure.RuntimePath
$script:healthFails=$true
$rejected=$false
try { Install-Desktop } catch { $rejected=$true }
Assert $rejected 'Health failure must reject activation'
Assert ((Get-Config).RuntimePath -eq $beforeFailure.RuntimePath) 'Failed upgrade did not restore old runtime'
Assert ((Get-Config).Phase -eq 'complete') 'Rollback left the install incomplete'
Assert (-not (Test-Path (Join-Path $fixture 'transaction.json'))) 'Completed recovery left a journal'
$script:healthFails=$false
Check-Desktop (Get-Config)
Invoke-Rollback
Assert ((Get-Config).ClientId -eq $first.ClientId) 'Manual rollback changed identity'
$current=Get-Config
$legacy=$current | ConvertTo-Json -Depth 32 | ConvertFrom-Json
$legacy.PSObject.Properties.Remove('RuntimePath')
$legacy.PSObject.Properties.Remove('AutoUpdate')
Save-Config $legacy
Install-Desktop
Invoke-Rollback
Assert (-not (Property (Get-Config) 'RuntimePath')) 'Manual legacy rollback did not restore saved configuration/tasks'
Install-Desktop
$current=Get-Config
Start-Transaction $current $current
$broken=$current | ConvertTo-Json -Depth 32 | ConvertFrom-Json
$broken.Phase='connecting'; Save-Config $broken
Restore-Transaction
Assert ((Get-Config).Phase -eq 'complete') 'Interrupted switch recovery failed'
New-Item -ItemType Directory -Force (Join-Path $fixture 'connections') | Out-Null
$lease=Join-Path $fixture 'connections\active.json'
Write-AtomicJson $lease @{pid=$PID;started=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()}
$rejected=$false
try { Install-Desktop } catch { $rejected=$true }
Assert $rejected 'Update interrupted an active MCP connection'
Remove-Item -LiteralPath $lease
$KeepConfig=$true
Uninstall-Desktop
Assert ((Get-Config).Phase -eq 'uninstalled') 'Retained config phase is incorrect'
$KeepConfig=$false
Install-Desktop
if ($TestMode -eq 'Remote') {
    Assert (@((Get-Content (Get-Config).AuthorizedKeysFile) | Where-Object { $_.EndsWith(':' + $first.ClientId) }).Count -eq 1) 'Reinstall did not restore callback authorization'
}
$script:offline=($TestMode -eq 'Remote')
Uninstall-Desktop
Assert ($script:tasks.Count -eq 0) 'Tasks remain after uninstall'
if ($TestMode -eq 'Remote') { Assert ((Get-Content $first.AuthorizedKeysFile -Raw).Trim() -eq "ssh-ed25519 AAAA retained`r`nssh-ed25519 AQID tacto:lifecycle-pc:another-install") 'Uninstall changed other authorization' }
Assert (-not (Test-Path $script:ConfigPath)) 'Full uninstall left installation config'
Assert (-not (Test-Path (Join-Path $fixture 'keys'))) 'Full uninstall left private keys'
if ($TestMode -eq 'Remote') { Assert ($null -ne $script:PendingRemote) 'Offline uninstall lost cleanup receipt' }
Write-Host ('PASS: ' + $TestMode + ' install/update/check/uninstall; actual launcher compiler; isolated OS/tasks/VPS.')
