import {readFile, stat} from 'node:fs/promises';
import {join, resolve} from 'node:path';
import {homedir} from 'node:os';
import {createHash} from 'node:crypto';

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
  return `${platform==='win32'?'npx.cmd':'npx'} -y tacto-mcp@latest driver${args.length?' '+args.join(' '):''}`;
}
export async function skillFiles(packageRoot, device, browser, prefix) {
  const template=await readFile(join(packageRoot,'resources','tacto-skill.md'),'utf8');
  const files={'SKILL.md':template.replaceAll('{{DEVICE}}',device).replaceAll('{{SERVER}}',`computer-${device}`).replaceAll('{{BROWSER}}',browser).replaceAll('{{CLI}}',prefix)};
  const folder=join(packageRoot,'resources','cua-skill');
  const manifest=JSON.parse(await readFile(join(folder,'source.json'),'utf8'));
  for (const name of [...Object.keys(manifest.files),'source.json','LICENSE']) {
    if (!/^[A-Za-z0-9_.-]+$/.test(name)) throw new Error('Invalid official Skill filename');
    const content=await readFile(join(folder,name),'utf8');
    if (manifest.files[name] && hash(content)!==manifest.files[name]) throw new Error(`Official Skill checksum mismatch: ${name}`);
    files[`official/${name}`]=content;
  }
  return files;
}
