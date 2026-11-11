import base64
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
source = Path(__file__).resolve().parents[1] / 'install/linux/setup-vps.py'
spec = importlib.util.spec_from_file_location('setup_vps', source)
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)
setup.BOOTSTRAP_SOURCE = source.read_text()


class SetupTest(unittest.TestCase):
    def setUp(self):
        fixtures = Path(tempfile.gettempdir()) / '.Tacto-temp'
        fixtures.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='vps-', dir=fixtures)
        self.home = Path(self.temp.name)
        subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(self.home/'client')],check=True)
        self.pub = (self.home/'client.pub').read_text()
        self.request = dict(action='prepare',device='test-laptop',clientId='id-1',reversePort=0,
            windowsUser='testuser',windowsHostKey=self.pub,tunnelPublicKey=self.pub,
            driverPath=r'C:\Users\Test User\AppData\Local\Tacto\cua-0.46.1\cua-driver.exe')
        self.auth = self.home/'.ssh'/'authorized_keys'
        self.auth.parent.mkdir()
        self.auth.write_text(self.pub.strip()+' retained-key\n')

    def tearDown(self):
        self.temp.cleanup()

    def test_prepare_repeat_remove(self):
        first = setup.execute(dict(self.request),self.home)
        second = setup.execute(dict(self.request),self.home)
        self.assertEqual(first,second)
        self.assertNotIn('container', first)
        self.assertEqual(self.auth.read_text().count('tacto:test-laptop:tunnel'),1)
        folder = self.home/'.tacto/devices/test-laptop'
        config = subprocess.check_output(['ssh','-G','-F',str(folder/'ssh_config'),'windows'],text=True)
        self.assertIn('user testuser',config)
        self.assertIn('port '+str(first['reversePort']),config)
        self.assertEqual((folder/'windows').stat().st_mode&0o777,0o600)
        self.assertIn('cua-mcp',(folder/'cua-proxy').read_text())
        self.assertEqual(set(first['mcp']), {'command', 'args'})
        self.assertEqual(json.loads((folder/'mcp.json').read_text())['mcpServers'][first['mcpName']], first['mcp'])
        removed=setup.execute(dict(action='remove',device='test-laptop',clientId='id-1'),self.home)
        self.assertTrue(removed['removed'])
        self.assertIn('retained-key',self.auth.read_text())
        self.assertNotIn('tacto:',self.auth.read_text())
        replacement=setup.execute(dict(self.request,clientId='replacement'),self.home)
        self.assertEqual(replacement['clientId'],'replacement')
        self.assertNotIn('removed',replacement)

    def test_collision_and_identity(self):
        first = setup.execute(dict(self.request),self.home)
        other = dict(self.request,device='second',clientId='id-2')
        second = setup.execute(other,self.home)
        self.assertNotEqual(first['reversePort'],second['reversePort'])
        with self.assertRaisesRegex(RuntimeError,'another installation'):
            setup.execute(dict(self.request,clientId='wrong'),self.home)
        with self.assertRaisesRegex(RuntimeError,'identity mismatch'):
            setup.execute(dict(action='remove',device='test-laptop',clientId='wrong'),self.home)

    def test_occupied_port_and_invalid_input(self):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0))
            with self.assertRaisesRegex(RuntimeError,'No free'):
                setup.execute(dict(self.request,reversePort=sock.getsockname()[1]),self.home)
        for name in ['../escape',';touch x','bad\nname']:
            with self.assertRaises(ValueError): setup.execute(dict(self.request,device=name),self.home)
        with self.assertRaises(ValueError):
            setup.execute(dict(self.request,tunnelPublicKey='bad\nkey'),self.home)

    def test_check_and_bootstrap_protocol(self):
        setup.execute(dict(self.request),self.home)
        def command(args,**kwargs):
            self.assertEqual(args[-1],'cua-status')
            return 'Cua Driver daemon is running'
        with patch.object(setup,'run',command):
            self.assertTrue(setup.execute(dict(action='check',device='test-laptop',clientId='id-1'),self.home)['connected'])
        with patch.object(setup,'run',return_value='not running'):
            with self.assertRaises(RuntimeError):
                setup.execute(dict(action='check',device='test-laptop',clientId='id-1'),self.home)
        payload=base64.b64encode(json.dumps(dict(self.request,device='../bad')).encode()).decode()
        code='import base64;code=base64.b64decode(%r).decode();exec(compile(code,"<bootstrap>","exec"),dict(__name__="__main__",__file__="<bootstrap>",BOOTSTRAP_SOURCE=code))'%base64.b64encode(source.read_bytes()).decode()
        proc=subprocess.run(['python3','-c',code,payload],capture_output=True,text=True)
        self.assertEqual(proc.returncode,1)
        self.assertIn('TACTO_SETUP_JSON=',proc.stdout)


if __name__=='__main__': unittest.main(verbosity=2)
