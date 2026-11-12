import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, writeFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';

const root=dirname(dirname(fileURLToPath(import.meta.url)));
await mkdir(join(root,'.Tacto-temp'),{recursive:true});
test('CLI passes JSON through stdin, saves images locally and preserves failures',async()=>{
  const folder=await mkdtemp(join(root,'.Tacto-temp','driver-cli-'));
  const fake=join(folder,'driver.mjs');
  await writeFile(fake,`let text=''; for await(const c of process.stdin) text+=c; const req=JSON.parse(text);
if(req.tool==='fail') {console.log('action failed'); process.exit(7);}
console.log(JSON.stringify({screenshot_png_b64:Buffer.from('image fixture').toString('base64'),request:req}));`);
  const entry=join(folder,'entry.mjs');
  await writeFile(entry,`import {driverCommand} from ${JSON.stringify(new URL('../src/driver-cli.mjs',import.meta.url).href)};
try { process.exitCode=await driverCommand(process.argv.slice(2),async(options,mode)=>{if(mode!=='cli')throw Error('wrong transport');return {command:process.execPath,args:[${JSON.stringify(fake)}]};}); } catch(e){console.error(e.message);process.exitCode=1;}`);
  const invoke=(args,input='')=>spawnSync(process.execPath,[entry,...args],{input,encoding:'utf8',timeout:20000});
  const image=join(folder,'screen.png');
  const args={session:'named-work',text:'中文 ☃ '+ 'x'.repeat(10000)};
  const result=invoke(['call','get_window_state','--screenshot-out-file',image],JSON.stringify(args));
  assert.equal(result.status,0,result.stderr);
  assert.deepEqual(JSON.parse(result.stdout).request.args,args);
  assert.equal(await readFile(image,'utf8'),'image fixture');
  assert.notEqual(invoke(['call','get_window_state','{}','--screenshot-out-file',image]).status,0);
  const failure=invoke(['call','fail','{}','--screenshot-out-file',join(folder,'failed.png')]);
  assert.equal(failure.status,7);
  assert.match(failure.stdout,/action failed/);
  for(const argv of [['call','bad;name','{}'],['call','get_window_state','[]'],['stop'],['call','get_window_state','{}','--screenshot-out-file',image,'--screenshot-out-file',image]]) {
    assert.notEqual(invoke(argv).status,0);
  }
});
