import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, writeFile, access} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {connectAgent, disconnectAgent, cleanupRemote} from '../src/integration.mjs';
import {gunzipSync} from 'node:zlib';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
await mkdir(join(root, '.Tacto-temp'), {recursive: true});
const server = {command: 'ssh', args: ['test-vps', 'exec /home/test/.tacto/devices/office/cua-proxy']};
test('remote cleanup uses a bounded compressed bootstrap and retains receipt after failure', async () => {
  const {folder} = await fixture();
  const receipt=join(folder,'cleanup.json');
  await writeFile(receipt,JSON.stringify({host:'example.test',user:'tester',port:22,device:'office',clientId:'owned'}));
  const run=async (command,args) => {
    assert.equal(command,'ssh');
    const remote=args.at(-1);
    assert.ok(remote.length < 29000);
    const encoded=remote.match(/b64decode\('([^']+)'\)/)[1];
    assert.equal(gunzipSync(Buffer.from(encoded,'base64')).toString(),await readFile(join(root,'install/linux/setup-vps.py'),'utf8'));
    return 1;
  };
  assert.equal(await cleanupRemote({receipt},root,run),1);
  await access(receipt);
  assert.equal(await cleanupRemote({receipt},root,async()=>0),0);
  await assert.rejects(access(receipt),{code:'ENOENT'});
});
async function fixture() {
  const folder = await mkdtemp(join(root, '.Tacto-temp', 'integration-'));
  const options = {'mcp-config': join(folder, 'agent.json'), 'skill-dir': join(folder, 'skills'), 'device-name': 'office'};
  const original = {theme: 'dark', mcpServers: {unrelated: {command: 'unrelated', args: []}}};
  await writeFile(options['mcp-config'], JSON.stringify(original));
  return {folder, options, original};
}
test('connect/update/disconnect preserves unrelated settings and binds Windows target', async () => {
  const {options, original} = await fixture();
  const result = await connectAgent(options, server, root);
  const text = await readFile(result.skill, 'utf8');
  assert.match(text, /computer-office/);
  assert.match(text, /controlled platform is \*\*Windows\*\*/);
  await connectAgent({...options, 'browser-mode': 'existing'}, server, root);
  assert.match(await readFile(result.skill, 'utf8'), /\*\*existing\*\*/);
  assert.deepEqual(await disconnectAgent(options), {ok: true, preserved: []});
  assert.deepEqual(JSON.parse(await readFile(options['mcp-config'])), original);
  await assert.rejects(access(result.skill), {code: 'ENOENT'});
  assert.equal((await disconnectAgent(options)).alreadyDisconnected, true);
});
test('edited client entries and Skills survive disconnect', async () => {
  const {options} = await fixture();
  const result = await connectAgent(options, server, root);
  const document = JSON.parse(await readFile(options['mcp-config']));
  document.mcpServers['computer-office'].command = 'user-edited';
  await writeFile(options['mcp-config'], JSON.stringify(document));
  await writeFile(result.skill, 'user edited Skill');
  await assert.rejects(connectAgent(options, server, root), /edited/);
  assert.equal((await disconnectAgent(options)).preserved.length, 2);
  assert.equal(await readFile(result.skill, 'utf8'), 'user edited Skill');
});
test('failed Skill creation rolls back the client configuration', async () => {
  const {folder, options, original} = await fixture();
  const blocked = join(folder, 'file-instead-of-directory');
  await writeFile(blocked, 'keep');
  await assert.rejects(connectAgent({...options, 'skill-dir': blocked}, server, root));
  assert.deepEqual(JSON.parse(await readFile(options['mcp-config'])), original);
});
test('existing foreign server and malformed JSON remain untouched', async () => {
  const {options} = await fixture();
  const foreign = JSON.stringify({mcpServers: {'computer-office': server}});
  await writeFile(options['mcp-config'], foreign);
  await assert.rejects(connectAgent(options, server, root), /existing/);
  assert.equal(await readFile(options['mcp-config'], 'utf8'), foreign);
  await writeFile(options['mcp-config'], '{broken');
  await assert.rejects(connectAgent(options, server, root));
  assert.equal(await readFile(options['mcp-config'], 'utf8'), '{broken');
});
test('VPS-local integration records cleanup ownership for its device', async () => {
  const {folder, options} = await fixture();
  const device = join(folder, '.tacto', 'devices', 'office');
  await mkdir(device, {recursive: true});
  const proxy = join(device, 'cua-proxy');
  const direct = {command: proxy, args: []};
  await writeFile(join(device, 'state.json'), JSON.stringify({clientId: 'owned-id', device: 'office', mcp: direct}));
  const result = await connectAgent({...options, proxy}, direct, root);
  assert.equal(result.deviceCleanupRegistered, true);
  assert.deepEqual(JSON.parse(await readFile(join(device, 'agent-integrations.json'))), [{clientId:'owned-id', receipt:result.receipt}]);
});
