param(
    [string]$CuaArchive,
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) '.Tacto-temp\packages')
)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$metadata = Get-Content -LiteralPath (Join-Path $projectRoot 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$version = $metadata.version
$output = [IO.Path]::GetFullPath($OutputDirectory)
$staging = Join-Path $output ('.Tacto-temp\' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $staging ('Tacto-' + $version)
New-Item -ItemType Directory -Force $package,$output | Out-Null
$files = @('README.md','LICENSE','NOTICE','package.json')
foreach ($directory in @('bin','src','install','resources','scripts','docs')) {
    $files += Get-ChildItem -LiteralPath (Join-Path $projectRoot $directory) -File -Recurse | ForEach-Object { $_.FullName.Substring($projectRoot.Length + 1) }
}
foreach ($name in $files) {
    New-Item -ItemType Directory -Force (Split-Path (Join-Path $package $name)) | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $package $name)
}
if ($CuaArchive) {
    $release = Get-Content -LiteralPath (Join-Path $projectRoot 'resources/cua-release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
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
