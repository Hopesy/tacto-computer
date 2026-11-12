"""Exercise the shipped PowerShell bridge with a real persistent JSON-RPC client."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

root = Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.name == 'nt', 'Windows stdio bridge')
class BridgeTest(unittest.TestCase):
    def test_streaming_gate_and_leases(self):
        fixtures = root / '.Tacto-temp'
        fixtures.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='bridge-', dir=fixtures) as directory:
            folder = Path(directory)
            source = folder / 'driver.cs'
            source.write_text('''using System; class Fake {
static void Main() { string s; while((s=Console.ReadLine())!=null) {
if(s.Contains("initialize") && s.Contains("\\\"id\\\"")) Console.WriteLine("{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":1,\\\"result\\\":{\\\"protocolVersion\\\":\\\"2025-06-18\\\",\\\"serverInfo\\\":{\\\"name\\\":\\\"test\\\",\\\"version\\\":\\\"1\\\"},\\\"capabilities\\\":{\\\"tools\\\":{}}}}");
else if(s.Contains("tools/list")) Console.WriteLine("{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":2,\\\"result\\\":{\\\"tools\\\":[{\\\"name\\\":\\\"first\\\",\\\"inputSchema\\\":{\\\"type\\\":\\\"object\\\"}}]}}");
}}}''')
            driver = folder / 'fake.exe'
            compiler = Path(os.environ['WINDIR']) / 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
            subprocess.run([str(compiler), '/nologo', '/target:exe', '/out:'+str(driver), str(source)], check=True, capture_output=True)
            config = folder / 'desktop.json'
            config.write_text(json.dumps(dict(Phase='complete', DriverPath=str(driver), SocketPath=r'\\.\pipe\test')))
            mcp = folder / 'mcp.json'
            mcp.write_text(json.dumps({'mcpServers': {'fixture': {'command':'powershell.exe', 'args':['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(root/'install/windows/Invoke-CuaBridge.ps1'),'-ConfigPath',str(config),'-Local']}}}))
            def probe():
                return subprocess.run(['node',str(root/'src/probe.mjs'),str(mcp)],capture_output=True,text=True,timeout=40)
            result = probe()
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout)['tools'],['first'])
            self.assertEqual(list((folder/'connections').glob('*.json')),[])
            (folder/'transaction.json').write_text('{}')
            self.assertNotEqual(probe().returncode,0)
            self.assertEqual(list((folder/'connections').glob('*.json')),[])

if __name__ == '__main__': unittest.main(verbosity=2)
