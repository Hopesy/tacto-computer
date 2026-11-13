import {win32} from 'node:path';

export function windowsPowerShellEnvironment() {
  return {PSModulePath:win32.join(process.env.SystemRoot ?? 'C:\\Windows','System32','WindowsPowerShell','v1.0','Modules')};
}

export function childEnvironment(overrides = {}, command = '') {
  const inherited = {...process.env};
  for (const name of Object.keys(inherited)) {
    if (/^npm_config_(package|call)$/i.test(name)) delete inherited[name];
  }
  Object.assign(inherited,overrides);
  if (process.platform==='win32' && /^powershell(?:\.exe)?$/i.test(win32.basename(command))) {
    // PowerShell 7 modules shadow 5.1's stock cmdlets when Node is the launcher.
    for (const name of Object.keys(inherited)) if (/^PSModulePath$/i.test(name)) delete inherited[name];
    Object.assign(inherited,windowsPowerShellEnvironment());
  }
  return inherited;
}
