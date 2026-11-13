import {readFile, stat} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {homedir} from 'node:os';
import {createHash} from 'node:crypto';
import {metadata, cliName, skillName, mcpName} from './product.mjs';

export const hash = text => createHash('sha256').update(text).digest('hex');
export async function detectSkillDirectories(home=homedir(), env=process.env) {
  const candidates = [
    [join(home,'.claude'), join(home,'.claude','skills')],
    [env.CODEX_HOME || join(home,'.codex'), env.CODEX_HOME ? join(env.CODEX_HOME,'skills') : join(home,'.agents','skills')],
    [join(home,'.cursor'), join(home,'.agents','skills')],
    [join(home,'.pi','agent'), join(home,'.agents','skills')],
    [join(home,'.factory'), join(home,'.factory','skills')],
    [join(home,'.openclaw'), join(home,'.openclaw','skills')],
    [join(home,'.config','opencode'), join(home,'.config','opencode','skills')],
  ];
  const found=[];
  for (const [marker,directory] of candidates) {
    try { if ((await stat(marker)).isDirectory()) found.push(resolve(directory)); }
    catch (error) { if (error.code!=='ENOENT') throw error; }
  }
  return [...new Set(found)];
}
export function cliPrefix(options, platform=process.platform) {
  const quote=value=>platform==='win32' ? `'${value.replaceAll("'","''")}'` : `'${value.replaceAll("'", "'\"'\"'")}'`;
  const args=[];
  for (const key of ['install-dir','proxy','ssh','ssh-config']) if (options[key]) args.push(`--${key}`,quote(options[key]));
  return `${platform==='win32'?'npx.cmd':'npx'} -y --package ${metadata.name}@latest ${cliName} driver${args.length?' '+args.join(' '):''}`;
}
export async function skillFiles(packageRoot, device, browser, prefix) {
  const template=await readFile(join(packageRoot,'resources','tacto-skill.md'),'utf8');
  const files={'SKILL.md':template.replaceAll('{{SKILL}}',skillName).replaceAll('{{DEVICE}}',device).replaceAll('{{SERVER}}',mcpName).replaceAll('{{BROWSER}}',browser).replaceAll('{{CLI}}',prefix)};
  const references=JSON.parse(await readFile(join(packageRoot,'install','skill-references.json'),'utf8'));
  return {...files,...references};
}
