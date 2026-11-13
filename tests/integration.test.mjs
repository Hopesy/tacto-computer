import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, writeFile, access, readdir} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {connectAgent, disconnectAgent, cleanupRemote} from '../src/integration.mjs';
import {gunzipSync} from 'node:zlib';
import {detectSkillDirectories, hash} from '../src/skills.mjs';

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
  assert.match(text, /^---\nname: tacto-computer\n/);
  assert.match(text, /tacto-mcp/);
  assert.match(text, /--package tacto-computer@latest tacto-cli/);
  assert.equal(dirname(result.skill),join(options['skill-dir'],'tacto-computer'));
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
  document.mcpServers['tacto-mcp'].command = 'user-edited';
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
  const foreign = JSON.stringify({mcpServers: {'tacto-mcp': server}});
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
  await writeFile(join(device, 'state.json'), JSON.stringify({managementVersion:2, clientId: 'owned-id', device: 'office', mcp: direct}));
  await assert.rejects(connectAgent({...options, proxy}, direct, root), /Update Tacto/);
  await assert.rejects(connectAgent({...options, proxy, 'skill-dir':undefined, 'no-skills':true}, direct, root), /Update Tacto/);
  await assert.rejects(access(options['mcp-config']+'.tacto-office.json'), {code:'ENOENT'});
  await writeFile(join(device, 'state.json'), JSON.stringify({managementVersion:3, clientId: 'owned-id', device: 'office', mcp: direct}));
  const result = await connectAgent({...options, proxy}, direct, root);
  assert.equal(result.deviceCleanupRegistered, true);
  assert.deepEqual(JSON.parse(await readFile(join(device, 'agent-integrations.json'))), [{clientId:'owned-id', receipt:result.receipt}]);
});
test('one device Skill exposes linked CUA references with provenance and preserves edits',async()=>{
  const {options}=await fixture();
  const result=await connectAgent(options,server,root);
  const folder=dirname(result.skill);
  const manifest=JSON.parse(await readFile(join(root,'resources/cua-skill/source.json')));
  const installed=JSON.parse(await readFile(join(folder,'references','source.json')));
  assert.deepEqual(installed.files,manifest.files);
  for(const [name,digest] of Object.entries(installed.adaptation.files)) assert.equal(hash(await readFile(join(folder,'references',name))),digest);
  assert.equal(hash(await readFile(join(folder,'references','BROWSER.md'))),manifest.files['BROWSER.md']);
  const paths=await readdir(folder,{recursive:true});
  assert.deepEqual(paths.filter(path=>path.split(/[\\/]/).at(-1)==='SKILL.md'),['SKILL.md']);
  assert.match(await readFile(join(folder,'references','CUA.md'),'utf8'),/^# cua-driver/);
  for(const path of paths.filter(path=>path.endsWith('.md'))) {
    const text=await readFile(join(folder,path),'utf8');
    if(path!=='SKILL.md') assert.doesNotMatch(text,/SKILL\.md/);
    for(const [,target] of text.matchAll(/\]\(([^)]+)\)/g)) {
      if(!/^(?:[a-z]+:|#)/i.test(target)) await access(join(dirname(join(folder,path)),target.split('#')[0]));
    }
  }
  const changed=join(folder,'references','WINDOWS.md');
  await writeFile(changed,'user extension');
  await assert.rejects(connectAgent(options,server,root),/edited/);
  assert.deepEqual((await disconnectAgent(options)).preserved,[changed]);
  assert.equal(await readFile(changed,'utf8'),'user extension');
  await assert.rejects(access(join(folder,'references','RUNTIME.md')),{code:'ENOENT'});
});

test('0.3.0 nested Skill migrates by ownership and preserves an edited legacy guide',async()=>{
  const {options}=await fixture();
  const folder=join(options['skill-dir'],'tacto-office');
  const texts={'SKILL.md':'legacy adapter','official/SKILL.md':'---\nname: cua-driver\n---\nlegacy guide','official/WINDOWS.md':'legacy windows'};
  const files=[];
  for(const [name,text] of Object.entries(texts)) {
    const path=join(folder,name); await mkdir(dirname(path),{recursive:true}); await writeFile(path,text);
    files.push({root:folder,path,hash:hash(text)});
  }
  const receipt=options['mcp-config']+'.tacto-office.json';
  const original=JSON.stringify({schema:2,config:options['mcp-config'],name:'computer-office',server,files});
  await writeFile(receipt,original);
  const oldDocument=JSON.parse(await readFile(options['mcp-config']));
  oldDocument.mcpServers['computer-office']=server;
  await writeFile(options['mcp-config'],JSON.stringify(oldDocument));
  const edited=join(folder,'official','WINDOWS.md');
  await writeFile(edited,'user extension');
  await assert.rejects(connectAgent(options,server,root),/edited/);
  assert.equal(await readFile(receipt,'utf8'),original);
  assert.equal(await readFile(edited,'utf8'),'user extension');
  await writeFile(edited,texts['official/WINDOWS.md']);
  const result=await connectAgent(options,server,root);
  await assert.rejects(access(folder),{code:'ENOENT'});
  await access(join(dirname(result.skill),'references','CUA.md'));
  const migrated=JSON.parse(await readFile(options['mcp-config']));
  assert.equal(migrated.mcpServers['computer-office'],undefined);
  assert.deepEqual(migrated.mcpServers['tacto-mcp'],server);
  await disconnectAgent(options);
  await assert.rejects(access(folder),{code:'ENOENT'});
  await assert.rejects(access(dirname(result.skill)),{code:'ENOENT'});
});

test('fixed names preserve another device and edited legacy MCP configuration',async()=>{
  const {options}=await fixture();
  const result=await connectAgent(options,server,root);
  await assert.rejects(connectAgent({...options,'device-name':'home'},server,root),/existing|edited/);
  await disconnectAgent(options);
  const legacy=JSON.stringify({schema:1,config:options['mcp-config'],name:'computer-office',server});
  await writeFile(result.receipt,legacy);
  const document={mcpServers:{'computer-office':{command:'user-edited'}}};
  await writeFile(options['mcp-config'],JSON.stringify(document));
  await assert.rejects(connectAgent(options,server,root),/edited computer-office/);
  assert.deepEqual(JSON.parse(await readFile(options['mcp-config'])),document);
  assert.equal(await readFile(result.receipt,'utf8'),legacy);
});
test('MCP-only connection and supported Skill directory detection',async()=>{
  const {folder,options}=await fixture();
  const result=await connectAgent({...options,'skill-dir':undefined,'no-skills':true},server,root);
  assert.equal(result.skill,null);
  assert.deepEqual((await disconnectAgent(options)).preserved,[]);
  await mkdir(join(folder,'.codex'));
  await mkdir(join(folder,'.cursor'));
  await mkdir(join(folder,'.claude'));
  assert.deepEqual((await detectSkillDirectories(folder,{})).sort(),[join(folder,'.agents','skills'),join(folder,'.claude','skills')].sort());
});
test('legacy one-file receipt migrates to official pack and CLI binds the selected target',async()=>{
  const {options}=await fixture();
  const skill=join(options['skill-dir'],'tacto-office','SKILL.md');
  await mkdir(dirname(skill),{recursive:true}); await writeFile(skill,'old managed skill');
  const receipt=options['mcp-config']+'.tacto-office.json';
  await writeFile(receipt,JSON.stringify({schema:1,config:options['mcp-config'],name:'computer-office',server,skill,skillHash:hash('old managed skill')}));
  const result=await connectAgent({...options,proxy:"/home/agent's files/cua-proxy",ssh:'my-vps'},server,root);
  assert.match(await readFile(result.skill,'utf8'),/--ssh 'my-vps'/);
  assert.equal(JSON.parse(await readFile(receipt)).files.length,14);
  await disconnectAgent(options);
  await assert.rejects(access(dirname(skill)),{code:'ENOENT'});
  await assert.rejects(access(dirname(result.skill)),{code:'ENOENT'});
});
