import {readFile, writeFile, rename, mkdir, rm, rmdir, stat} from 'node:fs/promises';
import {dirname, join, resolve} from 'node:path';
import {createHash, randomUUID} from 'node:crypto';
import {gzipSync} from 'node:zlib';

const hash = text => createHash('sha256').update(text).digest('hex');
async function read(path) { try { return await readFile(path, 'utf8'); } catch (error) { if (error.code === 'ENOENT') return null; throw error; } }
async function atomic(path, text) {
  await mkdir(dirname(path), {recursive: true});
  const temp = `${path}.${randomUUID()}.new`;
  try { await writeFile(temp, text, {mode: 0o600, flag: 'wx'}); await rename(temp, path); }
  finally { await rm(temp, {force: true}); }
}
function paths(options) {
  if (!options['mcp-config'] || !/^[a-z][a-z0-9-]{0,23}$/.test(options['device-name'] ?? '')) throw new Error('Provide --mcp-config and a lowercase --device-name (up to 24 characters)');
  const config = resolve(options['mcp-config']);
  const device = options['device-name'];
  return {config, device, name: `computer-${device}`, receipt: `${config}.tacto-${device}.json`};
}
export async function connectAgent(options, server, packageRoot) {
  const {config, device, name, receipt} = paths(options);
  if (!options['skill-dir']) throw new Error('Provide --skill-dir, the Agent host skill directory');
  const browser = options['browser-mode'] ?? 'isolated';
  if (!['isolated', 'existing'].includes(browser)) throw new Error('Browser mode must be isolated or existing');
  const skill = join(resolve(options['skill-dir']), `tacto-${device}`, 'SKILL.md');
  const originals = new Map();
  for (const path of [config, skill, receipt]) originals.set(path, await read(path));
  const previous = originals.get(receipt) ? JSON.parse(originals.get(receipt)) : null;
  const document = originals.get(config) ? JSON.parse(originals.get(config).replace(/^\uFEFF/, '')) : {};
  if (!document || typeof document !== 'object' || Array.isArray(document)) throw new Error('Expected an MCP JSON object');
  document.mcpServers ??= {};
  if (!document.mcpServers || typeof document.mcpServers !== 'object' || Array.isArray(document.mcpServers)) throw new Error('Expected mcpServers object');
  const existing = document.mcpServers[name];
  if (existing && (!previous || JSON.stringify(existing) !== JSON.stringify(previous.server))) throw new Error(`Preserve the existing or edited ${name} entry before connecting`);
  if (originals.get(skill) && (!previous || hash(originals.get(skill)) !== previous.skillHash || previous.skill !== skill)) throw new Error('Preserve the existing or edited target Skill before connecting');
  if (previous && previous.skill !== skill) throw new Error('Disconnect the previous integration before changing its Skill directory');
  const template = await readFile(join(packageRoot, 'resources', 'tacto-skill.md'), 'utf8');
  const text = template.replaceAll('{{DEVICE}}', device).replaceAll('{{SERVER}}', name).replaceAll('{{BROWSER}}', browser);
  document.mcpServers[name] = server;
  let registry;
  let registration;
  if (options.proxy && !options.ssh) {
    const stateText = await read(join(dirname(resolve(options.proxy)), 'state.json'));
    const state = stateText && JSON.parse(stateText);
    if (state?.device === device && state.mcp?.command === resolve(options.proxy) && state.clientId) {
      registry = join(dirname(resolve(options.proxy)), 'agent-integrations.json');
      const old = await read(registry);
      originals.set(registry, old);
      const entries = old ? JSON.parse(old) : [];
      registration = [...entries.filter(entry => entry.receipt !== receipt), {clientId: state.clientId, receipt}];
    }
  }
  try {
    await atomic(config, JSON.stringify(document, null, 2) + '\n');
    await atomic(skill, text);
    await atomic(receipt, JSON.stringify({schema: 1, config, name, server, skill, skillHash: hash(text)}, null, 2) + '\n');
    if (registry) await atomic(registry, JSON.stringify(registration, null, 2) + '\n');
  } catch (error) {
    for (const [path, original] of originals) { if (original === null) await rm(path, {force: true}); else await atomic(path, original); }
    throw error;
  }
  return {ok: true, config, skill, receipt, targetPlatform: 'win32', name, deviceCleanupRegistered: Boolean(registry)};
}
export async function disconnectAgent(options) {
  const {config, name, receipt} = paths(options);
  const saved = await read(receipt);
  if (!saved) return {ok: true, alreadyDisconnected: true};
  const record = JSON.parse(saved);
  if (record.config !== config || record.name !== name) throw new Error('Integration receipt does not match this connection');
  const preserved = [];
  const source = await read(config);
  if (source) {
    const document = JSON.parse(source.replace(/^\uFEFF/, ''));
    const entry = document.mcpServers?.[name];
    if (entry && JSON.stringify(entry) === JSON.stringify(record.server)) {
      delete document.mcpServers[name]; await atomic(config, JSON.stringify(document, null, 2) + '\n');
    } else if (entry) preserved.push(config);
  }
  const text = await read(record.skill);
  if (text && hash(text) === record.skillHash) {
    await rm(record.skill);
    try { await rmdir(dirname(record.skill)); } catch (error) { if (error.code !== 'ENOTEMPTY') throw error; }
  } else if (text) preserved.push(record.skill);
  if (!preserved.length) await rm(receipt);
  return {ok: true, preserved};
}
export async function cleanupRemote(options, packageRoot, run) {
  if (!options.receipt) throw new Error('Provide --receipt from the local uninstall');
  const path = resolve(options.receipt);
  const receipt = JSON.parse(await readFile(path, 'utf8'));
  if (!/^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$/.test(receipt.host) || !/^[a-z_][a-z0-9_-]{0,31}$/.test(receipt.user) || !/^[a-z][a-z0-9-]{0,23}$/.test(receipt.device) || !Number.isInteger(receipt.port) || receipt.port < 1 || receipt.port > 65535) throw new Error('Invalid remote cleanup receipt');
  const source = gzipSync(await readFile(join(packageRoot, 'install', 'linux', 'setup-vps.py'))).toString('base64');
  const payload = Buffer.from(JSON.stringify({action: 'remove', device: receipt.device, clientId: receipt.clientId, purge: true})).toString('base64');
  const command = `python3 -c "import base64,gzip;code=gzip.decompress(base64.b64decode('${source}')).decode();exec(compile(code,'<cleanup>','exec'),dict(__name__='__main__',__file__='<cleanup>'))" ${payload}`;
  if (command.length > 29000) throw new Error('Remote cleanup command exceeds the supported SSH command size');
  const args = ['-T', '-p', String(receipt.port), '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15'];
  if (options['identity-file']) { const key = resolve(options['identity-file']); if (!(await stat(key)).isFile()) throw new Error('Expected SSH identity file'); args.push('-i', key); }
  args.push(`${receipt.user}@${receipt.host}`, command);
  const code = await run('ssh', args);
  if (code === 0) await rm(path);
  return code;
}
