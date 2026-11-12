import {spawn} from 'node:child_process';
import {readFile, writeFile, mkdir, stat} from 'node:fs/promises';
import {hostname, homedir} from 'node:os';
import {dirname, isAbsolute, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {childEnvironment} from './process-env.mjs';
import {connectAgent, disconnectAgent, cleanupRemote} from './integration.mjs';

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const metadata = JSON.parse(await readFile(join(packageRoot, 'package.json'), 'utf8'));
const help = `Tacto ${metadata.version} — Computer Use MCP

  tacto-mcp setup --local [--unattended]
  tacto-mcp setup --remote --vps-host HOST --vps-user USER [--identity-file PATH]
  tacto-mcp update|rollback|check|uninstall [--install-dir PATH] [--unattended]
  tacto-mcp mcp [--install-dir PATH]
  tacto-mcp mcp --proxy /absolute/path/cua-proxy [--ssh HOST] [--ssh-config PATH]
  tacto-mcp config [connection options] [--output PATH] [--force]
  tacto-mcp probe MCP_CONFIG_JSON [SERVER_NAME] [--health] [--smoke]
  tacto-mcp connect [connection options] --mcp-config PATH --skill-dir PATH --device-name NAME
  tacto-mcp disconnect --mcp-config PATH --device-name NAME
  tacto-mcp cleanup --receipt PATH [--identity-file PATH]

The default command is mcp. Setup runs explicitly on the controlled Windows PC.
Setup options: --device-name, --vps-port, --reverse-port, --local-ssh-port,
               --identity-file, --driver-path, --install-dir, --unattended,
               --mcp-config, --skill-dir, --browser-mode isolated|existing
Maintenance: --auto-update on|off (update), --force (update/rollback),
             --keep-config (uninstall).
Connection options: --install-dir, or --proxy with optional --ssh and --ssh-config.
`;
const flags = new Set(['local', 'remote', 'unattended', 'force', 'keep-config']);
const values = new Set(['vps-host', 'vps-user', 'vps-port', 'reverse-port', 'local-ssh-port', 'device-name', 'identity-file', 'driver-path', 'install-dir', 'proxy', 'ssh', 'ssh-config', 'output', 'mcp-config', 'skill-dir', 'browser-mode', 'auto-update', 'receipt']);
const setupOptions = new Set(['local', 'remote', 'unattended', 'vps-host', 'vps-user', 'vps-port', 'reverse-port', 'local-ssh-port', 'device-name', 'identity-file', 'driver-path', 'install-dir', 'mcp-config', 'skill-dir', 'browser-mode', 'auto-update']);
const connectionOptions = ['install-dir', 'proxy', 'ssh', 'ssh-config'];

function parse(args, allowed) {
  const options = {};
  for (let i = 0; i < args.length; i += 1) {
    const key = args[i].startsWith('--') ? args[i].slice(2) : '';
    if (!allowed.has(key) || Object.hasOwn(options, key)) throw new Error(`Unexpected or repeated argument: ${args[i]}`);
    if (flags.has(key)) options[key] = true;
    else if (values.has(key)) {
      const value = args[++i];
      if (!value || value.startsWith('--') || /[\r\n\0]/.test(value)) throw new Error(`Provide a value for --${key}`);
      options[key] = value;
    }
  }
  return options;
}

function installDirectory(options) {
  return resolve(options['install-dir'] ?? join(process.env.LOCALAPPDATA ?? join(homedir(), 'AppData', 'Local'), 'Tacto'));
}

async function file(path) {
  const absolute = resolve(path);
  if (!(await stat(absolute)).isFile()) throw new Error(`Expected a file: ${absolute}`);
  return absolute;
}

function run(command, args, env = {}) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command, args, {stdio: 'inherit', windowsHide: true, env: childEnvironment(env)});
    const interrupt = () => child.kill('SIGINT');
    const terminate = () => child.kill('SIGTERM');
    process.on('SIGINT', interrupt);
    process.on('SIGTERM', terminate);
    const cleanup = () => { process.off('SIGINT', interrupt); process.off('SIGTERM', terminate); };
    child.once('error', error => { cleanup(); reject(new Error(`Failed to start ${command}: ${error.code ?? error.message}`)); });
    child.once('exit', (code, signal) => { cleanup(); resolveResult(code ?? (signal === 'SIGINT' ? 130 : 1)); });
  });
}

async function connection(options) {
  if (options.proxy) {
    if (options['install-dir']) throw new Error('Choose one connection: --install-dir or --proxy');
    if (options.ssh) {
      if (!/^[a-zA-Z0-9][a-zA-Z0-9_.@:-]*$/.test(options.ssh)) throw new Error('Use an SSH alias or user@hostname');
      if (!options.proxy.startsWith('/')) throw new Error('The remote proxy must be an absolute Unix path');
      const args = ['-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes'];
      if (options['ssh-config']) args.push('-F', await file(options['ssh-config']));
      const quoted = "'" + options.proxy.replaceAll("'", "'\"'\"'") + "'";
      return {command: 'ssh', args: [...args, options.ssh, `exec ${quoted}`]};
    }
    if (options['ssh-config']) throw new Error('--ssh-config requires --ssh');
    if (!isAbsolute(options.proxy)) throw new Error('--proxy must be an absolute path');
    return {command: await file(options.proxy), args: []};
  }
  if (options.ssh || options['ssh-config']) throw new Error('SSH connections require --proxy');
  if (process.platform !== 'win32') throw new Error('On an Agent host, connect with --proxy /path/to/cua-proxy and optionally --ssh HOST');
  const path = join(installDirectory(options), 'desktop.json');
  let config;
  try { config = JSON.parse((await readFile(path, 'utf8')).replace(/^\uFEFF/, '')); }
  catch (error) {
    if (error.code === 'ENOENT') throw new Error('Set up this Windows PC first: npx -y tacto-mcp setup --local');
    throw new Error(`Could not read the Tacto installation config: ${path}`);
  }
  if (config.Phase !== 'complete') throw new Error('Complete or repair the installation with: npx -y tacto-mcp update');
  if (typeof config.SocketPath !== 'string' || !config.SocketPath.startsWith('\\\\.\\pipe\\')) throw new Error('The installation has an invalid CUA pipe');
  if (typeof config.DriverPath !== 'string' || !isAbsolute(config.DriverPath)) throw new Error('The installation has an invalid CUA executable path');
  if (config.RuntimePath) {
    return {command: join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), args: ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', await file(join(installDirectory(options), 'Invoke-CuaBridge.ps1')), '-ConfigPath', path, '-Local']};
  }
  return {command: await file(config.DriverPath), args: ['mcp', '--socket', config.SocketPath]};
}

