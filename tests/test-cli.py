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
    def invoke(self, *args, env=None):
        return subprocess.run(['node',str(cli),*map(str,args)],capture_output=True,text=True,encoding='utf-8',timeout=20,env={**os.environ,**(env or {})})
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
        server=json.loads(result.stdout)['mcpServers']['tacto-mcp']
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
        server=json.loads(result.stdout)['mcpServers']['tacto-mcp']
        self.assertEqual(server,dict(command=str(driver),args=['mcp','--socket',r'\\.\pipe\tacto-test']))
        self.assertIn('Update the controlled PC',self.invoke('driver','--install-dir',self.folder,'call','get_screen_size','{}').stderr)
        config.write_text(json.dumps(dict(Phase='uninstalled')))
        self.assertNotEqual(self.invoke('config','--install-dir',self.folder).returncode,0)
    @unittest.skipUnless(os.name!='nt','Unix executable proxy')
    def test_local_proxy(self):
        proxy=self.folder/'cua-proxy'
        proxy.write_text('#!/bin/sh\n[ -z "$npm_config_package$npm_config_call" ] || exit 9\nprintf "proxy reached\\n"\n')
        proxy.chmod(0o700)
        result=self.invoke('mcp','--proxy',proxy,env={'npm_config_package':'["unrelated-package"]','npm_config_call':'unrelated-command'})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'proxy reached\n')

    @unittest.skipUnless(os.name!='nt','Unix SSH command routing')
    def test_cli_proxy_and_outer_ssh_pass_json_on_stdin(self):
        ssh=self.folder/'ssh'
        ssh.write_text('#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps({"argv":sys.argv[1:],"request":json.loads(sys.stdin.read())}))\n')
        ssh.chmod(0o700)
        proxy=self.folder/'cua-proxy'
        proxy.write_text('fixture')
        (self.folder/'ssh_config').write_text('fixture')
        env={'PATH':str(self.folder)+os.pathsep+os.environ['PATH']}
        payload=json.dumps({'session':'remote-named','text':'中文'},ensure_ascii=False)
        direct=self.invoke('driver','--proxy',proxy,'call','get_session',payload,env=env)
        self.assertEqual(direct.returncode,0,direct.stderr)
        body=json.loads(direct.stdout)
        self.assertEqual(body['argv'],['-T','-F',str(self.folder/'ssh_config'),'windows','cua-cli'])
        self.assertEqual(body['request']['args'],json.loads(payload))
        remote="/home/agent's directory/cua-proxy"
        outer=self.invoke('driver','--proxy',remote,'--ssh','my-vps','call','get_session',payload,env=env)
        self.assertEqual(outer.returncode,0,outer.stderr)
        body=json.loads(outer.stdout)
        self.assertEqual(shlex.split(body['argv'][-1]),['exec','ssh','-T','-F',"/home/agent's directory/ssh_config",'windows','cua-cli'])
        self.assertEqual(body['request']['args'],json.loads(payload))

if __name__=='__main__': unittest.main(verbosity=2)
