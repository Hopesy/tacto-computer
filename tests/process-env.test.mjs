import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {join} from 'node:path';
import {childEnvironment} from '../src/process-env.mjs';

test('Windows PowerShell resolves stock cmdlets through a polluted parent module path', {skip:process.platform!=='win32'}, () => {
  const core=spawnSync('pwsh',['-NoProfile','-NonInteractive','-Command','$PSHOME'],{encoding:'utf8',timeout:15000});
  assert.equal(core.status,0,core.stderr);
  const polluted=join(core.stdout.trim(),'Modules');
  const command=join(process.env.SystemRoot,'System32','WindowsPowerShell','v1.0','powershell.exe');
  const result=spawnSync(command,['-NoProfile','-NonInteractive','-Command',
    "$ErrorActionPreference='Stop'; $names='Get-FileHash','Get-AuthenticodeSignature','Expand-Archive','Get-ScheduledTask'; foreach($name in $names) { (Get-Command $name).Name }"],
    {env:childEnvironment({PSModulePath:polluted},command),encoding:'utf8',timeout:20000});
  assert.equal(result.status,0,result.stderr);
  assert.match(result.stdout,/Get-FileHash[\s\S]*Get-ScheduledTask/);
  const ordinary=childEnvironment({PSModulePath:polluted},'ssh');
  assert.equal(ordinary.PSModulePath,polluted);
});
