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
  const marker=join(folder,'invoked.count');
  await writeFile(fake,`import {writeFileSync, readFileSync} from 'node:fs';
let count=0; try { count=Number(readFileSync(${JSON.stringify(marker)},'utf8')); } catch {}
writeFileSync(${JSON.stringify(marker)},String(count+1));
let text=''; for await(const c of process.stdin) text+=c; const req=JSON.parse(text);
if(req.tool==='fail') {console.log('action failed'); process.exit(7);}
if(req.tool==='no_image') {console.log(JSON.stringify({ok:true,applied:true})); process.exit(0);}
console.log(JSON.stringify({screenshot_png_b64:Buffer.from('image fixture').toString('base64'),request:req}));`);
  const entry=join(folder,'entry.mjs');
  await writeFile(entry,`import {driverCommand} from ${JSON.stringify(new URL('../src/driver-cli.mjs',import.meta.url).href)};
try { process.exitCode=await driverCommand(process.argv.slice(2),async(options,mode)=>{if(mode!=='cli')throw Error('wrong transport');return {command:process.execPath,args:[${JSON.stringify(fake)}]};}); } catch(e){console.error(e.message);process.exitCode=1;}`);
  const invoke=(args,input='')=>spawnSync(process.execPath,[entry,...args],{input,encoding:'utf8',timeout:20000});
  const image=join(folder,'screen.png');
  const args={session:'named-work',text:'中文 ☃ '+ 'x'.repeat(10000)};
  const result=invoke(['call','get_window_state',`--screenshot-out-file=${image}`],JSON.stringify(args));
  assert.equal(result.status,0,result.stderr);
  const parsed=JSON.parse(result.stdout);
  assert.deepEqual(parsed.request.args,args);
  assert.equal(parsed.screenshot_png_b64,undefined);
  assert.equal(parsed.screenshot_file,image);
  assert.equal(await readFile(image,'utf8'),'image fixture');
  const beforeExisting=Number(await readFile(marker,'utf8'));
  assert.notEqual(invoke(['call','get_window_state','{}','--screenshot-out-file',image]).status,0);
  assert.equal(Number(await readFile(marker,'utf8')),beforeExisting);
  const shorthand=invoke(['list_windows','{"session":"named-work"}']);
  assert.equal(shorthand.status,0,shorthand.stderr);
  assert.equal(JSON.parse(shorthand.stdout).request.tool,'list_windows');
  const remoteImage=join(folder,'remote-screen.png');
  const remoteShot=invoke(['--proxy','/fixture/cua-proxy','get_window_state',JSON.stringify({session:'named-work',screenshot_out_file:remoteImage})]);
  assert.equal(remoteShot.status,0,remoteShot.stderr);
  const remoteParsed=JSON.parse(remoteShot.stdout);
  assert.equal(remoteParsed.request.args.screenshot_out_file,undefined);
  assert.equal(remoteParsed.screenshot_file,remoteImage);
  assert.equal(await readFile(remoteImage,'utf8'),'image fixture');
  const noImage=invoke(['no_image','{}','--screenshot-out-file',join(folder,'missing.png')]);
  assert.notEqual(noImage.status,0);
  assert.equal(JSON.parse(noImage.stdout).applied,true);
  const failure=invoke(['call','fail','{}','--screenshot-out-file',join(folder,'failed.png')]);
  assert.equal(failure.status,7);
  assert.match(failure.stdout,/action failed/);
  for(const argv of [['call','bad;name','{}'],['call','get_window_state','[]'],['stop'],['revoke'],['call','stop','{}'],['recording','start'],['-x','list_windows'],['call','get_window_state','{}','--screenshot-out-file',image,'--screenshot-out-file',image],['--proxy','/fixture/cua-proxy','get_window_state',JSON.stringify({screenshot_out_file:join(folder,'dup1.png')}),'--screenshot-out-file',join(folder,'dup2.png')]]) {
    assert.notEqual(invoke(argv).status,0);
  }
});