async function setup(command, options) {
  if (process.platform !== 'win32') throw new Error('Run desktop setup on the controlled Windows PC; use mcp --proxy on the Agent host');
  if (options.local && options.remote) throw new Error('Choose --local or --remote');
  const action = {setup: 'Install', update: 'Update', rollback: 'Rollback', check: 'Check', uninstall: 'Uninstall'}[command];
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', join(packageRoot, 'install', 'windows', 'Setup-Tacto.ps1'), '-Action', action, '-InstallDirectory', installDirectory(options)];
  if (command === 'setup') args.push('-Mode', options.local ? 'Local' : 'Remote');
  if (options.unattended) args.push('-Unattended');
  if (options['keep-config']) args.push('-KeepConfig');
  if (options.force) args.push('-Force');
  const mapping = {'vps-host': 'VpsHost', 'vps-user': 'VpsUser', 'vps-port': 'VpsPort', 'reverse-port': 'ReversePort', 'local-ssh-port': 'LocalSshPort', 'device-name': 'DeviceName', 'identity-file': 'IdentityFile', 'driver-path': 'DriverPath', 'mcp-config': 'McpConfig', 'skill-dir': 'SkillDirectory', 'browser-mode': 'BrowserMode', 'auto-update': 'AutoUpdate'};
  for (const [name, parameter] of Object.entries(mapping)) {
    if (options[name] === undefined) continue;
    if (name.endsWith('port') && !/^\d+$/.test(options[name])) throw new Error(`--${name} must be an integer`);
    const value = name === 'identity-file' || name === 'driver-path' ? await file(options[name]) : options[name];
    args.push(`-${parameter}`, value);
  }
  if (command === 'setup' && !options['device-name']) {
    let name = hostname().toLowerCase().replace(/[^a-z0-9-]/g, '-');
    if (!/^[a-z]/.test(name)) name = `pc-${name}`;
    args.push('-DeviceName', name.slice(0, 24));
  }
  const powershell = join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return run(powershell, args);
}

async function main() {
  const args = process.argv.slice(2);
  if (args.includes('--help') || args[0] === 'help') { console.log(help); return 0; }
  if (args[0] === '--version' || args[0] === 'version') { console.log(metadata.version); return 0; }
  const command = args[0] && !args[0].startsWith('--') ? args.shift() : 'mcp';
  if (command === 'probe') {
    if (args.length < 1 || args.length > 4) throw new Error('Usage: tacto-mcp probe MCP_CONFIG_JSON [SERVER_NAME]');
    return run(process.execPath, [join(packageRoot, 'src', 'probe.mjs'), await file(args[0]), ...args.slice(1)]);
  }
  if (['setup', 'update', 'rollback', 'check', 'uninstall'].includes(command)) {
    const allowed = command === 'setup' ? setupOptions : new Set(['install-dir', 'unattended', ...(command === 'update' ? ['identity-file', 'driver-path', 'auto-update', 'mcp-config', 'skill-dir', 'browser-mode', 'force'] : []), ...(command === 'uninstall' ? ['keep-config'] : []), ...(command === 'rollback' ? ['force'] : [])]);
    return setup(command, parse(args, allowed));
  }
  if (command === 'connect') {
    const options = parse(args, new Set([...connectionOptions, 'mcp-config', 'skill-dir', 'device-name', 'browser-mode']));
    console.log(JSON.stringify(await connectAgent(options, await connection(options), packageRoot), null, 2));
    return 0;
  }
  if (command === 'disconnect') {
    const options = parse(args, new Set(['mcp-config', 'device-name']));
    console.log(JSON.stringify(await disconnectAgent(options), null, 2)); return 0;
  }
  if (command === 'cleanup') {
    const options = parse(args, new Set(['receipt', 'identity-file']));
    return cleanupRemote(options, packageRoot, run);
  }
  if (command === 'mcp' || command === 'config') {
    const options = parse(args, new Set([...connectionOptions, ...(command === 'config' ? ['output', 'force'] : [])]));
    const server = await connection(options);
    if (command === 'mcp') return run(server.command, server.args);
    const json = JSON.stringify({mcpServers: {tacto: server}}, null, 2) + '\n';
    if (options.output) {
      const output = resolve(options.output);
      await mkdir(dirname(output), {recursive: true});
      await writeFile(output, json, {encoding: 'utf8', flag: options.force ? 'w' : 'wx'});
      console.log(output);
    } else console.log(json.trimEnd());
    return 0;
  }
  throw new Error(`Unknown command: ${command}. Use tacto-mcp --help`);
}

try { process.exitCode = await main(); }
catch (error) { console.error(`Tacto: ${error.message}`); process.exitCode = 1; }
