$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture = Join-Path (Split-Path $PSScriptRoot) ('forwarding space-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $fixture | Out-Null
$preload = Join-Path $fixture 'preload.mjs'
$source = @'
import childProcess from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';
import {writeFileSync} from 'node:fs';
import {EventEmitter} from 'node:events';
childProcess.spawn = (command, args) => {
  writeFileSync(process.env.TACTO_TEST_ARGS, JSON.stringify({command,args}));
  const child = new EventEmitter();
  child.kill = () => true;
  setImmediate(() => child.emit('exit', 0));
  return child;
};
syncBuiltinESMExports();
'@
[IO.File]::WriteAllText($preload, $source)
$preloadUri = ([Uri]$preload).AbsoluteUri
$previousArgs = $env:TACTO_TEST_ARGS
try {
    $env:TACTO_TEST_ARGS = Join-Path $fixture 'arguments.txt'
    & node --import $preloadUri (Join-Path $repo 'bin/tacto.mjs') setup --local --unattended --install-dir (Join-Path $fixture 'install dir') --device-name test-pc
    if ($LASTEXITCODE) { throw 'CLI setup failed' }
    $arguments = (Get-Content $env:TACTO_TEST_ARGS -Raw | ConvertFrom-Json).args
    if ($arguments -notcontains '-Unattended' -or $arguments -notcontains 'Local' -or $arguments -notcontains (Join-Path $repo 'Setup-Tacto.ps1')) { throw 'CLI forwarded wrong installer arguments' }
    if ($arguments -notcontains (Join-Path $fixture 'install dir')) { throw 'CLI changed path containing spaces' }
    & node --import $preloadUri (Join-Path $repo 'bin/tacto.mjs') update --unattended --install-dir (Join-Path $fixture 'install dir')
    if ($LASTEXITCODE) { throw 'CLI update failed' }
    $arguments = (Get-Content $env:TACTO_TEST_ARGS -Raw | ConvertFrom-Json).args
    if ($arguments -contains '-Mode' -or $arguments -notcontains 'Install') { throw 'Update changed existing installation mode' }
} finally {
    $env:TACTO_TEST_ARGS = $previousArgs
}
Write-Host 'PASS: CLI installer routing and unattended arguments with isolated process calls'
