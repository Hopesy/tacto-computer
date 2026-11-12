$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$folder=Join-Path $repo ('.Tacto-temp\skill-' + [guid]::NewGuid().ToString('N'))
$install=Join-Path $folder 'install'
. (Join-Path $repo 'install\windows\Setup-Tacto.ps1') -LibraryOnly -InstallDirectory $install -NoSkills
New-Item -ItemType Directory -Force $install | Out-Null
function Assert($Value,$Message) { if (-not $Value) { throw $Message } }
$config=[pscustomobject]@{RuntimePath=$repo;DeviceName='skill-test';BrowserMode='isolated';SkillDirectory=(Join-Path $folder 'skills');McpConfig=(Join-Path $folder 'agent.json')}
$server=@{command='test';args=@()}
Install-TargetSkill $config
Set-AgentIntegration $config $server
Assert ($config.Integration.files.Count -eq 14) 'Official files not recorded'
$official=Join-Path $config.SkillDirectory 'tacto-skill-test\official\WINDOWS.md'
Assert ((Get-FileHash $official).Hash -eq (Get-FileHash (Join-Path $repo 'resources\cua-skill\WINDOWS.md')).Hash) 'Official bytes changed'
# Upgrade the old single-file integration receipt.
Remove-AgentIntegration $config
$skill=Join-Path $config.SkillDirectory 'tacto-skill-test\SKILL.md'
New-Item -ItemType Directory -Force (Split-Path $skill) | Out-Null
Write-Utf8 $skill 'legacy skill'
Set-Property $config 'Integration' ([pscustomobject]@{name='computer-skill-test';configPath=$config.McpConfig;server=$server;skillPath=$skill;skillHash=(Get-TextHash 'legacy skill')})
Set-AgentIntegration $config $server
Assert ($config.Integration.files.Count -eq 14) 'Legacy receipt did not migrate'
Write-Utf8 $official 'user extension'
$before=Get-Content -LiteralPath $config.McpConfig -Raw
$refused=$false
try { Set-AgentIntegration $config $server } catch { $refused=$true }
Assert $refused 'Edited reference overwritten'
Assert ((Get-Content -LiteralPath $config.McpConfig -Raw) -eq $before) 'Conflict changed the MCP config'
Remove-AgentIntegration $config
Assert ((Get-Content -LiteralPath $official -Raw) -eq 'user extension') 'Edited official reference lost'
Assert (-not (Test-Path $skill)) 'Owned adapter retained'
Assert (-not (Test-Path (Join-Path (Split-Path $official) 'RUNTIME.md'))) 'Unedited official reference retained'
# CLI idle leases participate in maintenance without referring to a dead process.
New-Item -ItemType Directory -Force (Join-Path $install 'cli-sessions') | Out-Null
$lease=Join-Path $install 'cli-sessions\named.json'
Write-AtomicJson $lease @{kind='cli-session';expires=[DateTime]::UtcNow.AddMinutes(5).ToString('o')}
Assert (@(Get-ActiveConnections).Count -eq 1) 'Named CLI session ignored'
$refused=$false
try { Assert-Idle } catch { $refused=$true }
Assert $refused 'Busy CLI session allowed update'
Write-AtomicJson $lease @{kind='cli-session';expires=[DateTime]::UtcNow.AddMinutes(-1).ToString('o')}
Assert (@(Get-ActiveConnections).Count -eq 0) 'Expired CLI session blocks update'
Write-Host 'PASS: official files, legacy migration, edited references and CLI idle leases'
# Full Skill payloads travel over stdin, preserving UTF-8 beyond the command-line limit.
$echo=Join-Path $folder 'echo.py'
Write-Utf8 $echo 'import json,sys; data=json.load(sys.stdin); print(json.dumps({"size":len(data["text"]),"prefix":data["text"][:2]}))'
$inputText=@{text=('中文' + ('x' * 100000))} | ConvertTo-Json -Compress
$result=Invoke-ProcessResult 'python.exe' @('-X','utf8',$echo) -InputText $inputText
Assert ($result.Code -eq 0) 'Large stdin process failed'
$response=$result.Output | ConvertFrom-Json
Assert ($response.size -eq 100002 -and $response.prefix -eq '中文') 'Large UTF-8 stdin changed'
$realProcess=${function:Invoke-ProcessResult}
function Invoke-ProcessResult($Executable,$Arguments,[switch]$Interactive,[string]$InputText) {
    Assert ($Arguments[-1] -eq 'tacto-stdin-v2') 'Management body leaked into command arguments'
    Assert ($InputText.Length -gt 29000) 'Expected a full official Skill payload'
    $request=$InputText | ConvertFrom-Json
    Assert ($request.skillFiles.'official/WINDOWS.md') 'Official reference missing from remote request'
    return @{Code=0;Output='TACTO_SETUP_JSON={"ok":true,"result":{"configured":true}}'}
}
Set-Property $config 'Remote' ([pscustomobject]@{managementVersion=2})
foreach ($pair in @(@('ClientId','fixture'),@('VpsHost','example.test'),@('VpsUser','fixture'),@('VpsPort',22),@('KnownHostsFile',(Join-Path $folder 'known')), @('TunnelKey',(Join-Path $folder 'key')))) { Set-Property $config $pair[0] $pair[1] }
Assert (Invoke-Vps $config 'configure').configured 'Managed Skill request failed'
${function:Invoke-ProcessResult}=$realProcess
Write-Host 'PASS: bounded management framing and large UTF-8 stdin'
