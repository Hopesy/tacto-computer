# Lifecycle state is private to this installation. Loaded by Setup-Tacto.ps1.
$script:Outcome = ''
$script:PendingRemote = $null
function Property($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Set-Property($Object, [string]$Name, $Value) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
function Write-AtomicJson([string]$Path, $Value) {
    $temp = $Path + '.new'
    Write-Utf8 $temp ($Value | ConvertTo-Json -Depth 32)
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}
function Assert-InstallRoot {
    $forbidden = @([IO.Path]::GetPathRoot($InstallDirectory), $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramFiles, $env:WINDIR, [Environment]::GetFolderPath('Desktop'))
    foreach ($path in $forbidden) {
        if ($path -and $InstallDirectory.TrimEnd('\') -eq $path.TrimEnd('\')) { throw 'Choose a dedicated Tacto installation directory.' }
    }
    $cursor = $InstallDirectory
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Use an installation path without junctions or symbolic links.' }
        $cursor = Split-Path $cursor -Parent
    }
    if ($Action -in @('Install','Update') -and -not (Test-Path -LiteralPath $script:ConfigPath) -and (Test-Path -LiteralPath $InstallDirectory)) {
        $foreign = @(Get-ChildItem -LiteralPath $InstallDirectory -Force | Where-Object { $_.Name -notin @('.lifecycle.lock','ownership.json','.Tacto-temp') })
        if ($foreign.Count -and -not (Test-Path -LiteralPath (Join-Path $InstallDirectory 'ownership.json'))) { throw 'The installation directory contains existing files. Choose an empty directory.' }
    }
}
function Enter-LifecycleLock {
    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
    try { return [IO.File]::Open((Join-Path $InstallDirectory '.lifecycle.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw 'Another Tacto maintenance operation is running. Retry when it finishes.' }
}
function Test-NeedsElevation($Config) {
    if ($Action -eq 'Check') { return $false }
    if ($Action -eq 'Rollback') {
        $previousFile=Join-Path $InstallDirectory 'previous.json'
        if (Test-Path -LiteralPath $previousFile) {
            $previous=Get-Content -LiteralPath $previousFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not (Property $previous 'RuntimePath')) { return $true }
        }
    }
    if ($Config -and $Config.Phase -eq 'complete' -and -not (Property $Config 'RuntimePath')) { return $true }
    if ($Action -eq 'Uninstall') { return ($Config -and $Config.Mode -eq 'Remote' -and $Config.Phase -ne 'uninstalled') }
    if ($Config) { return ($Config.Mode -eq 'Remote' -and (-not (Property $Config 'RuntimePath') -or $Config.Phase -ne 'complete')) }
    return ($Mode -eq 'Remote')
}
function Add-OwnedPath([string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or ($Relative -split '[\\/]') -contains '..') { throw 'Invalid owned resource path.' }
    $path = Join-Path $InstallDirectory 'ownership.json'
    $state = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{schema=1;root=$InstallDirectory;paths=@()} }
    if ($state.root -ne $InstallDirectory) { throw 'Ownership manifest belongs to another directory.' }
    $state.paths = @(@($state.paths) + $Relative | Sort-Object -Unique)
    Write-AtomicJson $path $state
}
function Remove-OwnedPath([string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or ($Relative -split '[\\/]') -contains '..') { throw 'Invalid cleanup path.' }
    $path = [IO.Path]::GetFullPath((Join-Path $InstallDirectory $Relative))
    if (-not $path.StartsWith($InstallDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup path escaped the installation.' }
    if (Test-Path -LiteralPath $path) {
        $items = @((Get-Item -LiteralPath $path -Force)) + @(Get-ChildItem -LiteralPath $path -Force -Recurse -ErrorAction SilentlyContinue)
        if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw "Cleanup stopped at a linked resource: $path" }
        for ($attempt=0; $attempt -lt 10; $attempt++) {
            try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop; break }
            catch {
                if ($attempt -eq 9) { throw }
                # Windows may briefly retain image handles after the task exits.
                Start-Sleep -Milliseconds 500
            }
        }
    }
}
function Get-ActiveConnections {
    $active = @()
    $cliFolder=Join-Path $InstallDirectory 'cli-sessions'
    if (Test-Path -LiteralPath $cliFolder) {
        foreach ($file in Get-ChildItem -LiteralPath $cliFolder -Filter '*.json' -File) {
            try {
                $entry=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([DateTime]::Parse($entry.expires).ToUniversalTime() -gt [DateTime]::UtcNow) { $active+=$entry; continue }
            } catch { }
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
    $folder = Join-Path $InstallDirectory 'connections'
    if (-not (Test-Path -LiteralPath $folder)) { return $active }
    foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.json' -File) {
        $process=$null; $lease=$null
        try {
            $lease = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            try { $process = Get-Process -Id $lease.pid -ErrorAction Stop }
            catch {
                if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { $active += $lease; continue }
                Remove-Item -LiteralPath $file.FullName -Force
                continue
            }
            if ($process.StartTime.ToUniversalTime().Ticks.ToString() -eq $lease.started) { $active += $lease; continue }
        } catch {
            # A live process may require elevation to inspect. Treat it as busy.
            if ($process) { $active += $lease; continue }
        }
        Remove-Item -LiteralPath $file.FullName -Force
    }
    return $active
}
function Assert-Idle {
    if (@(Get-ActiveConnections).Count -and -not $Force) { throw 'MCP connections or CLI sessions are active. Close the connection or call end_session, then retry; --force permits an immediate restart.' }
}
function Stop-OwnedConnections {
    foreach ($lease in @(Get-ActiveConnections)) {
        if ((Property $lease 'kind') -eq 'cli-session') { continue }
        $result=Invoke-ProcessResult "$env:WINDIR\System32\taskkill.exe" @('/PID',[string]$lease.pid,'/T','/F')
        if ($result.Code -ne 0 -and (Get-Process -Id $lease.pid -ErrorAction SilentlyContinue)) { throw 'An active MCP process requires elevated permissions to stop. Retry from an administrator terminal.' }
    }
    Remove-OwnedPath 'cli-sessions'
}
function New-DesktopConfig {
    $defaultDevice = ($env:COMPUTERNAME.ToLower() -replace '[^a-z0-9-]','-')
    if ($defaultDevice -notmatch '^[a-z]') { $defaultDevice = 'pc-' + $defaultDevice }
    $defaultDevice = $defaultDevice.Substring(0, [Math]::Min(24,$defaultDevice.Length))
    $config = [pscustomobject]@{
        VpsHost=$(if ($Mode -eq 'Remote') { Read-Setting 'VPS host' $VpsHost '' } else { '' });
        VpsUser=$(if ($Mode -eq 'Remote') { Read-Setting 'VPS user' $VpsUser '' } else { '' });
        VpsPort=$VpsPort; DeviceName=(Read-Setting 'Computer name' $DeviceName $defaultDevice); ReversePort=$ReversePort;
        LocalSshPort=$LocalSshPort; Mode=$Mode; SocketPath=''; ClientId=[guid]::NewGuid().ToString();
        DriverPath=''; DriverOwned=$true; AuthorizedKeysFile=''; WindowsHostKey='';
        TunnelKey=(Join-Path $InstallDirectory 'keys\tunnel'); KnownHostsFile=(Join-Path $InstallDirectory 'keys\known_hosts');
        CuaTask=''; TunnelTask=''; Remote=$null; Phase='preparing'; UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    $instance = $config.DeviceName + '-' + $config.ClientId.Substring(0,8)
    $config.SocketPath = '\\.\pipe\tacto-' + $instance
    $config.CuaTask = 'Tacto-CUA-' + $instance
    $config.TunnelTask = 'Tacto-Tunnel-' + $instance
    return $config
}
function Stage-Runtime($Config) {
    $metadata = Get-Content -LiteralPath (Join-Path $script:PackageRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $relative = 'releases\' + $metadata.version + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    Add-OwnedPath 'releases'
    Add-OwnedPath $relative
    $destination = Join-Path $InstallDirectory $relative
    New-Item -ItemType Directory -Force $destination | Out-Null
    foreach ($item in @('install','resources','package.json')) { Copy-Item -LiteralPath (Join-Path $script:PackageRoot $item) -Destination $destination -Recurse }
    $windows = Join-Path $destination 'install\windows'
    $compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    Invoke-Native $compiler @('/nologo','/target:winexe','/platform:x64','/optimize+',('/out:' + (Join-Path $windows 'BackgroundLauncher.exe')),(Join-Path $windows 'BackgroundLauncher.cs'))
    Set-Property $Config 'RuntimePath' $destination
    Set-Property $Config 'TactoVersion' $metadata.version
    Set-Property $Config 'CliBridgeVersion' 1
}
function Register-Uninstaller($Config) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Tacto-' + $Config.ClientId
    New-Item -Path $key -Force | Out-Null
    $powershell="$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $args=@('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $Config.RuntimePath 'install\windows\Setup-Tacto.ps1'),'-Action','Uninstall','-InstallDirectory',$InstallDirectory,'-Unattended')
    $command=(Quote-Argument $powershell) + ' ' + (($args | ForEach-Object { Quote-Argument $_ }) -join ' ')
    foreach ($entry in @{DisplayName=('Tacto - ' + $Config.DeviceName);DisplayVersion=$Config.TactoVersion;Publisher='Hopesy';InstallLocation=$InstallDirectory;UninstallString=$command;QuietUninstallString=$command}.GetEnumerator()) { New-ItemProperty -Path $key -Name $entry.Key -Value $entry.Value -PropertyType String -Force | Out-Null }
    foreach ($name in @('NoModify','NoRepair')) { New-ItemProperty -Path $key -Name $name -Value 1 -PropertyType DWord -Force | Out-Null }
}
function Export-Connections($Config) {
    $powershell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $server = @{command=$powershell;args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $InstallDirectory 'Invoke-CuaBridge.ps1'),'-ConfigPath',$script:ConfigPath,'-Local')}
    $name=(Get-TargetProduct $Config).mcpName
    Write-AtomicJson (Join-Path $InstallDirectory 'mcp-local.json') @{mcpServers=@{$name=$server}}
    if ($Config.Mode -eq 'Remote') { Write-AtomicJson (Join-Path $InstallDirectory 'mcp-vps.json') @{mcpServers=@{$name=$Config.Remote.mcp}} }
    Install-TargetSkill $Config
    return $server
}
function Restore-Transaction {
    $path = Join-Path $InstallDirectory 'transaction.json'
    $transaction = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $previous = $transaction.previous
    Stop-OwnedTasks $transaction.candidate
    Remove-AgentIntegration $transaction.candidate
    if ($previous -and $previous.Phase -eq 'complete') {
        Save-Config $previous
        foreach ($backup in @($transaction.files)) {
            if ($backup.content -ne $null) { [IO.File]::WriteAllBytes((Join-Path $InstallDirectory $backup.name), [Convert]::FromBase64String($backup.content)) }
            elseif (Test-Path -LiteralPath (Join-Path $InstallDirectory $backup.name)) { Remove-Item -LiteralPath (Join-Path $InstallDirectory $backup.name) -Force }
        }
        if (Property $previous 'RuntimePath') {
            if ($previous.Mode -eq 'Remote') { $null=Invoke-Vps $previous 'configure' }
            Install-Tasks $previous
            $server=Export-Connections $previous
            Set-AgentIntegration $previous $server
            Save-Config $previous
            Register-Uninstaller $previous
            Set-AutoUpdateTask $previous
        }
        else {
            Set-AutoUpdateTask $previous
            $uninstallKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Tacto-' + $previous.ClientId
            if (Test-Path -LiteralPath $uninstallKey) { Remove-Item -LiteralPath $uninstallKey -Recurse -Force }
            foreach ($task in @($transaction.tasks)) {
                Register-ScheduledTask -TaskName $task.name -Xml $task.xml -Force | Out-Null
                Start-ScheduledTask -TaskName $task.name
            }
        }
        Wait-Healthy $previous
        Write-Host 'Previous Tacto version restored.'
    } else {
        $transaction.candidate.Phase = 'failed'
        Save-Config $transaction.candidate
    }
    Remove-Item -LiteralPath $path -Force
}
function Start-Transaction($Previous, $Candidate) {
    $files = @()
    foreach ($name in @('Invoke-CuaBridge.ps1','mcp-local.json','mcp-vps.json','skill\SKILL.md')) {
        $path = Join-Path $InstallDirectory $name
        $content = if (Test-Path -LiteralPath $path) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) } else { $null }
        $files += @{name=$name;content=$content}
    }
    $tasks = @()
    if ($Previous) {
        foreach ($name in @($Previous.CuaTask,$Previous.TunnelTask)) {
            if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { $tasks += @{name=$name;xml=(Export-ScheduledTask -TaskName $name)} }
        }
    }
    Add-OwnedPath 'transaction.json'
    Write-AtomicJson (Join-Path $InstallDirectory 'transaction.json') @{previous=$Previous;candidate=$Candidate;files=$files;tasks=$tasks}
}
function Wait-Healthy($Config) {
    $deadline=[DateTime]::UtcNow.AddSeconds(90)
    $healthFailures=0
    for ($attempt=0; $attempt -lt 45; $attempt++) {
        try { Check-Desktop $Config -Activation; return }
        catch {
            if ($_.Exception.Message -notlike 'Tacto readiness:*') { $healthFailures++ }
            if ($healthFailures -ge 3 -or [DateTime]::UtcNow -ge $deadline -or $attempt -eq 44) { throw }
            Write-Host ("Waiting for desktop health: " + $_.Exception.Message)
            Start-Sleep -Seconds 2
        }
    }
}
function Install-Desktop {
    $previous = if (Test-Path -LiteralPath $script:ConfigPath) { Get-Config } else { $null }
    $config = if ($previous) { $previous | ConvertTo-Json -Depth 32 | ConvertFrom-Json } else { New-DesktopConfig }
    if ($previous) {
        if (($script:ModeSpecified -and $Mode -ne $config.Mode) -or ($config.Mode -eq 'Remote' -and (($VpsHost -and $VpsHost -ne $config.VpsHost) -or ($VpsUser -and $VpsUser -ne $config.VpsUser))) -or ($DeviceName -and $DeviceName -ne $config.DeviceName)) { throw 'Uninstall the existing connection before changing its identity or destination.' }
        Assert-Idle
        foreach ($pair in @(@('McpConfig',$McpConfig),@('SkillDirectory',$SkillDirectory))) {
            $old=Property $previous $pair[0]
            if ($old -and $pair[1] -and [IO.Path]::GetFullPath($pair[1]) -ne $old -and $previous.Phase -ne 'uninstalled') { throw 'Keep the existing Agent paths during update; uninstall with --keep-config before relocating an integration.' }
        }
    }
    if ($previous -and $previous.Phase -eq 'uninstalled') {
        # Reinstall retained settings using the existing identity and key pair.
        $config.Remote=$null
        $config.AuthorizedKeysFile=''
    }
    Assert-Settings $config
    Protect-Directory $InstallDirectory
    foreach ($path in @('desktop.json','previous.json','.Tacto-temp','keys','logs','connections','cli-sessions','skill','mcp-local.json','mcp-vps.json','Invoke-CuaBridge.ps1','sshd_config.before')) { Add-OwnedPath $path }
    Protect-Directory (Join-Path $InstallDirectory 'keys')
    if (-not $previous) { Save-Config $config }
    if ($IdentityFile) { Set-Property $config 'BootstrapIdentityFile' (Resolve-Path -LiteralPath $IdentityFile).Path }
    elseif (Property $config 'BootstrapIdentityFile') { $script:IdentityFile = $config.BootstrapIdentityFile }
    if ($McpConfig) { Set-Property $config 'McpConfig' ([IO.Path]::GetFullPath($McpConfig)) }
    if ($NoSkills -and $SkillDirectory) { throw 'Choose -SkillDirectory or -NoSkills.' }
    if ($NoSkills) { Set-Property $config 'NoSkills' $true }
    elseif ($SkillDirectory) { Set-Property $config 'NoSkills' $false }
    if ($SkillDirectory) { Set-Property $config 'SkillDirectory' ([IO.Path]::GetFullPath($SkillDirectory)) }
    if ($script:BrowserModeSpecified -or -not (Property $config 'BrowserMode')) { Set-Property $config 'BrowserMode' $BrowserMode }
    if ($AutoUpdate) { Set-Property $config 'AutoUpdate' ($AutoUpdate -eq 'on') }
    elseif (-not $config.PSObject.Properties['AutoUpdate']) { Set-Property $config 'AutoUpdate' $false }
    Write-Host '[1/5] Preparing dependencies and verified runtime'
    if ($config.Mode -eq 'Remote' -and -not $config.AuthorizedKeysFile) { Ensure-OpenSsh $config; Save-Config $config }
    $release = Get-Content (Join-Path $script:PackageRoot 'resources/cua-release.json') -Raw | ConvertFrom-Json
    if (-not $DriverPath -and $config.DriverOwned) { Add-OwnedPath ('cua-' + $release.version) }
    Install-Cua $config
    Stage-Runtime $config
    Write-Host '[2/5] Preparing connection'
    if ($config.Mode -eq 'Remote') {
        if (-not (Test-Path -LiteralPath $config.TunnelKey)) { Invoke-Native (Get-SshExe 'ssh-keygen.exe') @('-q','-t','ed25519','-N','','-f',$config.TunnelKey) }
        if (-not (Test-Path -LiteralPath $config.KnownHostsFile)) {
            $known = Join-Path $env:USERPROFILE '.ssh\known_hosts'
            if (Test-Path -LiteralPath $known) { Copy-Item -LiteralPath $known -Destination $config.KnownHostsFile }
        }
        if (-not $config.Remote -or (Property $config.Remote 'managementVersion' 0) -lt 3) {
            $config.Remote = Invoke-Vps $config 'prepare' -Bootstrap
            $config.ReversePort = $config.Remote.reversePort
            Set-Property $config 'RemoteCleanupComplete' $false
        }
    }
    Write-Host '[3/5] Switching background services'
    Start-Transaction $previous $config
    try {
        Assert-Idle
        if ($config.Mode -eq 'Remote') { $null=Invoke-Vps $config 'configure' }
        if ($Force) { Stop-OwnedConnections }
        Stop-OwnedTasks $config
        Copy-Item -LiteralPath (Join-Path $config.RuntimePath 'install\windows\Invoke-CuaBridge.ps1') -Destination (Join-Path $InstallDirectory 'Invoke-CuaBridge.ps1') -Force
        $config.Phase = 'connecting'
        Save-Config $config
        if ($config.Mode -eq 'Remote' -and (-not $previous -or $previous.Phase -ne 'complete' -or -not (Property $previous 'RuntimePath'))) { Set-WindowsAuthorization $config $config.Remote.windowsKey }
        Install-Tasks $config
        Write-Host '[4/5] Verifying the real MCP connection'
        Wait-Healthy $config
        $server = Export-Connections $config
        Set-AgentIntegration $config $server
        $config.Phase = 'complete'
        Save-Config $config
        Register-Uninstaller $config
        Set-AutoUpdateTask $config
        if ($previous -and $previous.Phase -eq 'complete') {
            Write-AtomicJson (Join-Path $InstallDirectory 'previous.json') $previous
            Add-OwnedPath 'previous-transaction.json'
            Copy-Item -LiteralPath (Join-Path $InstallDirectory 'transaction.json') -Destination (Join-Path $InstallDirectory 'previous-transaction.json') -Force
        }
        Remove-Item -LiteralPath (Join-Path $InstallDirectory 'transaction.json') -Force
    } catch {
        $failure = $_.Exception.Message
        try { Restore-Transaction } catch { throw "Update failed: $failure. Recovery pending: $($_.Exception.Message). Run update again." }
        throw "Update failed and recovery completed: $failure"
    }
    Write-Host '[5/5] Installation complete'
    $script:Outcome = "Tacto $($config.TactoVersion) ready. MCP: $InstallDirectory\mcp-local.json"
    Write-Host $script:Outcome
}
function Invoke-Rollback {
    Assert-Idle
    $file = Join-Path $InstallDirectory 'previous.json'
    if (-not (Test-Path -LiteralPath $file)) { throw 'No previous verified version is available.' }
    $current = Get-Config
    $previous = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not (Property $previous 'RuntimePath')) {
        $snapshot=Join-Path $InstallDirectory 'previous-transaction.json'
        if (-not (Test-Path -LiteralPath $snapshot)) { throw 'The saved legacy transaction backup is missing.' }
        if ($Force) { Stop-OwnedConnections }
        $transaction=Get-Content -LiteralPath $snapshot -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($transaction.previous.ClientId -ne $current.ClientId) { throw 'Legacy backup belongs to another installation.' }
        $transaction.candidate=$current
        Write-AtomicJson (Join-Path $InstallDirectory 'transaction.json') $transaction
        Restore-Transaction
        Write-AtomicJson $file $current
        $script:Outcome='Legacy version restored and MCP health verified.'
        Write-Host $script:Outcome
        return
    }
    Start-Transaction $current $previous
    try {
        if ($Force) { Stop-OwnedConnections }
        Stop-OwnedTasks $current
        Remove-AgentIntegration $current
        if ($previous.Mode -eq 'Remote') { $null=Invoke-Vps $previous 'configure' }
        Save-Config $previous
        Copy-Item -LiteralPath (Join-Path $previous.RuntimePath 'install\windows\Invoke-CuaBridge.ps1') -Destination (Join-Path $InstallDirectory 'Invoke-CuaBridge.ps1') -Force
        Install-Tasks $previous
        Wait-Healthy $previous
        $server = Export-Connections $previous
        Set-AgentIntegration $previous $server
        Save-Config $previous
        Register-Uninstaller $previous
        Set-AutoUpdateTask $previous
        Write-AtomicJson $file $current
        Remove-Item -LiteralPath (Join-Path $InstallDirectory 'transaction.json')
        $script:Outcome = 'Rollback completed and MCP health verified.'
        Write-Host $script:Outcome
    } catch { $failure=$_.Exception.Message; Restore-Transaction; throw $failure }
}
function Uninstall-Desktop {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { $script:Outcome='Tacto is already uninstalled.'; return }
    $config = Get-Config
    $wasRemoved=$config.Phase -eq 'uninstalled'
    $pending = $null
    if ($config.Mode -eq 'Remote' -and -not (Property $config 'RemoteCleanupComplete' $false)) {
        try {
            $removed = Invoke-Vps $config 'remove'
            if (Property $removed 'retainedBackup') { throw 'Legacy VPS files require owner-login cleanup.' }
            foreach ($path in @(Property $removed 'preservedIntegrations' @())) { Write-Warning ('Preserved edited Agent integration on VPS: ' + $path) }
            Set-Property $config 'RemoteCleanupComplete' $true
        }
        catch { $pending = $_.Exception.Message }
    }
    $config.Phase='uninstalling'
    Save-Config $config
    Stop-OwnedConnections
    Stop-OwnedTasks $config
    foreach ($name in @($config.CuaTask,$config.TunnelTask,('Tacto-Update-' + $config.ClientId))) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
    }
    if (-not $wasRemoved -and $config.Mode -eq 'Remote' -and $config.AuthorizedKeysFile) { Set-WindowsAuthorization $config '' -Remove }
    Remove-AgentIntegration $config
    if (-not $wasRemoved) { Restore-OpenSshSettings $config }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Tacto-' + $config.ClientId
    if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force }
    if ($pending) {
        $receiptFolder = Join-Path $env:LOCALAPPDATA 'Tacto-cleanup'
        New-Item -ItemType Directory -Force $receiptFolder | Out-Null
        $receipt = Join-Path $receiptFolder ($config.ClientId + '.json')
        $proxy = Property $config.Remote 'mcp'
        Write-AtomicJson $receipt @{schema=1;device=$config.DeviceName;clientId=$config.ClientId;host=$config.VpsHost;user=$config.VpsUser;port=$config.VpsPort;proxy=(Property $proxy 'command');error=$pending;action='Sign in to the VPS and run tacto-cli cleanup --receipt <this file> on an SSH-capable Agent host.'}
        $script:PendingRemote = $receipt
        Write-Warning "Local cleanup continues. Remote cleanup receipt: $receipt"
    }
    # Legacy installations have a known, bounded set of owned resources.
    foreach ($path in @('desktop.json','previous.json','transaction.json','.Tacto-temp','keys','logs','connections','cli-sessions','skill','mcp-local.json','mcp-vps.json','Invoke-CuaBridge.ps1','Start-Tunnel.ps1','BackgroundLauncher.cs','BackgroundLauncher.exe','cua.pid','sshd_config.before')) { Add-OwnedPath $path }
    if ($config.DriverOwned -and $config.DriverPath.StartsWith($InstallDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $driverFolder = $config.DriverPath.Substring($InstallDirectory.Length+1).Split('\')[0]
        if ($driverFolder -match '^cua-[0-9]') { Add-OwnedPath $driverFolder }
    }
    $manifestFile = Join-Path $InstallDirectory 'ownership.json'
    $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($relative in @($manifest.paths)) {
        if ($KeepConfig -and $relative -in @('desktop.json','keys','logs','sshd_config.before')) { continue }
        Remove-OwnedPath $relative
    }
    if ($KeepConfig) { $config.Phase='uninstalled'; Save-Config $config }
    else { Remove-Item -LiteralPath $manifestFile -Force }
    $script:Outcome = if ($pending) { 'Local uninstall completed. Remote authorization cleanup is pending; see the receipt.' } else { 'Tacto services, authorization and owned files removed.' }
    Write-Host $script:Outcome
}

function Set-AutoUpdateTask($Config) {
    $name='Tacto-Update-' + $Config.ClientId
    if (Property $Config 'AutoUpdate' $false) {
        $account=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        $args=@("$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe",'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Config.RuntimePath 'install\windows\Update-Available.ps1'),'-InstallDirectory',$InstallDirectory)
        $actionSpec=New-ScheduledTaskAction -Execute (Join-Path $Config.RuntimePath 'install\windows\BackgroundLauncher.exe') -Argument (($args | ForEach-Object { Quote-Argument $_ }) -join ' ') -WorkingDirectory $InstallDirectory
        $trigger=New-ScheduledTaskTrigger -Daily -At '12:00' -RandomDelay (New-TimeSpan -Minutes 30)
        $principal=New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel Limited
        $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -StartWhenAvailable -RunOnlyIfNetworkAvailable
        Register-ScheduledTask -TaskName $name -Action $actionSpec -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    } elseif (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
}
function Restore-OpenSshSettings($Config) {
    if (-not (Property $Config 'SshCreated' $false)) { return }
    $file=Join-Path $env:ProgramData 'ssh\sshd_config'
    $backup=Join-Path $InstallDirectory 'sshd_config.before'
    if ((Test-Path -LiteralPath $backup) -and (Test-Path -LiteralPath $file) -and (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq (Property $Config 'SshConfigHash')) {
        $authorization=if (Test-Path -LiteralPath $Config.AuthorizedKeysFile) { @(Get-Content -LiteralPath $Config.AuthorizedKeysFile | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') }) } else { @() }
        if (@($authorization).Count -eq 0) {
            Copy-Item -LiteralPath $backup -Destination $file -Force
            Stop-Service sshd
            Set-Service sshd -StartupType Manual
            Set-Property $Config 'SshSettingsRestored' $true
        } else { Write-Warning 'OpenSSH is shared by other keys; its current service configuration was retained.' }
    }
}
