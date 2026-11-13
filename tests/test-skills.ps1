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
$target=Join-Path $config.SkillDirectory 'tacto-computer'
$official=Join-Path $target 'references\WINDOWS.md'
$bundle=[IO.File]::ReadAllText((Join-Path $repo 'install\skill-references.json')) | ConvertFrom-Json
foreach ($entry in $bundle.PSObject.Properties) {
    Assert ([IO.File]::ReadAllText((Join-Path $target $entry.Name)) -ceq $entry.Value) 'Windows references differ from the shared bundle'
}
Assert (@(Get-ChildItem -LiteralPath $target -Filter SKILL.md -Recurse).Count -eq 1) 'Expected one discoverable device Skill'
# Exercise the old runtime layout in both directions, including the private export.
$legacy=Join-Path $folder 'legacy-runtime'
New-Item -ItemType Directory -Force $legacy | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'resources') -Destination $legacy -Recurse
Write-Utf8 (Join-Path $legacy 'package.json') '{"name":"tacto-mcp"}'
$template=Join-Path $legacy 'resources\tacto-skill.md'
Write-Utf8 $template ([IO.File]::ReadAllText($template).Replace('{{SKILL}}','tacto-{{DEVICE}}').Replace('references/CUA.md','official/SKILL.md').Replace('references/','official/'))
$config.RuntimePath=$legacy
Install-TargetSkill $config
Set-AgentIntegration $config $server
$legacyTarget=Join-Path $config.SkillDirectory 'tacto-skill-test'
Assert (Test-Path (Join-Path $legacyTarget 'official\SKILL.md')) 'Previous runtime layout was not restored'
Assert (-not (Test-Path $target)) 'New Skill directory survived rollback'
Assert ((Get-Content $config.McpConfig -Raw | ConvertFrom-Json).mcpServers.'computer-skill-test') 'Previous MCP name was not restored'
$config.RuntimePath=$repo
Install-TargetSkill $config
Set-AgentIntegration $config $server
Assert (-not (Test-Path $legacyTarget)) 'Legacy nested Skill survived migration'
Assert ((Get-Content $config.McpConfig -Raw | ConvertFrom-Json).mcpServers.'tacto-mcp') 'MCP name was not migrated'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $install 'skill') -Filter SKILL.md -Recurse).Count -eq 1) 'Private export contains a nested Skill'
# Upgrade the old single-file integration receipt.
Remove-AgentIntegration $config
$skill=Join-Path $config.SkillDirectory 'tacto-skill-test\SKILL.md'
New-Item -ItemType Directory -Force (Split-Path $skill) | Out-Null
Write-Utf8 $skill 'legacy skill'
Set-Property $config 'Integration' ([pscustomobject]@{name='computer-skill-test';configPath=$config.McpConfig;server=$server;skillPath=$skill;skillHash=(Get-TextHash 'legacy skill')})
Set-AgentIntegration $config $server
Assert ($config.Integration.files.Count -eq 14) 'Legacy receipt did not migrate'
$skill=Join-Path $target 'SKILL.md'
Assert ([IO.File]::ReadAllText($skill).Contains('name: tacto-computer')) 'Skill name did not migrate'
Assert ([IO.File]::ReadAllText($skill).Contains('--package tacto-computer@latest tacto-cli')) 'CLI prefix did not migrate'
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
    Assert ($request.skillFiles.'references/CUA.md') 'CUA reference missing from remote request'
    Assert ($request.skillFiles.'references/WINDOWS.md') 'Windows reference missing from remote request'
    return @{Code=0;Output='TACTO_SETUP_JSON={"ok":true,"result":{"configured":true}}'}
}
Set-Property $config 'Remote' ([pscustomobject]@{managementVersion=3})
foreach ($pair in @(@('ClientId','fixture'),@('VpsHost','example.test'),@('VpsUser','fixture'),@('VpsPort',22),@('KnownHostsFile',(Join-Path $folder 'known')), @('TunnelKey',(Join-Path $folder 'key')))) { Set-Property $config $pair[0] $pair[1] }
Assert (Invoke-Vps $config 'configure').configured 'Managed Skill request failed'
${function:Invoke-ProcessResult}=$realProcess
Write-Host 'PASS: bounded management framing and large UTF-8 stdin'
