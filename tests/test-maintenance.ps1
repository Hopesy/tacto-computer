$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fixture=Join-Path $repo ('.Tacto-temp\maintenance-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $fixture | Out-Null
. (Join-Path $repo 'install\windows\Setup-Tacto.ps1') -LibraryOnly -InstallDirectory $fixture
function Assert($condition,$message) { if (-not $condition) { throw $message } }
$env:ProgramData=Join-Path $fixture 'programdata'
$configFile=Join-Path $env:ProgramData 'ssh\sshd_config'
New-Item -ItemType Directory -Force (Split-Path $configFile) | Out-Null
$original="# Default OpenSSH config`r`nPasswordAuthentication no`r`n"
Write-Utf8 $configFile $original
$config=[pscustomobject]@{LocalSshPort=2222;AuthorizedKeysFile=(Join-Path $fixture 'authorized_keys')}
function Stop-Service($Name) { $script:stopped=$true }
function Set-Service($Name,$StartupType) { $script:startup=$StartupType }
Assert (Set-OwnedSshSettings $config $configFile $true) 'Fresh service settings were not applied'
Assert ((Get-Content $configFile -Raw).StartsWith('ListenAddress 127.0.0.1')) 'Missing loopback binding'
Restore-OpenSshSettings $config
Assert ($script:stopped -and $script:startup -eq 'Manual') 'Owned service was not restored'
Assert ((Get-Content $configFile -Raw) -eq $original) 'Original SSH settings changed'
Assert (Set-OwnedSshSettings $config $configFile $false) 'Retained reinstall did not reapply owned settings'
Restore-OpenSshSettings $config
Write-Utf8 $configFile '# user changed settings'
Assert (-not (Set-OwnedSshSettings $config $configFile $false)) 'Reinstall overwrote edited SSH settings'
Assert ((Get-Content $configFile -Raw) -eq '# user changed settings') 'Edited SSH settings changed'
$health=[pscustomobject]@{schema_version=1;platform='win32';overall='degraded';checks=@('binary_version','platform_supported','session_active') | ForEach-Object { [pscustomobject]@{name=$_;status='pass';message='ready'} }}
Assert-Health $health
$health.checks[2].status='fail'
$rejected=$false
try { Assert-Health $health } catch { $rejected=$true }
Assert $rejected 'Failed interactive session passed health validation'
$health.checks[2].status='pass'; $health.platform='linux'
$rejected=$false
try { Assert-Health $health } catch { $rejected=$true }
Assert $rejected 'Incorrect controlled platform passed health validation'
Write-AtomicJson (Join-Path $fixture 'desktop.json') @{Phase='complete';AutoUpdate=$true}
New-Item -ItemType Directory -Force (Join-Path $fixture 'connections') | Out-Null
Write-AtomicJson (Join-Path $fixture 'connections\active.json') @{pid=$PID;started=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'install\windows\Update-Available.ps1') -InstallDirectory $fixture
Assert ($LASTEXITCODE -eq 0) 'Idle updater failed to defer an active connection'
Assert (-not (Test-Path -LiteralPath (Join-Path $fixture '.Tacto-temp\updates'))) 'Busy updater started downloading'
Write-Host 'PASS: owned SSH settings, retained reinstall, edited settings protection, health validation'
$locked=Join-Path $fixture 'occupied-empty-install'
New-Item -ItemType Directory -Path $locked | Out-Null
$previousDirectory=[Environment]::CurrentDirectory
try {
    [Environment]::CurrentDirectory=$locked
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repo 'install\windows\Setup-Tacto.ps1') -Action Uninstall -InstallDirectory $locked -Unattended
    Assert ($LASTEXITCODE -eq 0) 'An occupied empty directory changed successful uninstall into failure'
    Assert (Test-Path -LiteralPath $locked) 'Expected the held empty directory to remain'
} finally { [Environment]::CurrentDirectory=$previousDirectory }
Write-Host 'PASS: empty directory lock is reported after successful service cleanup'
