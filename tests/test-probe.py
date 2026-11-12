import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

root = Path(__file__).resolve().parent.parent / '.Tacto-temp'
root.mkdir(exist_ok=True)
probe = root.parent / 'src/probe.mjs'
fake = root / 'fake-mcp.mjs'
fake.write_text('''import {createInterface} from 'node:readline';
const mode = process.argv[2];
if (mode === 'nested' && (process.env.npm_config_package || process.env.npm_config_call)) process.exit(9);
createInterface({input:process.stdin}).on('line', line => {
 const m = JSON.parse(line); if (!m.id) return;
 if (mode === 'invalid') { console.log('not-json'); return; }
 if (mode === 'exit') { process.exit(2); }
 if (mode.startsWith('health') && m.method === 'tools/list') {
  console.log(JSON.stringify({jsonrpc:'2.0',id:m.id,result:{tools:[{name:'health_report',inputSchema:{type:'object'}}]}})); return;
 }
 if (mode.startsWith('health') && m.method === 'tools/call') {
  const health={schema_version:1,platform:mode==='health-platform'?'linux':'win32',overall:'degraded',checks:['binary_version','platform_supported','session_active'].map(name=>({name,status:mode==='health-fail'&&name==='session_active'?'fail':'pass'}))};
  console.log(JSON.stringify({jsonrpc:'2.0',id:m.id,result:{content:[{type:'text',text:JSON.stringify(health)}]}})); return;
 }
 const result = m.method === 'initialize'
 ? {protocolVersion:mode === 'version' ? '2099-01-01' : '2025-06-18',serverInfo:{name:'fixture',version:'1'},capabilities:{tools:{}}}
 : {tools:[{name:m.params.cursor ? 'second' : 'first',inputSchema:{type:'object'}}],...(mode === 'cursor' || !m.params.cursor ? {nextCursor:'next'} : {})};
 console.log(JSON.stringify({jsonrpc:'2.0',id:m.id,result}));
});
''', encoding='utf-8')

class ProbeTest(unittest.TestCase):
    def invoke(self, mode, env=None):
        with tempfile.TemporaryDirectory(prefix='probe-', dir=root) as folder:
            config = Path(folder) / 'mcp.json'
            config.write_text(json.dumps({'mcpServers': {'fixture': {'command':'node','args':[str(fake),mode]}}}))
            return subprocess.run(['node',str(probe),str(config)]+(['--health'] if mode.startswith('health') else []),capture_output=True,text=True,timeout=15,env={**os.environ,**(env or {})})
    def test_health_semantics(self):
        result=self.invoke('health-degraded')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['health']['overall'],'degraded')
        for mode in ['health-fail','health-platform']:
            result=self.invoke(mode)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('Desktop health failed',result.stderr)
    def test_paginated_discovery(self):
        result = self.invoke('success')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['tools'],['first','second'])
    def test_nested_npm_options_are_scoped_to_parent(self):
        result=self.invoke('nested',{'npm_config_package':'["unrelated-package"]','npm_config_call':'unrelated-command'})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['toolCount'],2)
    def test_invalid_responses(self):
        for mode, text in [('invalid','non-JSON'),('exit','exited'),('version','protocol version'),('cursor','pagination')]:
            with self.subTest(mode=mode):
                result=self.invoke(mode)
                self.assertNotEqual(result.returncode,0)
                self.assertIn(text,result.stderr)

if __name__ == '__main__': unittest.main(verbosity=2)
