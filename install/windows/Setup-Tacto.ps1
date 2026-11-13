[CmdletBinding()]
param(
    [ValidateSet('Install','Update','Rollback','Check','Uninstall')][string]$Action = 'Install',
    [ValidateSet('Local','Remote')][string]$Mode = 'Remote',
    [string]$VpsHost,
    [string]$VpsUser,
    [ValidateRange(1,65535)][int]$VpsPort = 22,
    [string]$DeviceName,
    [ValidateRange(0,65535)][int]$ReversePort = 0,
    [ValidateRange(1,65535)][int]$LocalSshPort = 22,
    [string]$IdentityFile,
    [string]$DriverPath,
    [string]$InstallDirectory = "$env:LOCALAPPDATA\Tacto",
    [string]$ExpectedUserSid,
    [string]$ResultFile,
    [string]$McpConfig,
    [string]$SkillDirectory,
    [ValidateSet('isolated','existing')][string]$BrowserMode = 'isolated',
    [switch]$NoSkills,
    [switch]$KeepConfig,
    [switch]$Force,
    [int]$ParentConsolePid,
    [ValidateSet('on','off')][string]$AutoUpdate,
    [switch]$LibraryOnly,
    [switch]$Unattended
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Desktop') { $env:PSModulePath = [IO.Path]::Combine($PSHOME,'Modules') }
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Set-StrictMode -Version 2.0
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
$script:PackageDirectory = $PSScriptRoot
$script:PackageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:ConfigPath = Join-Path $InstallDirectory 'desktop.json'
$script:Utf8 = [Text.UTF8Encoding]::new($false)
$script:InteractiveInstall = -not $VpsHost
$script:ModeSpecified = $PSBoundParameters.ContainsKey('Mode')
$script:BrowserModeSpecified = $PSBoundParameters.ContainsKey('BrowserMode')

function Write-Utf8([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $script:Utf8)
}

function Quote-Argument([string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-ProcessResult([string]$Executable, [string[]]$Arguments, [switch]$Interactive, [int]$TimeoutSeconds=180, [string]$InputText) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.Arguments = ($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $PSBoundParameters.ContainsKey('InputText')
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = -not $Interactive
    $info.CreateNoWindow = -not $Interactive
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        $process.Start() | Out-Null
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = if (-not $Interactive) { $process.StandardError.ReadToEndAsync() } else { $null }
        if ($info.RedirectStandardInput) {
            $inputBytes=$script:Utf8.GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($inputBytes,0,$inputBytes.Length)
            $process.StandardInput.BaseStream.Close()
        }
        if ($Interactive) { $process.WaitForExit() }
        elseif (-not $process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill(); $process.WaitForExit(); throw "$Executable timed out after $TimeoutSeconds seconds." }
        return @{ Code=$process.ExitCode; Output=$outputTask.Result; Error=$(if ($errorTask) { $errorTask.Result } else { '' }) }
    } finally { $process.Dispose() }
}

function Invoke-Native([string]$Executable, [string[]]$Arguments) {
    $result = Invoke-ProcessResult $Executable $Arguments
    if ($result.Output) { Write-Host $result.Output.TrimEnd() }
    if ($result.Code -ne 0) { throw "$Executable 执行失败，退出码 $($result.Code)" }
}

. (Join-Path $PSScriptRoot 'Download.ps1')

function Read-Setting([string]$Label, [string]$Value, [string]$Default) {
    if ($Value) { return $Value }
    if ($Unattended) {
        if ($Default) { return $Default }
        throw "自动安装需要提供：$Label"
    }
    $inputValue = Read-Host "$Label [$Default]"
    if ($inputValue) { return $inputValue.Trim() }
    return $Default
}

function Assert-Settings($Config) {
    if ($Config.Mode -eq 'Remote' -and $Config.VpsHost -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$') { throw 'VPS 地址请填写 IPv4 或主机名。' }
    if ($Config.Mode -eq 'Remote' -and $Config.VpsUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw 'VPS 用户名格式有误。' }
    if ($Config.DeviceName -notmatch '^[a-z][a-z0-9-]{0,23}$') { throw '电脑名称请使用小写字母开头，最多 24 位字母、数字和横线。' }
    if ($Config.ReversePort -ne 0 -and $Config.ReversePort -lt 1024) { throw '反向端口应为 1024–65535，或 0（自动分配）。' }
    foreach ($name in @('VpsPort','LocalSshPort')) {
        if ($Config.$name -lt 1 -or $Config.$name -gt 65535) { throw "$name 应为 1–65535。" }
    }
    if ($Config.ReversePort -gt 65535) { throw '反向端口应小于 65536。' }
}

function Protect-Directory([string]$Path) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Invoke-Native icacls.exe @($Path, '/inheritance:r', '/grant:r', "*${sid}:(OI)(CI)(F)", '*S-1-5-18:(OI)(CI)(F)', '*S-1-5-32-544:(OI)(CI)(F)')
}

function Ensure-Elevation {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($ExpectedUserSid -and $identity.User.Value -ne $ExpectedUserSid) { throw '请使用日常登录账户的管理员权限运行，以便接入该用户的桌面。' }
    if ([Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }
    $resultPath=$ResultFile
    if (-not $resultPath) {
        $folder=Join-Path ([IO.Path]::GetTempPath()) ('.Tacto-temp\elevation-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force $folder | Out-Null
        $resultPath=Join-Path $folder 'result.json'
    }
    $forward = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $script:PackageDirectory 'Setup-Tacto.ps1'),'-Action',$Action,'-InstallDirectory',$InstallDirectory,'-ExpectedUserSid',$identity.User.Value,'-ResultFile',$resultPath,'-ParentConsolePid',[string]$PID)
    foreach ($name in @('VpsHost','VpsUser','DeviceName','IdentityFile','DriverPath','McpConfig','SkillDirectory','AutoUpdate')) {
        $value = Get-Variable -Name $name -ValueOnly
        if ($value) { $forward += @('-' + $name, [string]$value) }
    }
    if ($script:ModeSpecified) { $forward += @('-Mode',$Mode) }
    if ($script:BrowserModeSpecified) { $forward += @('-BrowserMode',$BrowserMode) }
    foreach ($flag in @('Unattended','KeepConfig','Force','NoSkills')) { if (Get-Variable -Name $flag -ValueOnly) { $forward += '-' + $flag } }
    $forward += @('-VpsPort',"$VpsPort",'-ReversePort',"$ReversePort",'-LocalSshPort',"$LocalSshPort")
    $arguments = ($forward | ForEach-Object { Quote-Argument $_ }) -join ' '
    # Interactive SSH prompts reuse the original terminal; background helpers stay hidden.
    $process = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if (Test-Path -LiteralPath $resultPath) { Write-Host (Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8) }
    exit $process.ExitCode
}

function Get-SshExe([string]$Name) {
    $path = Join-Path "$env:WINDIR\System32\OpenSSH" $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "缺少 OpenSSH 程序：$path" }
    return $path
}

function Set-OwnedSshSettings($Config, [string]$ServerConfig, [bool]$Created) {
    $backup=Join-Path $InstallDirectory 'sshd_config.before'
    $restore=(Property $Config 'SshSettingsRestored' $false) -and (Test-Path -LiteralPath $backup) -and (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $ServerConfig -Algorithm SHA256).Hash
    if (-not $Created -and -not $restore) { return $false }
    if ($Created) {
        Set-Property $Config 'SshCreated' $true
        Copy-Item -LiteralPath $ServerConfig -Destination $backup -Force
    }
    $body=Get-Content -LiteralPath $ServerConfig -Raw
    Write-Utf8 $ServerConfig ("ListenAddress 127.0.0.1`r`nPort $($Config.LocalSshPort)`r`n" + $body)
    Set-Property $Config 'SshConfigHash' (Get-FileHash -LiteralPath $ServerConfig -Algorithm SHA256).Hash
    Set-Property $Config 'SshSettingsRestored' $false
    return $true
}

function Ensure-OpenSsh($Config) {
    $wasInstalled = [bool](Get-Service sshd -ErrorAction SilentlyContinue)
    foreach ($name in @('OpenSSH.Client~~~~0.0.1.0','OpenSSH.Server~~~~0.0.1.0')) {
        $feature = Get-WindowsCapability -Online -Name $name
        if ($feature.State -ne 'Installed') {
            $result = Add-WindowsCapability -Online -Name $name
            if ($result.RestartNeeded) { throw 'OpenSSH 安装需要重启 Windows；重启后再次运行 Install.cmd 即可继续。' }
        }
    }
    $sshd = Get-SshExe 'sshd.exe'
    $serverConfig = "$env:ProgramData\ssh\sshd_config"
    if (-not (Test-Path -LiteralPath $serverConfig)) {
        New-Item -ItemType Directory -Force "$env:ProgramData\ssh" | Out-Null
        Copy-Item -LiteralPath (Join-Path (Split-Path $sshd) 'sshd_config_default') -Destination $serverConfig
    }
    $ownedSettings=Set-OwnedSshSettings $Config $serverConfig (-not $wasInstalled)
    Invoke-Native (Get-SshExe 'ssh-keygen.exe') @('-A')
    Invoke-Native $sshd @('-t','-f',$serverConfig)
    if ($ownedSettings) { Set-Service sshd -StartupType Automatic }
    Start-Service sshd
    $settings = & $sshd -T -f $serverConfig -C "user=$env:USERNAME,host=localhost,addr=127.0.0.1"
    if ($LASTEXITCODE -ne 0) { throw '读取 OpenSSH 实际配置失败。' }
    $keySetting = @($settings | Where-Object { $_ -match '^authorizedkeysfile ' })[0] -replace '^authorizedkeysfile\s+',''
    $keySetting = $keySetting.Split(' ')[0]
    $keySetting = $keySetting.Replace('__PROGRAMDATA__',$env:ProgramData).Replace('%h',$env:USERPROFILE).Replace('%u',$env:USERNAME)
    if (-not [IO.Path]::IsPathRooted($keySetting)) { $keySetting = Join-Path $env:USERPROFILE $keySetting }
    $Config.AuthorizedKeysFile = [IO.Path]::GetFullPath($keySetting)
    if (-not $Config.PSObject.Properties['AuthorizedFileCreated']) { Set-Property $Config 'AuthorizedFileCreated' (-not (Test-Path -LiteralPath $Config.AuthorizedKeysFile)) }
    $Config.WindowsHostKey = (Get-Content -LiteralPath "$env:ProgramData\ssh\ssh_host_ed25519_key.pub" -Raw).Trim()
}

function Assert-CuaSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Cua AI') { throw 'CUA 可执行文件签名验证失败。' }
}

