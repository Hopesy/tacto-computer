import {readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';

// Compile once; Node and standalone PowerShell installers consume this same bundle.
const root = new URL('../', import.meta.url);
const upstream = new URL('resources/cua-skill/', root);
const digest = value => createHash('sha256').update(value).digest('hex');
const source = JSON.parse(await readFile(new URL('source.json', upstream), 'utf8'));
const files = {}, installedHashes = {};
for (const name of [...new Set([...Object.keys(source.files), 'LICENSE'])].sort()) {
  if (!/^[A-Za-z0-9_.-]+$/.test(name)) throw new Error(`Invalid official filename: ${name}`);
  let content = await readFile(new URL(name, upstream), 'utf8');
  if (source.files[name] && digest(content) !== source.files[name]) throw new Error(`Official Skill checksum mismatch: ${name}`);
  if (name === 'SKILL.md') {
    const frontmatter = /^---\r?\n[\s\S]*?\r?\n---\r?\n/;
    if (!frontmatter.test(content)) throw new Error('Expected official Skill frontmatter');
    content = content.replace(frontmatter, '').replace(/^\r?\n/, '');
  }
  // Both Markdown links and prose mention the upstream entrypoint.
  if (name.endsWith('.md')) content = content.replaceAll('SKILL.md', 'CUA.md');
  const target = name === 'SKILL.md' ? 'CUA.md' : name;
  files[`references/${target}`] = content;
  installedHashes[target] = digest(content);
}
files['references/source.json'] = JSON.stringify({...source, adaptation: {
  format: 1,
  description: 'SKILL.md becomes CUA.md without YAML frontmatter; Markdown references to SKILL.md become CUA.md. Other content is preserved.',
  files: installedHashes,
}}, null, 2) + '\n';
const output = new URL('install/skill-references.json', root);
const text = JSON.stringify(files, null, 2) + '\n';
if (process.argv.includes('--check')) {
  if (await readFile(output, 'utf8') !== text) throw new Error('Skill reference bundle is stale. Run npm run build:skills.');
  console.log('Skill reference bundle matches verified upstream sources.');
} else {
  await writeFile(output, text);
  console.log(fileURLToPath(output));
}
