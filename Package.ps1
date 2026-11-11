param(
    [string]$CuaArchive,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '.Tacto-temp\packages')
)
$ErrorActionPreference = 'Stop'
$version = '0.1.0'
$output = [IO.Path]::GetFullPath($OutputDirectory)
$staging = Join-Path $output ('.Tacto-temp\' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $staging ('Tacto-' + $version)
New-Item -ItemType Directory -Force $package,$output | Out-Null
$files = @('Install.cmd','Install-Local.cmd','Update.cmd','Check.cmd','Uninstall.cmd','Setup-Tacto.ps1','Export-McpConfig.ps1','setup-vps.py','BackgroundLauncher.cs','Start-Tunnel.ps1','Invoke-CuaBridge.ps1','cua-release.json','probe.mjs','Package.ps1','README.md','VERIFICATION.md','LICENSE','NOTICE','package.json','bin/tacto.mjs')
foreach ($name in $files) { New-Item -ItemType Directory -Force (Split-Path (Join-Path $package $name)) | Out-Null; Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $package $name) }
if ($CuaArchive) {
    $release = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'cua-release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Get-FileHash -LiteralPath $CuaArchive -Algorithm SHA256).Hash -ne $release.sha256) { throw 'CUA archive hash mismatch' }
    New-Item -ItemType Directory -Force (Join-Path $package 'vendor') | Out-Null
    Copy-Item -LiteralPath $CuaArchive -Destination (Join-Path $package ('vendor\cua-' + $release.version + '.zip'))
}
$manifest = [ordered]@{ product='Tacto'; version=$version; files=@() }
foreach ($file in Get-ChildItem -LiteralPath $package -File -Recurse) {
    $manifest.files += @{ path=$file.FullName.Substring($package.Length + 1).Replace('\','/'); sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower(); bytes=$file.Length }
}
[IO.File]::WriteAllText((Join-Path $package 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$zip = Join-Path $output ('Tacto-' + $version + '.zip')
Compress-Archive -LiteralPath $package -DestinationPath $zip -Force
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText(($zip + '.sha256'), ($hash + '  ' + (Split-Path $zip -Leaf) + "`n"), [Text.UTF8Encoding]::new($false))
Write-Host $zip
Write-Host $hash