function Install-Cua($Config) {
    if ($DriverPath) {
        $Config.DriverPath = (Resolve-Path -LiteralPath $DriverPath).Path
        $Config.DriverOwned = $false
        return
    }
    if ($Config.DriverPath -and -not $Config.DriverOwned) { return }
    $release = Get-Content (Join-Path $script:PackageRoot 'resources/cua-release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $target = Join-Path $InstallDirectory ('cua-' + $release.version)
    $Config.DriverPath = Join-Path $target 'cua-driver.exe'
    $Config.DriverOwned = $true
    if (Test-Path -LiteralPath $Config.DriverPath) { Assert-CuaSignature $Config.DriverPath; return }
    $cache = Join-Path $InstallDirectory '.Tacto-temp\downloads'
    New-Item -ItemType Directory -Force $cache | Out-Null
    $archive = Join-Path $cache ('cua-' + $release.version + '.zip')
    $bundled = Join-Path $script:PackageRoot ('vendor\cua-' + $release.version + '.zip')
    if (-not (Test-Path -LiteralPath $archive) -and (Test-Path -LiteralPath $bundled)) { Copy-Item -LiteralPath $bundled -Destination $archive }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Receive-VerifiedArchive $release.url $archive $release.sha256
    Expand-Archive -LiteralPath $archive -DestinationPath $target -Force
    if (-not (Test-Path -LiteralPath $Config.DriverPath)) {
        $found = @(Get-ChildItem -LiteralPath $target -Filter cua-driver.exe -File -Recurse)
        if ($found.Count -ne 1) { throw 'CUA 安装包目录结构有变化，请更新安装包。' }
        $Config.DriverPath = $found[0].FullName
    }
    Assert-CuaSignature $Config.DriverPath
}

function Invoke-Vps($Config, [string]$RemoteAction, [switch]$Bootstrap, [switch]$CoreOnly) {
    $request = @{ action=$RemoteAction; device=$Config.DeviceName; clientId=$Config.ClientId }
    if ($CoreOnly) { $request.healthScope='activation' }
    if ($Bootstrap -or $RemoteAction -eq 'configure') {
        $request.skillFiles=Get-TargetSkillFiles $Config '{{VPS_CLI}}'
        $product=Get-TargetProduct $Config
        $request.mcpName=$product.mcpName
        $request.skillName=$product.skillName
        $request.cliPrefix="npx -y --package $($product.packageName)@latest $($product.cliName) driver"
    }
    if ($RemoteAction -eq 'remove') { $request.purge = $true }
    if ($Bootstrap) {
        $request.windowsUser = $env:USERNAME
        $request.windowsHostKey = $Config.WindowsHostKey
        $request.tunnelPublicKey = (Get-Content -LiteralPath ($Config.TunnelKey + '.pub') -Raw).Trim()
        $request.driverPath = $Config.DriverPath
        $request.reversePort = $Config.ReversePort
    }
    $payload = 'tacto-stdin-v2'
    $requestText=$request | ConvertTo-Json -Depth 32 -Compress
    $sshArgs = @('-T','-p',"$($Config.VpsPort)",'-o','ConnectTimeout=15','-o','IdentitiesOnly=yes','-o',"UserKnownHostsFile=$($Config.KnownHostsFile)")
    if ($Bootstrap) {
        if ($Unattended) { $sshArgs += @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes') }
        else { $sshArgs += @('-o','StrictHostKeyChecking=ask') }
        if ($IdentityFile) { $sshArgs += @('-i',(Resolve-Path -LiteralPath $IdentityFile).Path) }
        $bytes=[IO.File]::ReadAllBytes((Join-Path $script:PackageRoot 'install/linux/setup-vps.py'))
        $buffer=[IO.MemoryStream]::new()
        $gzip=[IO.Compression.GZipStream]::new($buffer,[IO.Compression.CompressionMode]::Compress,$true)
        try { $gzip.Write($bytes,0,$bytes.Length) } finally { $gzip.Dispose() }
        $source=[Convert]::ToBase64String($buffer.ToArray()); $buffer.Dispose()
        $command = 'python3 -c "import base64,gzip;code=gzip.decompress(base64.b64decode(''{0}'')).decode();exec(compile(code,''<bootstrap>'',''exec''),dict(__name__=''__main__'',__file__=''<bootstrap>'',BOOTSTRAP_SOURCE=code))" {1}' -f $source,$payload

    } else {
        $sshArgs += @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-i',$Config.TunnelKey)
        if ((Property $Config.Remote 'managementVersion' 0) -lt 2 -and $RemoteAction -in @('check','remove')) { $command=[Convert]::ToBase64String($script:Utf8.GetBytes($requestText)) }
        else { $command = $payload }
    }
    if ($command.Length -gt 29000) { throw 'VPS 初始化命令过长，请更新安装包传输方式。' }
    $sshArgs += @("$($Config.VpsUser)@$($Config.VpsHost)",$command)
    $nativeResult = Invoke-ProcessResult (Get-SshExe 'ssh.exe') $sshArgs -Interactive:($Bootstrap -and -not $Unattended) -InputText $requestText
    $response = @($nativeResult.Output -split '\r?\n')
    $code = $nativeResult.Code
    $line = @($response | Where-Object { $_ -like 'TACTO_SETUP_JSON=*' } | Select-Object -Last 1)
    if ($line.Count -ne 1) { throw "VPS 连接失败（退出码 $code）。请检查地址、SSH 登录和 Python 3。" }
    $data = $line[0].Substring('TACTO_SETUP_JSON='.Length) | ConvertFrom-Json
    if (-not $data.ok) { throw $data.error }
    return $data.result
}

function Set-WindowsAuthorization($Config, [string]$PublicKey, [switch]$Remove) {
    $path = $Config.AuthorizedKeysFile
    $folder = Split-Path $path
    New-Item -ItemType Directory -Force $folder | Out-Null
    $marker = 'tacto:' + $Config.DeviceName + ':' + $Config.ClientId
    $lines = @(if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Encoding UTF8 | Where-Object { -not $_.EndsWith(' ' + $marker) } })
    if (-not $Remove) {
        $bridgePath = (Join-Path $InstallDirectory 'Invoke-CuaBridge.ps1').Replace("'","''")
        $configPathEscaped = $script:ConfigPath.Replace("'","''")
        $bridge = "& '$bridgePath' -ConfigPath '$configPathEscaped'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bridge))
        $parts = $PublicKey.Split(' ')
        $lines += 'restrict,command="powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded + '" ' + $parts[0] + ' ' + $parts[1] + ' ' + $marker
    }
    Write-Utf8 $path (($lines -join "`r`n") + "`r`n")
    if ($Remove -and (Property $Config 'AuthorizedFileCreated' $false) -and @($lines | Where-Object { $_.Trim() }).Count -eq 0) {
        Remove-Item -LiteralPath $path -Force
        return
    }
    if ((Split-Path $path -Leaf) -eq 'administrators_authorized_keys') {
        Invoke-Native icacls.exe @($path,'/inheritance:r','/grant:r','*S-1-5-18:(F)','*S-1-5-32-544:(F)')
    } else {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Invoke-Native icacls.exe @($path,'/inheritance:r','/grant:r',"*${sid}:(F)",'*S-1-5-18:(F)','*S-1-5-32-544:(F)')
    }
}

function Save-Config($Config) { Write-AtomicJson $script:ConfigPath $Config }

function Install-Tasks($Config) {
    $launcher = Join-Path $InstallDirectory 'BackgroundLauncher.exe'
    $launcher = Join-Path $Config.RuntimePath 'install\windows\BackgroundLauncher.exe'
    $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $account
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $cuaArgs = @($Config.DriverPath,'serve','--socket',$Config.SocketPath,'--pid-file',(Join-Path $InstallDirectory 'cua.pid'))
    $tunnelArgs = @("$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe",'-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Config.RuntimePath 'install\windows\Start-Tunnel.ps1'),'-VpsHost',$Config.VpsHost,'-VpsUser',$Config.VpsUser,'-VpsPort',"$($Config.VpsPort)",'-ReversePort',"$($Config.ReversePort)",'-LocalSshPort',"$($Config.LocalSshPort)",'-IdentityFile',$Config.TunnelKey,'-KnownHostsFile',$Config.KnownHostsFile,'-InstanceName',$Config.TunnelTask,'-LogDirectory',(Join-Path $InstallDirectory 'logs'))
    $taskSpecs = @(@{ Name=$Config.CuaTask; Args=$cuaArgs; Level='Limited' })
    if ($Config.Mode -eq 'Remote') { $taskSpecs += @{ Name=$Config.TunnelTask; Args=$tunnelArgs; Level='Limited' } }
    foreach ($spec in $taskSpecs) {
        $actionSpec = New-ScheduledTaskAction -Execute $launcher -Argument (($spec.Args | ForEach-Object { Quote-Argument $_ }) -join ' ') -WorkingDirectory $InstallDirectory
        $principal = New-ScheduledTaskPrincipal -UserId $account -LogonType Interactive -RunLevel $spec.Level
        Register-ScheduledTask -TaskName $spec.Name -Action $actionSpec -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $spec.Name
    }
}

function Stop-OwnedTasks($Config) {
    foreach ($name in @($Config.TunnelTask,$Config.CuaTask)) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($task) { Stop-ScheduledTask -TaskName $name }
    }
    Start-Sleep -Seconds 1
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { throw "尚未找到安装配置：$script:ConfigPath" }
    return Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Check-Desktop($Config, [switch]$Activation) {
    $taskNames = @($Config.CuaTask)
    if ($Config.Mode -eq 'Remote') { $taskNames += $Config.TunnelTask }
    foreach ($name in $taskNames) {
        $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        Write-Host ("{0}: {1}" -f $name,$task.State)
        if ($task.State -ne 'Running') {
            $taskInfo=Get-ScheduledTaskInfo -TaskName $name
            if ($taskInfo.LastTaskResult -notin @(0,267009,267011)) { throw "Background task $name failed with result $($taskInfo.LastTaskResult)." }
            throw "Tacto readiness: task $name is $($task.State)."
        }
    }
    $driverStatus = Invoke-ProcessResult $Config.DriverPath @('status','--socket',$Config.SocketPath,'--pid-file',(Join-Path $InstallDirectory 'cua.pid')) -TimeoutSeconds 10
    if ($driverStatus.Code -notin @(0,1)) { throw "CUA executable failed with exit code $($driverStatus.Code)." }
    if ($driverStatus.Code -ne 0 -or $driverStatus.Output -notmatch 'daemon is running') { throw 'Tacto readiness: the CUA daemon is still starting.' }
    Write-Host $driverStatus.Output.TrimEnd()
    $health = Invoke-McpHealth $Config -CoreOnly:$Activation
    $remoteHealth = $null
    if ($Config.Mode -eq 'Remote') {
        $result = Invoke-Vps $Config 'check' -CoreOnly:$Activation
        if (Property $Config.Remote 'managementVersion') { $remoteHealth=$result.health; Assert-Health $remoteHealth }
        else { throw 'Upgrade the VPS helper once using the original SSH login before running full diagnostics.' }
    }
    $diagnostic = @{ok=$true;scope=$(if ($Activation) { 'activation' } else { 'full' });driver=$health;remote=$remoteHealth;daemonUser=$Config.UserSid;callerUser=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;callerSession=[Diagnostics.Process]::GetCurrentProcess().SessionId}
    Write-Host ($diagnostic | ConvertTo-Json -Depth 16 -Compress)
    $script:Outcome = 'MCP connected. Desktop health: ' + $health.overall + '. Capability details are included in the report.'

}

. (Join-Path $PSScriptRoot 'Lifecycle.ps1')
. (Join-Path $PSScriptRoot 'McpHealth.ps1')
. (Join-Path $PSScriptRoot 'AgentIntegration.ps1')

if ($LibraryOnly) { return }
$lock = $null
try {
    if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw '请使用 Windows 10/11 x64。' }
    if ($ParentConsolePid -and -not $Unattended) {
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class TactoConsole { [DllImport("kernel32.dll")] public static extern bool FreeConsole(); [DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid); }'
        [TactoConsole]::FreeConsole() | Out-Null
        if (-not [TactoConsole]::AttachConsole([uint32]$ParentConsolePid)) { throw 'Run remote setup from your terminal, or use --unattended with a trusted host and SSH key.' }
    }
    Assert-InstallRoot
    $existing = if (Test-Path -LiteralPath $script:ConfigPath) { Get-Config } else { $null }
    if ($Action -eq 'Install' -and -not $existing -and $Mode -eq 'Remote') {
        $VpsHost=Read-Setting 'VPS host' $VpsHost ''
        $VpsUser=Read-Setting 'VPS user' $VpsUser ''
        if (-not $DeviceName) { $DeviceName=(New-DesktopConfig).DeviceName }
    }
    if (Test-NeedsElevation $existing) { Ensure-Elevation }
    if ($Action -ne 'Check') { $lock = Enter-LifecycleLock }
    if (Test-Path -LiteralPath (Join-Path $InstallDirectory 'transaction.json')) {
        if ($Action -eq 'Check') { throw 'An interrupted update needs recovery. Run update or uninstall.' }
        Restore-Transaction
    }
    switch ($Action) {
        'Install' { Install-Desktop }
        'Update' { if (-not $existing) { throw '请先安装 Tacto。' }; Install-Desktop }
        'Rollback' { Invoke-Rollback }
        'Check' { $checked=Get-Config; if ($checked.Phase -ne 'complete') { throw 'Complete or repair the installation with update.' }; Check-Desktop $checked }
        'Uninstall' { Uninstall-Desktop }
    }
    if ($ResultFile) { Write-Utf8 $ResultFile (@{ok=$true;action=$Action;message=$script:Outcome;pendingRemote=$script:PendingRemote} | ConvertTo-Json -Depth 8) }
} catch {
    $message = $_.Exception.Message
    if ($ResultFile) { Write-Utf8 $ResultFile (@{ok=$false;action=$Action;message=$message} | ConvertTo-Json) }
    [Console]::Error.WriteLine('Tacto: ' + $message)
    exit 1
} finally {
    if ($lock) { $lock.Dispose() }
    if ($Action -eq 'Uninstall' -and (Test-Path -LiteralPath $InstallDirectory)) {
        $lockFile = Join-Path $InstallDirectory '.lifecycle.lock'
        if (Test-Path -LiteralPath $lockFile) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
        if (@(Get-ChildItem -LiteralPath $InstallDirectory -Force).Count -eq 0) {
            try { Remove-Item -LiteralPath $InstallDirectory -ErrorAction Stop }
            catch [System.IO.IOException] { Write-Warning "Owned services and files are removed; an application still holds the empty installation directory: $InstallDirectory" }
        }
    }
}
