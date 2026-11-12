param([Parameter(Mandatory=$true)][string]$InstallDirectory)
$ErrorActionPreference='Stop'
$InstallDirectory=[IO.Path]::GetFullPath($InstallDirectory)
$config=Get-Content -LiteralPath (Join-Path $InstallDirectory 'desktop.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($config.Phase -ne 'complete' -or -not $config.AutoUpdate) { exit 0 }
. (Join-Path $PSScriptRoot 'Setup-Tacto.ps1') -LibraryOnly -InstallDirectory $InstallDirectory -Unattended
if (@(Get-ActiveConnections).Count) { exit 0 }
$cache=Join-Path $InstallDirectory '.Tacto-temp\updates'
New-Item -ItemType Directory -Force $cache | Out-Null
$log=Join-Path $cache 'last-update.json'
try {
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $releaseFile=Join-Path $cache 'release.json'
    Receive-File 'https://api.github.com/repos/Hopesy/tacto-mcp/releases/latest' $releaseFile
    $release=Get-Content -LiteralPath $releaseFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $version=$release.tag_name -replace '^v',''
    if ($version -notmatch '^\d+\.\d+\.\d+$' -or [version]$version -le [version]$config.TactoVersion) { exit 0 }
    $name='Tacto-' + $version + '.zip'
    $zipAsset=@($release.assets | Where-Object { $_.name -eq $name })
    $hashAsset=@($release.assets | Where-Object { $_.name -eq ($name + '.sha256') })
    if ($zipAsset.Count -ne 1 -or $hashAsset.Count -ne 1) { throw 'The published release is missing its Windows package or checksum.' }
    foreach ($asset in @($zipAsset[0],$hashAsset[0])) {
        if (-not $asset.browser_download_url.StartsWith('https://github.com/Hopesy/tacto-mcp/releases/download/')) { throw 'Unexpected release download source.' }
    }
    $zip=Join-Path $cache $name
    Receive-File $hashAsset[0].browser_download_url ($zip + '.sha256')
    $hash=(Get-Content -LiteralPath ($zip + '.sha256') -Raw).Trim().Split(' ')[0]
    Receive-File $zipAsset[0].browser_download_url ($zip + '.partial')
    if ($hash -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath ($zip + '.partial') -Algorithm SHA256).Hash -ne $hash) { throw 'Update archive checksum mismatch.' }
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
    $result=Invoke-ProcessResult "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $package 'install\windows\Setup-Tacto.ps1'),'-Action','Update','-InstallDirectory',$InstallDirectory,'-Unattended','-ResultFile',$log) -TimeoutSeconds 900
    if ($result.Code -ne 0) { throw $result.Error }
} catch {
    Write-AtomicJson $log @{ok=$false;message=$_.Exception.Message;time=[DateTime]::UtcNow.ToString('o')}
    exit 1
}
