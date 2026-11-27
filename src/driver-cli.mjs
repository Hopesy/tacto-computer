import {spawn} from 'node:child_process';
import {writeFile, mkdir, stat} from 'node:fs/promises';
import {dirname, resolve} from 'node:path';
import {childEnvironment} from './process-env.mjs';

const managementCommands = new Set(['list-tools', 'describe', 'doctor', 'status', 'version']);
const blockedCommands = new Set(['stop', 'serve', 'revoke', 'config', 'telemetry', 'recording', 'update', 'check-update', 'diagnose', 'permissions', 'autostart', 'skills', 'manifest', 'extension', 'perception', 'channel', 'cursor', 'sessions', 'history', 'connect', 'test', 'mcp']);
const valuedOptions = new Set(['--install-dir', '--proxy', '--ssh', '--ssh-config', '--screenshot-out-file']);

export async function driverCommand(argv, connect) {
  const options = {}, positional = [];
  let screenshot;
  for (let i=0; i<argv.length; i++) {
    const raw=argv[i];
    const eq=raw.startsWith('--') ? raw.indexOf('=') : -1;
    const token=eq===-1 ? raw : raw.slice(0, eq);
    if (valuedOptions.has(token)) {
      const value=eq===-1 ? argv[++i] : raw.slice(eq+1);
      if (!value || (eq===-1 && value.startsWith('--')) || /[\r\n\0]/.test(value)) throw new Error(`Provide a value for ${token}`);
      if (token === '--screenshot-out-file') { if (screenshot) throw new Error(`Repeated option ${token}`); screenshot=resolve(value); }
      else { if (options[token.slice(2)]) throw new Error(`Repeated option ${token}`); options[token.slice(2)]=value; }
    } else if (raw === '--version') positional.push('version');
    else if (raw === '--json') { /* doctor already uses structured output. */ }
    else if (raw.startsWith('-')) throw new Error(`Unknown Driver option: ${token}`);
    else positional.push(raw);
  }
  let [command, tool, input, ...extra]=positional;
  if (command && command !== 'call' && !managementCommands.has(command) && !blockedCommands.has(command) && /^[a-z][a-z0-9_]*$/.test(command)) {
    extra=input === undefined ? [] : [input, ...extra];
    input=tool;
    tool=command;
    command='call';
  }
  if (command !== 'call' && !managementCommands.has(command)) throw new Error('Use driver [call] TOOL|list-tools|describe|doctor|status|--version');
  if (extra.length || (command === 'describe' && input !== undefined) || (!['call','describe'].includes(command) && tool !== undefined)) throw new Error('Unexpected Driver arguments');
  if (['call','describe'].includes(command) && (blockedCommands.has(tool ?? '') || !/^[a-z][a-z0-9_]*$/.test(tool ?? ''))) throw new Error('Provide the advertised tool name');
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
    if ((options.proxy || options.ssh) && typeof args.screenshot_out_file === 'string' && args.screenshot_out_file) {
      if (screenshot) throw new Error('Specify either --screenshot-out-file or JSON screenshot_out_file, not both');
      if (/[\r\n\0]/.test(args.screenshot_out_file)) throw new Error('Invalid screenshot_out_file path');
      screenshot = resolve(args.screenshot_out_file);
      delete args.screenshot_out_file;
    }
  }
  if (screenshot && command !== 'call') throw new Error('--screenshot-out-file requires a tool call');
  if (screenshot) {
    try { await stat(screenshot); throw new Error(`Screenshot output file already exists: ${screenshot}`); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
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
          let result;
          try { result=JSON.parse(text); } catch (error) { process.stdout.write(text); throw error; }
          const topImage=typeof result.screenshot_png_b64==='string' ? result.screenshot_png_b64 : null;
          const items=result.content ?? result.result?.content ?? [];
          const contentImage=!topImage ? items.find(item=>item.type==='image' && typeof item.data==='string') : null;
          const data=topImage ?? contentImage?.data;
          if (!data) {
            process.stdout.write(text);
            throw new Error('The tool returned no image');
          }
          try {
            await mkdir(dirname(screenshot),{recursive:true});
            await writeFile(screenshot,Buffer.from(data,'base64'),{flag:'wx'});
          } catch (error) {
            if (topImage !== null) delete result.screenshot_png_b64;
            for (const item of items) if (item.type==='image' && typeof item.data==='string') delete item.data;
            process.stdout.write(JSON.stringify(result)+'\n');
            throw error;
          }
          if (topImage !== null) delete result.screenshot_png_b64;
          for (const item of items) if (item.type==='image' && typeof item.data==='string') { delete item.data; item.screenshot_file=screenshot; }
          result.screenshot_file=screenshot;
          process.stdout.write(JSON.stringify(result)+'\n');
        }
        resolveExit(code ?? 1);
      } catch(error) { reject(error); }
    });
  });
}
