import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

root = Path(__file__).resolve().parents[1]
cli = root / 'bin/tacto.mjs'

class CliTest(unittest.TestCase):
    def setUp(self):
        (root / '.Tacto-temp').mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='cli-', dir=root / '.Tacto-temp')
        self.folder = Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()
    def invoke(self, *args):
        return subprocess.run(['node',str(cli),*map(str,args)],capture_output=True,text=True,encoding='utf-8',timeout=20)
    def test_help_and_validation(self):
        self.assertIn('setup --local',self.invoke('--help').stdout)
        self.assertEqual(self.invoke('--version').stdout.strip(),json.loads((root / 'package.json').read_text())['version'])
        for args in [('unknown',),('mcp','--invalid'),('config','--ssh','my-vps'),('config','--proxy','relative/path'),('config','--ssh','-bad','--proxy','/tmp/proxy')]:
            with self.subTest(args=args):
                result=self.invoke(*args)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(result.stdout,'')
    def test_ssh_config_and_output(self):
        proxy="/home/test user's directory/cua-proxy"
        result=self.invoke('config','--ssh','my-vps','--proxy',proxy)
        self.assertEqual(result.returncode,0,result.stderr)
        server=json.loads(result.stdout)['mcpServers']['tacto']
        self.assertEqual(server['command'],'ssh')
        self.assertEqual(shlex.split(server['args'][-1]),['exec',proxy])
        output=self.folder/'export.json'
        args=('config','--ssh','my-vps','--proxy',proxy,'--output',str(output))
        self.assertEqual(self.invoke(*args).returncode,0)
        original=output.read_bytes()
        self.assertNotEqual(self.invoke(*args).returncode,0)
        self.assertEqual(output.read_bytes(),original)
        self.assertEqual(self.invoke(*args,'--force').returncode,0)
    @unittest.skipUnless(os.name=='nt','Windows installation configuration')
    def test_local_config(self):
        driver=self.folder/'cua driver.exe'
        driver.write_bytes(b'fixture')
        config=self.folder/'desktop.json'
        config.write_text(json.dumps(dict(Phase='complete',DriverPath=str(driver),SocketPath=r'\\.\pipe\tacto-test')))
        result=self.invoke('config','--install-dir',self.folder)
        self.assertEqual(result.returncode,0,result.stderr)
        server=json.loads(result.stdout)['mcpServers']['tacto']
        self.assertEqual(server,dict(command=str(driver),args=['mcp','--socket',r'\\.\pipe\tacto-test']))
        config.write_text(json.dumps(dict(Phase='uninstalled')))
        self.assertNotEqual(self.invoke('config','--install-dir',self.folder).returncode,0)
    @unittest.skipUnless(os.name!='nt','Unix executable proxy')
    def test_local_proxy(self):
        proxy=self.folder/'cua-proxy'
        proxy.write_text('#!/bin/sh\nprintf "proxy reached\\n"\n')
        proxy.chmod(0o700)
        result=self.invoke('mcp','--proxy',proxy)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'proxy reached\n')

if __name__=='__main__': unittest.main(verbosity=2)
