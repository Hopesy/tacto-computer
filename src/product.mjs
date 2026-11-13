import {readFile} from 'node:fs/promises';

export const metadata = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
export const cliName = Object.keys(metadata.bin)[0];
export const {skillName, mcpName} = metadata.tacto;
