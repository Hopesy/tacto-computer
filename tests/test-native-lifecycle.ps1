param([string]$DriverPath)
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root=Join-Path $repo ('.Tacto-temp\native-' + [guid]::NewGuid().ToString('N'))
$install=Join-Path $root 'install'
$configFile=Join-Path $install 'desktop.json'
$client=Join-Path $root 'agent.json'
$skills=Join-Path $root 'skills'
New-Item -ItemType Directory -Force $root | Out-Null
[IO.File]::WriteAllText($client,'{"mcpServers":{"other":{"command":"other","args":[]}}}')
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Config { Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json }
function Step([string]$Name,[string[]]$Arguments,[switch]$FailureExpected) {
    $log=Join-Path $root ($Name + '.log')
    $savedPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install\windows\Setup-Tacto.ps1') -InstallDirectory $install -Unattended @Arguments *> $log
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$savedPreference }
    if ($FailureExpected) { Assert ($code -ne 0) "Expected failure: $Name" }
    else { Assert ($code -eq 0) "Failed $Name; see $log" }
    Write-Host "PASS: $Name"
}
$device='native-' + [guid]::NewGuid().ToString('N').Substring(0,10)
try {
    $installationArgs=@('-Action','Install','-Mode','Local','-DeviceName',$device,'-McpConfig',$client,'-SkillDirectory',$skills)
    if ($DriverPath) { $installationArgs+=@('-DriverPath',$DriverPath) }
    Step 'install' $installationArgs
    $first=Config
    Assert ($first.Phase -eq 'complete') 'Install incomplete'
    Assert ((Get-ScheduledTask -TaskName $first.CuaTask).Principal.RunLevel -eq 'Limited') 'Local task requested elevated execution'
    $cli=Join-Path $repo 'bin\tacto.mjs'
    $session='tacto-cli-acceptance'
    $startJson='{"session":"' + $session + '"}'
    $startJson | & node $cli driver --install-dir $install call start_session *> (Join-Path $root 'cli-start.json')
    Assert ($LASTEXITCODE -eq 0) 'CLI start_session failed'
    $startJson | & node $cli call --install-dir $install get_session *> (Join-Path $root 'cli-session.json')
    Assert ($LASTEXITCODE -eq 0) 'CLI named session did not survive a second process'
    Assert (@(Get-ChildItem (Join-Path $install 'cli-sessions') -Filter '*.json').Count -eq 1) 'CLI idle lease missing'
    Step 'cli-busy-update' @('-Action','Update') -FailureExpected
    $startJson | & node $cli driver --install-dir $install call end_session *> (Join-Path $root 'cli-end.json')
    Assert ($LASTEXITCODE -eq 0) 'CLI end_session failed'
    Assert (@(Get-ChildItem (Join-Path $install 'cli-sessions') -Filter '*.json').Count -eq 0) 'CLI idle lease remains'
    & node $cli driver --install-dir $install call get_screen_size '{}' *> (Join-Path $root 'cli-screen-size.json')
    Assert ($LASTEXITCODE -eq 0) 'CLI read-only screen-size call failed'
    $official=Join-Path $skills 'tacto-computer\references\BROWSER.md'
    Assert ((Get-FileHash $official).Hash -eq (Get-FileHash (Join-Path $repo 'resources\cua-skill\BROWSER.md')).Hash) 'Official Skill content changed'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $skills 'tacto-computer') -Filter SKILL.md -Recurse).Count -eq 1) 'Expected one discoverable device Skill'
    Step 'upgrade' @('-Action','Update')
    $second=Config
    Assert ($first.RuntimePath -ne $second.RuntimePath) 'Upgrade did not stage an independent runtime'
    Assert ($first.ClientId -eq $second.ClientId -and $first.SocketPath -eq $second.SocketPath) 'Upgrade changed identity'
    $broken=Join-Path $root 'broken-driver.exe'
    $source=Join-Path $root 'broken.cs'
    [IO.File]::WriteAllText($source,'class Broken { static int Main() { return 17; } }')
    & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe "/out:$broken" $source
    Assert ($LASTEXITCODE -eq 0) 'Fault fixture compilation failed'
    Step 'failed-upgrade-restored' @('-Action','Update','-DriverPath',$broken) -FailureExpected
    $restored=Config
    Assert ($restored.RuntimePath -eq $second.RuntimePath -and $restored.DriverPath -eq $second.DriverPath -and $restored.Phase -eq 'complete') 'Automatic rollback failed'
    Step 'health-after-recovery' @('-Action','Check')
    & node (Join-Path $repo 'bin\tacto.mjs') probe (Join-Path $install 'mcp-local.json') --health --smoke *> (Join-Path $root 'probe.json')
    Assert ($LASTEXITCODE -eq 0) 'Actual MCP endpoint failed health/screen-size check'
    Step 'manual-rollback' @('-Action','Rollback')
    Assert ((Config).RuntimePath -eq $first.RuntimePath) 'Manual rollback chose the wrong runtime'
    Stop-ScheduledTask -TaskName $first.CuaTask
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName $first.CuaTask
    Start-Sleep -Seconds 4
    $readiness=Join-Path $root 'restart-health.ps1'
    $body=". '" + (Join-Path $repo 'install\windows\Setup-Tacto.ps1').Replace("'","''") + "' -LibraryOnly -InstallDirectory '" + $install.Replace("'","''") + "'`r`nWait-Healthy (Get-Config)"
    [IO.File]::WriteAllText($readiness,$body,[Text.UTF8Encoding]::new($true))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $readiness *> (Join-Path $root 'restart-health.log')
    Assert ($LASTEXITCODE -eq 0) 'Restart failed activation health'
    Write-Host 'PASS: restart-health'
    $launcher=Join-Path (Config).RuntimePath 'install\windows\BackgroundLauncher.exe'
    $bytes=[IO.File]::ReadAllBytes($launcher)
    $pe=[BitConverter]::ToInt32($bytes,0x3c)
    Assert ([BitConverter]::ToUInt16($bytes,$pe+24+68) -eq 2) 'Launcher has a console subsystem'
    $processes=@(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $launcher })
    Assert ($processes.Count -eq 1) 'Expected one owned background launcher'
    Assert ((Get-Process -Id $processes[0].ProcessId).MainWindowHandle -eq 0) 'Background launcher created a visible window'
    Step 'keep-config-uninstall' @('-Action','Uninstall','-KeepConfig')
    Assert ((Config).Phase -eq 'uninstalled') 'Keep-config uninstall lost its state'
    Assert (-not (Get-ScheduledTask -TaskName $first.CuaTask -ErrorAction SilentlyContinue)) 'Uninstall left the task'
    Step 'reinstall' @('-Action','Install','-Mode','Local')
    Assert ((Config).ClientId -eq $first.ClientId) 'Reinstall changed the retained identity'
    [IO.File]::WriteAllText((Join-Path $install 'user-note.txt'),'preserve this unrelated file')
    Step 'full-uninstall' @('-Action','Uninstall')
    Assert (-not (Test-Path -LiteralPath $configFile)) 'Full uninstall left desktop configuration'
    if ($DriverPath) { Assert (Test-Path -LiteralPath $DriverPath) 'External Driver was deleted' }
    else { Assert (-not (Test-Path -LiteralPath $first.DriverPath)) 'Owned Driver remains after full uninstall' }
    Assert (Test-Path -LiteralPath (Join-Path $install 'user-note.txt')) 'Unrelated file was deleted'
    Assert (-not (Test-Path -LiteralPath (Join-Path $install 'keys'))) 'Keys remain'
    Assert (-not (Test-Path -LiteralPath (Join-Path (Join-Path $skills 'tacto-computer') 'SKILL.md'))) 'Owned Skill remains'
    Assert (-not (Test-Path -LiteralPath ('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Tacto-' + $first.ClientId))) 'Installed-app entry remains'
    $document=Get-Content -LiteralPath $client -Raw | ConvertFrom-Json
    Assert ($document.mcpServers.other.command -eq 'other' -and @($document.mcpServers.PSObject.Properties).Count -eq 1) 'Client cleanup changed unrelated entries'
    Step 'repeat-uninstall' @('-Action','Uninstall')
    Write-Host "PASS: real Windows lifecycle; artifacts: $root"
} finally {
    if (Test-Path -LiteralPath $configFile) {
        $ErrorActionPreference='Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install\windows\Setup-Tacto.ps1') -Action Uninstall -InstallDirectory $install -Unattended *> (Join-Path $root 'cleanup.log')
    }
}
