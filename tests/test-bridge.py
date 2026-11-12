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


    def test_cli_native_arguments_sessions_and_maintenance_gate(self):
        fixtures=root/'.Tacto-temp'
        fixtures.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='cli-bridge-',dir=fixtures) as directory:
            folder=Path(directory)
            source=folder/'driver.cs'
            source.write_text('''using System; using System.Web.Script.Serialization;
class Fake { static void Main(string[] args) {
Console.InputEncoding=new System.Text.UTF8Encoding(false); Console.OutputEncoding=new System.Text.UTF8Encoding(false);
var json=new JavaScriptSerializer();
Console.WriteLine(json.Serialize(new { arguments=args, input=Console.In.ReadToEnd() }));
}}''')
            driver=folder/'fake driver.exe'
            compiler=Path(os.environ['WINDIR'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
            subprocess.run([str(compiler),'/nologo','/r:System.Web.Extensions.dll','/out:'+str(driver),str(source)],check=True,capture_output=True)
            config=folder/'desktop.json'
            pipe=r'\\.\pipe\cli-test'
            config.write_text(json.dumps(dict(Phase='complete',DriverPath=str(driver),SocketPath=pipe)))
            def invoke(request,remote=False):
                quote=lambda value: "'"+str(value).replace("'","''")+"'"
                command="[Console]::InputEncoding=[Text.UTF8Encoding]::new($true); & "+quote(root/'install/windows/Invoke-CuaBridge.ps1')+' -ConfigPath '+quote(config)
                if not remote: command+=' -Local -Cli'
                args=['powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',command]
                return subprocess.run(args,input=json.dumps(request,ensure_ascii=False),capture_output=True,text=True,encoding='utf-8',timeout=30,env={**os.environ,'SSH_ORIGINAL_COMMAND':'cua-cli'})
            payload=dict(command='call',tool='get_session',args=dict(session='named-test',text='中文 ☃'))
            for remote in (False,True):
                result=invoke(payload,remote)
                self.assertEqual(result.returncode,0,result.stderr)
                body=json.loads(result.stdout)
                self.assertEqual(body['arguments'],['call','get_session','--socket',pipe])
                self.assertEqual(json.loads(body['input']),payload['args'])
                self.assertEqual(len(list((folder/'cli-sessions').glob('*.json'))),1)
                self.assertEqual(list((folder/'connections').glob('*.json')),[])
            end=invoke(dict(command='call',tool='end_session',args=dict(session='named-test')))
            self.assertEqual(end.returncode,0,end.stderr)
            self.assertEqual(list((folder/'cli-sessions').glob('*.json')),[])
            self.assertNotEqual(invoke(dict(command='stop')).returncode,0)
            (folder/'transaction.json').write_text('{}')
            self.assertNotEqual(invoke(payload).returncode,0)
            self.assertEqual(list((folder/'connections').glob('*.json')),[])

if __name__ == '__main__': unittest.main(verbosity=2)
