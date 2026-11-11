param([ValidateSet('Local','Remote')][string]$TestMode='Remote')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture = Join-Path (Split-Path $PSScriptRoot) ('lifecycle ' + [guid]::NewGuid().ToString('N'))
. "$repo\Setup-Tacto.ps1" -LibraryOnly -Mode $TestMode -VpsHost example.test -VpsUser tester -DeviceName lifecycle-pc -InstallDirectory $fixture
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$Unattended = $true
Assert ((Read-Setting 'device' '' 'default-device') -eq 'default-device') 'Unattended mode failed to use default'
$missingRejected = $false
try { Read-Setting 'required' '' '' } catch { $missingRejected = $true }
Assert $missingRejected 'Unattended mode must report missing required settings'
$script:tasks = @{}
$script:remoteActions = @()
$script:clientIds = @()
function Protect-Directory($Path) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
function Ensure-OpenSsh($Config) {
    $Config.AuthorizedKeysFile = Join-Path $fixture 'authorized_keys'
    if (-not (Test-Path $Config.AuthorizedKeysFile)) { Write-Utf8 $Config.AuthorizedKeysFile "ssh-ed25519 AAAA retained`nssh-ed25519 AQID tacto:lifecycle-pc:another-install`n" }
    $Config.WindowsHostKey = 'ssh-ed25519 AQID host'
}
function Install-Cua($Config) { $Config.DriverPath = Join-Path $fixture 'cua-driver.exe' }
function Invoke-Vps($Config,$RemoteAction,[switch]$Bootstrap) {
    $script:remoteActions += $RemoteAction
    $script:clientIds += $Config.ClientId
    switch ($RemoteAction) {
        'prepare' { [pscustomobject]@{reversePort=22227;windowsKey='ssh-ed25519 AQID callback';mcpName='computer-lifecycle-pc';mcp=@{command='/fixture/cua-proxy';args=@()}} }
        'check' { [pscustomobject]@{status='Cua Driver daemon is running'} }
        'remove' { [pscustomobject]@{removed=$true} }
    }
}
function Get-ScheduledTask($TaskName) { if ($script:tasks.ContainsKey($TaskName)) { $script:tasks[$TaskName] } }
function New-ScheduledTaskTrigger { param([switch]$AtLogOn,$User) @{User=$User} }
function New-ScheduledTaskSettingsSet { param($MultipleInstances,$ExecutionTimeLimit,$RestartCount,$RestartInterval,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries) @{MultipleInstances=$MultipleInstances} }
function New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory) @{Execute=$Execute;Argument=$Argument} }
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) @{UserId=$UserId} }
function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Settings,$Principal,[switch]$Force) $script:tasks[$TaskName]=[pscustomobject]@{State='Ready';Action=$Action} }
function Start-ScheduledTask($TaskName) { $script:tasks[$TaskName].State='Running' }
function Stop-ScheduledTask($TaskName) { $script:tasks[$TaskName].State='Ready' }
function Export-ScheduledTask($TaskName) { '<Task />' }
function Unregister-ScheduledTask { param($TaskName,[switch]$Confirm) $script:tasks.Remove($TaskName) }
function Start-Sleep { param($Seconds) }
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
Assert ($exported.mcpServers.'computer-lifecycle-pc'.args[2] -eq $first.SocketPath) 'Export uses wrong daemon pipe'
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
Uninstall-Desktop
Assert ($script:tasks.Count -eq 0) 'Tasks remain after uninstall'
if ($TestMode -eq 'Remote') { Assert ((Get-Content $first.AuthorizedKeysFile -Raw).Trim() -eq "ssh-ed25519 AAAA retained`r`nssh-ed25519 AQID tacto:lifecycle-pc:another-install") 'Uninstall changed other authorization' }
Assert ((Get-Config).Phase -eq 'uninstalled') 'Uninstall state not saved'
Write-Host ('PASS: ' + $TestMode + ' install/update/check/uninstall; actual launcher compiler; isolated OS/tasks/VPS.')
