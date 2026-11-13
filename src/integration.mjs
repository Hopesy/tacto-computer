import {readFile, writeFile, rename, mkdir, rm, rmdir, stat} from 'node:fs/promises';
import {dirname, basename, join, resolve, relative} from 'node:path';
import {randomUUID} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {hash, skillFiles, cliPrefix, detectSkillDirectories} from './skills.mjs';
import {skillName, mcpName} from './product.mjs';

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
  return {config, device, name: mcpName, receipt: `${config}.tacto-${device}.json`};
}
function assertReceipt(record, config, device) {
  if (record.config!==config || ![mcpName,`computer-${device}`].includes(record.name) || (record.device && record.device!==device)) throw new Error('Integration receipt does not match this connection');
}
function ownedFiles(record) {
  if (!record) return [];
  const files=record.files ?? (record.skill ? [{path:record.skill,hash:record.skillHash,root:dirname(record.skill)}] : []);
  for (const file of files) {
    const local=relative(file.root,file.path).replaceAll('\\','/');
    const expectedRoot=record.name===mcpName ? skillName : record.name.replace(/^computer-/,'tacto-');
    if (basename(file.root)!==expectedRoot || !/^(SKILL\.md|(?:official|references)\/[A-Za-z0-9_.-]+)$/.test(local)) throw new Error('Invalid Skill ownership path');
  }
  return files;
}
async function prune(files) {
  const dirs=[...new Set(files.flatMap(file=>[dirname(file.path),file.root]))].sort((a,b)=>b.length-a.length);
  for (const dir of dirs) { try { await rmdir(dir); } catch(error) { if (!['ENOENT','ENOTEMPTY','EEXIST'].includes(error.code)) throw error; } }
}
export async function connectAgent(options, server, packageRoot) {
  const {config, device, name, receipt} = paths(options);
  if (options['no-skills'] && options['skill-dir']) throw new Error('Choose --skill-dir or --no-skills');
  const browser = options['browser-mode'] ?? 'isolated';
  if (!['isolated', 'existing'].includes(browser)) throw new Error('Browser mode must be isolated or existing');
  const originals = new Map([[config,await read(config)],[receipt,await read(receipt)]]);
  const previous = originals.get(receipt) ? JSON.parse(originals.get(receipt)) : null;
  if (previous) assertReceipt(previous,config,device);
  const oldFiles=ownedFiles(previous);
  const directories=options['no-skills'] ? [] : options['skill-dir'] ? [resolve(options['skill-dir'])] : previous ? [...new Set(oldFiles.map(file=>dirname(file.root)))] : await detectSkillDirectories();
  const roots=directories.map(dir=>join(dir,skillName));
  const content=roots.length ? await skillFiles(packageRoot,device,browser,cliPrefix(options)) : {};
  const files=roots.flatMap(root=>Object.entries(content).map(([name,text])=>({root,path:join(root,name),hash:hash(text),text})));
  const oldMap=new Map(oldFiles.map(file=>[file.path,file]));
  for (const file of [...files,...oldFiles]) {
    if (!originals.has(file.path)) originals.set(file.path,await read(file.path));
    const text=originals.get(file.path);
    if (text!==null && hash(text)!==oldMap.get(file.path)?.hash) throw new Error('Preserve the existing or edited target Skill before connecting');
  }
  const document = originals.get(config) ? JSON.parse(originals.get(config).replace(/^\uFEFF/, '')) : {};
  if (!document || typeof document !== 'object' || Array.isArray(document)) throw new Error('Expected an MCP JSON object');
  document.mcpServers ??= {};
  if (!document.mcpServers || typeof document.mcpServers !== 'object' || Array.isArray(document.mcpServers)) throw new Error('Expected mcpServers object');
  const existing = document.mcpServers[name];
  if (existing && (!previous || previous.name!==name || JSON.stringify(existing) !== JSON.stringify(previous.server))) throw new Error(`Preserve the existing or edited ${name} entry before connecting`);
  if (previous && previous.name!==name) {
    const oldEntry=document.mcpServers[previous.name];
    if (oldEntry && JSON.stringify(oldEntry)!==JSON.stringify(previous.server)) throw new Error(`Preserve the edited ${previous.name} entry before connecting`);
    delete document.mcpServers[previous.name];
  }
  document.mcpServers[name] = server;
  let registry, registration;
  if (options.proxy && !options.ssh) {
    const stateText = await read(join(dirname(resolve(options.proxy)), 'state.json'));
    const state = stateText && JSON.parse(stateText);
    if (state?.device === device && state.mcp?.command === resolve(options.proxy) && state.clientId) {
      if ((state.managementVersion ?? 0)<3) throw new Error('Update Tacto on the Windows PC before registering the new MCP and Skill names on this VPS');
      registry = join(dirname(resolve(options.proxy)), 'agent-integrations.json');
      const old = await read(registry);
      originals.set(registry, old);
      const entries = old ? JSON.parse(old) : [];
      registration = [...entries.filter(entry => entry.receipt !== receipt), {clientId: state.clientId, receipt}];
    }
  }
  const skill=files.find(file=>file.path===join(file.root,'SKILL.md'))?.path ?? null;
  try {
    await atomic(config, JSON.stringify(document, null, 2) + '\n');
    for (const file of files) await atomic(file.path,file.text);
    const desired=new Set(files.map(file=>file.path));
    for (const file of oldFiles) if (!desired.has(file.path)) await rm(file.path,{force:true});
    await atomic(receipt, JSON.stringify({schema:2,config,device,name,server,skill,skillHash:skill?hash(content['SKILL.md']):null,files:files.map(({text,...file})=>file)}, null, 2) + '\n');
    if (registry) await atomic(registry, JSON.stringify(registration, null, 2) + '\n');
  } catch (error) {
    for (const [path, original] of originals) { if (original === null) await rm(path, {force: true}); else await atomic(path, original); }
    await prune(files);
    throw error;
  }
  await prune(oldFiles);
  return {ok:true,config,skill,skills:roots,receipt,targetPlatform:'win32',name,deviceCleanupRegistered:Boolean(registry)};
}
export async function disconnectAgent(options) {
  const {config, device, receipt} = paths(options);
  const saved = await read(receipt);
  if (!saved) return {ok: true, alreadyDisconnected: true};
  const record = JSON.parse(saved);
  assertReceipt(record,config,device);
  const name=record.name;
  const files=ownedFiles(record);
  const preserved = [];
  const source = await read(config);
  if (source) {
    const document = JSON.parse(source.replace(/^\uFEFF/, ''));
    const entry = document.mcpServers?.[name];
    if (entry && JSON.stringify(entry) === JSON.stringify(record.server)) {
      delete document.mcpServers[name]; await atomic(config, JSON.stringify(document, null, 2) + '\n');
    } else if (entry) preserved.push(config);
  }
  for (const file of files) {
    const text=await read(file.path);
    if (text!==null && hash(text)===file.hash) await rm(file.path);
    else if (text!==null) preserved.push(file.path);
  }
  await prune(files);
  if (!preserved.length) await rm(receipt);
  return {ok:true,preserved};
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
