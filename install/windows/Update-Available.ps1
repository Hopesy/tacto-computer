param([Parameter(Mandatory=$true)][string]$InstallDirectory)
$ErrorActionPreference='Stop'
$InstallDirectory=[IO.Path]::GetFullPath($InstallDirectory)
$config=Get-Content -LiteralPath (Join-Path $InstallDirectory 'desktop.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($config.Phase -ne 'complete' -or -not $config.AutoUpdate) { exit 0 }
. (Join-Path $PSScriptRoot 'Setup-Tacto.ps1') -LibraryOnly -Action Update -InstallDirectory $InstallDirectory -Unattended
if (@(Get-ActiveConnections).Count) { exit 0 }
$cache=Join-Path $InstallDirectory '.Tacto-temp\updates'
New-Item -ItemType Directory -Force $cache | Out-Null
$log=Join-Path $cache 'last-update.json'
if (Test-NeedsElevation $config) {
    Write-AtomicJson $log @{ok=$false;skipped=$true;message='Manual update required because administrator permissions are needed.';time=[DateTime]::UtcNow.ToString('o')}
    exit 0
}
$stage=$null
$zip=$null
$childLog=Join-Path $cache ('child-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $releaseFile=Join-Path $cache 'release.json'
    Receive-File 'https://api.github.com/repos/Hopesy/tacto-computer/releases/latest' $releaseFile
    $release=Get-Content -LiteralPath $releaseFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Property $release 'draft' $false) -or (Property $release 'prerelease' $false)) { exit 0 }
    $version=$release.tag_name -replace '^v',''
    if ($version -notmatch '^\d+\.\d+\.\d+$' -or $release.tag_name -ne ('v' + $version) -or [version]$version -le [version]$config.TactoVersion) { exit 0 }
    $name='Tacto-' + $version + '.zip'
    $zipAsset=@($release.assets | Where-Object { $_.name -eq $name })
    $hashAsset=@($release.assets | Where-Object { $_.name -eq ($name + '.sha256') })
    if ($zipAsset.Count -ne 1 -or $hashAsset.Count -ne 1) { throw 'The published release is missing its Windows package or checksum.' }
    $expectedPrefix='https://github.com/Hopesy/tacto-computer/releases/download/v' + $version + '/'
    foreach ($asset in @($zipAsset[0],$hashAsset[0])) {
        if (-not $asset.browser_download_url.StartsWith($expectedPrefix)) { throw 'Unexpected release download source.' }
    }
    $zip=Join-Path $cache $name
    Receive-File $hashAsset[0].browser_download_url ($zip + '.sha256')
    $hash=(Get-Content -LiteralPath ($zip + '.sha256') -Raw).Trim().Split(' ')[0]
    if ($hash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid release checksum format.' }
    $assetDigest=Property $zipAsset[0] 'digest'
    if ($assetDigest -and $assetDigest -match '^sha256:([a-fA-F0-9]{64})$' -and $Matches[1].ToLower() -ne $hash.ToLower()) {
        throw 'GitHub release asset digest does not match the published checksum.'
    }
    Receive-File $zipAsset[0].browser_download_url ($zip + '.partial') -Resume
    if ((Get-FileHash -LiteralPath ($zip + '.partial') -Algorithm SHA256).Hash -ne $hash) {
        Remove-Item -LiteralPath ($zip + '.partial') -Force -ErrorAction SilentlyContinue
        throw 'Update archive checksum mismatch.'
    }
    Move-Item -LiteralPath ($zip + '.partial') -Destination $zip -Force
    $stage=Join-Path $cache ([guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $zip -DestinationPath $stage
    $package=Join-Path $stage ('Tacto-' + $version)
    $manifest=Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.files) {
        $path=[IO.Path]::GetFullPath((Join-Path $package $entry.path))
        if (-not $path.StartsWith($package + '\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid update manifest path.' }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) { throw 'Update payload checksum mismatch.' }
    }
    if (@(Get-ActiveConnections).Count) { exit 0 }
    $result=Invoke-ProcessResult "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $package 'install\windows\Setup-Tacto.ps1'),'-Action','Update','-InstallDirectory',$InstallDirectory,'-Unattended','-ResultFile',$childLog) -TimeoutSeconds 900
    if ($result.Code -ne 0) {
        $childMessage=''
        if (Test-Path -LiteralPath $childLog) {
            try { $childMessage=Property (Get-Content -LiteralPath $childLog -Raw -Encoding UTF8 | ConvertFrom-Json) 'message' '' } catch { }
        }
        $detail=if ($childMessage) { $childMessage } elseif ($result.Error.Trim()) { $result.Error.Trim() } else { "Update exited with code $($result.Code)." }
        throw $detail
    }
    if (Test-Path -LiteralPath $childLog) { Copy-Item -LiteralPath $childLog -Destination $log -Force }
} catch {
    Write-AtomicJson $log @{ok=$false;message=$_.Exception.Message;time=[DateTime]::UtcNow.ToString('o')}
    exit 1
} finally {
    $cleanupPaths = @($stage,$childLog)
    if ($zip) { $cleanupPaths += @(($zip + '.partial'),($zip + '.sha256'),$zip) }
    foreach ($cleanupPath in $cleanupPaths) {
        if ($cleanupPath -and (Test-Path -LiteralPath $cleanupPath)) { Remove-Item -LiteralPath $cleanupPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
