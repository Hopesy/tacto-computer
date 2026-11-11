import {spawn} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import {createInterface} from 'node:readline';

const {version} = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));

const [path, selected] = process.argv.slice(2);
if (!path) throw new Error('Usage: node probe.mjs <mcp.json> [server-name]');
const config = JSON.parse((await readFile(path, 'utf8')).replace(/^\uFEFF/, ''));
const names = Object.keys(config.mcpServers ?? {});
const name = selected ?? (names.length === 1 ? names[0] : undefined);
const server = name && config.mcpServers[name];
if (!server || typeof server.command !== 'string' || !Array.isArray(server.args) || !server.args.every(arg => typeof arg === 'string')) {
  throw new Error('Select one stdio MCP server with command and args.');
}
const child = spawn(server.command, server.args, {stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true, env: {...process.env, ...server.env}});
child.stderr.resume();
const pending = new Map();
let nextId = 0;
let closed = false;
const exit = new Promise(resolve => { child.once('exit', resolve); child.once('error', resolve); });
function fail(error) {
  closed = true;
  for (const request of pending.values()) request.reject(error);
  pending.clear();
}
child.on('error', error => fail(new Error(`MCP process failed: ${error.code ?? 'spawn error'}`)));
child.on('exit', () => fail(new Error('MCP process exited before replying')));
child.stdin.on('error', () => fail(new Error('MCP input closed')));
const lines = createInterface({input: child.stdout});
lines.on('line', line => {
  if (!line.trim()) return;
  let message;
  try { message = JSON.parse(line); }
  catch { fail(new Error('MCP stdout contained a non-JSON line')); return; }
  if (message.jsonrpc !== '2.0') { fail(new Error('Invalid JSON-RPC response')); return; }
  if (typeof message.method === 'string') {
    if (message.id !== undefined) {
      const response = message.method === 'ping' ? {result: {}} : {error: {code: -32601, message: 'Unsupported client method'}};
      child.stdin.write(JSON.stringify({jsonrpc: '2.0', id: message.id, ...response}) + '\n');
    }
    return;
  }
  const request = pending.get(message.id);
  if (!request) return;
  if (message.error) request.reject(new Error(`MCP request refused (${message.error.code})`));
  else if (!('result' in message)) request.reject(new Error('MCP response has no result'));
  else request.resolve(message.result);
});
function request(method, params) {
  if (closed) return Promise.reject(new Error('MCP process is closed'));
  return new Promise((resolve, reject) => {
    const id = ++nextId;
    const finish = (error, result) => {
      clearTimeout(timer);
      pending.delete(id);
      if (error) reject(error); else resolve(result);
    };
    const timer = setTimeout(() => finish(new Error(`${method} timed out`)), 30_000);
    pending.set(id, {resolve: result => finish(null, result), reject: error => finish(error)});
    child.stdin.write(JSON.stringify({jsonrpc: '2.0', id, method, params}) + '\n');
  });
}
async function waitForExit(ms) {
  let timer;
  const ended = await Promise.race([exit.then(() => true), new Promise(resolve => { timer = setTimeout(() => resolve(false), ms); })]);
  clearTimeout(timer);
  return ended;
}
try {
  const initialized = await request('initialize', {protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: 'tacto-probe', version}});
  if (!['2024-11-05', '2025-03-26', '2025-06-18'].includes(initialized.protocolVersion)) throw new Error('Unsupported MCP protocol version');
  if (!initialized.serverInfo || !initialized.capabilities?.tools) throw new Error('MCP server did not advertise its tool capability');
  child.stdin.write(JSON.stringify({jsonrpc: '2.0', method: 'notifications/initialized'}) + '\n');
  const tools = [];
  const cursors = new Set();
  let cursor;
  for (let page = 0; page < 100; page += 1) {
    const result = await request('tools/list', cursor ? {cursor} : {});
    if (!Array.isArray(result.tools)) throw new Error('Invalid tools/list response');
    for (const tool of result.tools) {
      if (typeof tool.name !== 'string' || !tool.inputSchema) throw new Error('Invalid MCP tool schema');
      tools.push(tool.name);
    }
    cursor = result.nextCursor;
    if (cursor === undefined) break;
    if (typeof cursor !== 'string' || !cursor || cursors.has(cursor) || page === 99) throw new Error('Invalid MCP pagination');
    cursors.add(cursor);
  }
  if (!tools.length) throw new Error('The MCP server returned no tools');
  console.log(JSON.stringify({ok: true, name, server: initialized.serverInfo, protocolVersion: initialized.protocolVersion, toolCount: tools.length, tools}, null, 2));
} finally {
  child.stdin.end();
  if (!await waitForExit(3_000)) {
    if (process.platform === 'win32' && child.pid) {
      const killer = spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], {windowsHide: true, stdio: 'ignore'});
      await new Promise(resolve => { killer.once('exit', resolve); killer.once('error', resolve); });
    } else child.kill('SIGTERM');
    if (!await waitForExit(3_000)) child.kill('SIGKILL');
  }
  lines.close();
}
