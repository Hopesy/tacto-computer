import {spawn} from 'node:child_process';
import {writeFile, mkdir} from 'node:fs/promises';
import {dirname, resolve} from 'node:path';
import {childEnvironment} from './process-env.mjs';

export async function driverCommand(argv, connect) {
  const options = {}, positional = [];
  let screenshot;
  for (let i=0; i<argv.length; i++) {
    const token=argv[i];
    if (['--install-dir','--proxy','--ssh','--ssh-config','--screenshot-out-file'].includes(token)) {
      const value=argv[++i];
      if (!value || value.startsWith('--') || /[\r\n\0]/.test(value)) throw new Error(`Provide a value for ${token}`);
      if (token === '--screenshot-out-file') { if (screenshot) throw new Error(`Repeated option ${token}`); screenshot=resolve(value); }
      else { if (options[token.slice(2)]) throw new Error(`Repeated option ${token}`); options[token.slice(2)]=value; }
    } else if (token === '--version') positional.push('version');
    else if (token === '--json') { /* doctor already uses structured output. */ }
    else if (token.startsWith('--')) throw new Error(`Unknown Driver option: ${token}`);
    else positional.push(token);
  }
  const [command, tool, input, ...extra]=positional;
  if (!['call','list-tools','describe','doctor','status','version'].includes(command)) throw new Error('Use driver call|list-tools|describe|doctor|status|--version');
  if (extra.length || (command === 'describe' && input !== undefined) || (!['call','describe'].includes(command) && tool !== undefined)) throw new Error('Unexpected Driver arguments');
  if (['call','describe'].includes(command) && !/^[a-z][a-z0-9_]*$/.test(tool ?? '')) throw new Error('Provide the advertised tool name');
  let args={};
  if (command === 'call') {
    let text=input;
    if (text === undefined && !process.stdin.isTTY) {
      const chunks=[]; let length=0;
      for await (const chunk of process.stdin) { length+=chunk.length; if (length>8*1024*1024) throw new Error('Tool input exceeds 8 MiB'); chunks.push(chunk); }
      text=Buffer.concat(chunks).toString('utf8').trim();
    }
    if (Buffer.byteLength(text ?? '', 'utf8')>8*1024*1024) throw new Error('Tool input exceeds 8 MiB');
    args=text ? JSON.parse(text) : {};
    if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error('Tool arguments must be a JSON object');
  }
  if (screenshot && command !== 'call') throw new Error('--screenshot-out-file requires a tool call');
  const target=await connect(options,'cli');
  return new Promise((resolveExit,reject) => {
    const child=spawn(target.command,target.args,{stdio:['pipe',screenshot?'pipe':'inherit','inherit'],windowsHide:true,env:childEnvironment(target.env,target.command)});
    const chunks=[]; let length=0;
    if (screenshot) child.stdout.on('data',chunk=>{ length+=chunk.length; if (length>64*1024*1024) { child.kill(); reject(new Error('Screenshot response exceeds 64 MiB')); } else chunks.push(chunk); });
    const stop=()=>child.kill();
    process.on('SIGINT',stop); process.on('SIGTERM',stop);
    const cleanup=()=>{process.off('SIGINT',stop);process.off('SIGTERM',stop);};
    child.on('error',error=>{cleanup();reject(error);});
    child.stdin.on('error',()=>{});
    child.stdin.end(JSON.stringify({command,tool,args})+'\n');
    child.on('close',async code=>{
      cleanup();
      try {
        if (screenshot && code!==0) process.stdout.write(Buffer.concat(chunks));
        if (screenshot && code===0) {
          const text=Buffer.concat(chunks).toString('utf8');
          const result=JSON.parse(text);
          const image=typeof result.screenshot_png_b64==='string' ? {data:result.screenshot_png_b64} : (result.content ?? result.result?.content ?? []).find(item=>item.type==='image' && typeof item.data==='string');
          if (!image) throw new Error('The tool returned no image');
          await mkdir(dirname(screenshot),{recursive:true});
          await writeFile(screenshot,Buffer.from(image.data,'base64'),{flag:'wx'});
          process.stdout.write(text);
        }
        resolveExit(code ?? 1);
      } catch(error) { reject(error); }
    });
  });
}
