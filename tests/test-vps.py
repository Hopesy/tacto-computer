import base64
import importlib.util
import json
import hashlib
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
        self.assertFalse(folder.exists())
        self.assertTrue(setup.execute(dict(action='remove',device='test-laptop',clientId='id-1'),self.home)['purged'])
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

    def test_registered_agent_cleanup(self):
        state = setup.execute(dict(self.request), self.home)
        folder = self.home/'.tacto/devices/test-laptop'
        config = self.home/'agent.json'
        skill = self.home/'skills/tacto-test-laptop/SKILL.md'
        skill.parent.mkdir(parents=True)
        skill.write_text('Windows target skill')
        receipt = Path(str(config)+'.tacto-test-laptop.json')
        config.write_text(json.dumps({'mcpServers':{state['mcpName']:state['mcp'],'other':{'command':'other'}}}))
        receipt.write_text(json.dumps(dict(config=str(config),name=state['mcpName'],server=state['mcp'],skill=str(skill),skillHash=hashlib.sha256(skill.read_bytes()).hexdigest())))
        (folder/'agent-integrations.json').write_text(json.dumps([dict(clientId=state['clientId'],receipt=str(receipt))]))
        configured=setup.execute(dict(action='configure',device='test-laptop',clientId='id-1',skillText='Updated Windows target skill'),self.home)
        self.assertEqual(configured['preservedIntegrations'], [])
        self.assertEqual(skill.read_text(), 'Updated Windows target skill')
        self.assertEqual(json.loads(receipt.read_text())['skillHash'], hashlib.sha256(skill.read_bytes()).hexdigest())
        removed = setup.execute(dict(action='remove',device='test-laptop',clientId='id-1'),self.home)
        self.assertEqual(removed['preservedIntegrations'], [])
        self.assertEqual(json.loads(config.read_text()), {'mcpServers':{'other':{'command':'other'}}})
        self.assertFalse(skill.exists())
        self.assertFalse(receipt.exists())
        self.assertFalse(folder.exists())

    def test_official_pack_update_rollback_and_edited_cleanup(self):
        state=setup.execute(dict(self.request),self.home)
        folder=self.home/'.tacto/devices/test-laptop'
        config=self.home/'agent.json'
        skill=self.home/'skills/tacto-test-laptop/SKILL.md'
        skill.parent.mkdir(parents=True)
        skill.write_text('old')
        receipt=Path(str(config)+'.tacto-test-laptop.json')
        config.write_text(json.dumps({'mcpServers':{state['mcpName']:state['mcp']}}))
        receipt.write_text(json.dumps(dict(config=str(config),name=state['mcpName'],server=state['mcp'],skill=str(skill),skillHash=hashlib.sha256(b'old').hexdigest())))
        (folder/'agent-integrations.json').write_text(json.dumps([dict(clientId=state['clientId'],receipt=str(receipt))]))
        files={'SKILL.md':'Use {{VPS_CLI}}', 'official/WINDOWS.md':'official '+ 'x'*100000, 'official/RUNTIME.md':'sessions'}
        files['official/SKILL.md']='---\nname: cua-driver\n---\nCUA guide'
        request=dict(action='configure',device='test-laptop',clientId='id-1',skillFiles=files)
        result=setup.execute(request,self.home)
        self.assertEqual(result['preservedIntegrations'],[])
        self.assertIn('driver --proxy',skill.read_text())
        reference=skill.parent/'official/WINDOWS.md'
        self.assertEqual(reference.read_text(),files['official/WINDOWS.md'])
        # Upgrade the existing nested pack, then roll back through the same helper.
        adapted={'SKILL.md':'Use {{VPS_CLI}}', 'references/CUA.md':'CUA guide', 'references/WINDOWS.md':'Windows guide', 'references/RUNTIME.md':'sessions'}
        updated=dict(request,skillFiles=adapted,mcpName='tacto-mcp',skillName='tacto-computer',cliPrefix='npx -y --package tacto-computer@latest tacto-cli driver')
        setup.execute(updated,self.home)
        renamed=skill.parent.parent/'tacto-computer'
        self.assertFalse(skill.parent.exists())
        self.assertEqual(set(json.loads(config.read_text())['mcpServers']),{'tacto-mcp'})
        self.assertEqual(json.loads(receipt.read_text())['name'],'tacto-mcp')
        self.assertIn('--package tacto-computer@latest tacto-cli', (renamed/'SKILL.md').read_text())
        for target in (renamed,folder/'skill'):
            self.assertEqual(list(target.rglob('SKILL.md')),[target/'SKILL.md'])
            self.assertFalse((target/'official').exists())
            self.assertEqual((target/'references/CUA.md').read_text(),'CUA guide')
        setup.execute(request,self.home)
        self.assertTrue((skill.parent/'official/SKILL.md').exists())
        self.assertFalse(renamed.exists())
        self.assertEqual(set(json.loads(config.read_text())['mcpServers']),{'computer-test-laptop'})
        # A previous runtime can roll the same receipt back to its single-file Skill.
        setup.execute(dict(action='configure',device='test-laptop',clientId='id-1',skillText='old'),self.home)
        self.assertFalse(reference.exists())
        self.assertEqual(skill.read_text(),'old')
        setup.execute(updated,self.home)
        reference=renamed/'references/WINDOWS.md'
        reference.write_text('user extension')
        self.assertIn(str(reference),setup.execute(updated,self.home)['preservedIntegrations'])
        removed=setup.execute(dict(action='remove',device='test-laptop',clientId='id-1'),self.home)
        self.assertEqual(removed['preservedIntegrations'],[str(reference)])
        self.assertEqual(reference.read_text(),'user extension')
        self.assertFalse((renamed/'SKILL.md').exists())
        self.assertFalse((reference.parent/'RUNTIME.md').exists())
        with self.assertRaises(ValueError): setup.skill_files({'skillFiles':{'SKILL.md':'x','../escape':'x'}},folder)

    def test_stdin_protocol_accepts_pack_larger_than_windows_command_limit(self):
        request=dict(self.request,device='../bad',skillFiles={'SKILL.md':'x'*100000})
        proc=subprocess.run(['python3',str(source),'tacto-stdin-v2'],input=json.dumps(request),capture_output=True,text=True)
        self.assertEqual(proc.returncode,1)
        self.assertIn('Computer name',proc.stdout)
        self.assertNotIn('base64',proc.stdout)

    def test_mcp_health_stream_and_core_failure(self):
        fake = self.home/'mcp.py'
        fake.write_text('''import json,sys
for line in sys.stdin:
 m=json.loads(line)
 if 'id' not in m: continue
 if m['method']=='initialize': result={'protocolVersion':'2025-06-18'}
 elif m['method']=='tools/list':
  if m.get('params',{}).get('cursor')=='page2': result={'tools':[{'name':'health_report'}]}
  else: result={'tools':[{'name':'first_tool'}],'nextCursor':'page2'}
 else:
  result={'structuredContent':{'schema_version':'1','platform':'win32','overall':sys.argv[1],'checks':[{'name':name,'status':'pass'} for name in ['binary_version','platform_supported','session_active']]}}
 print(json.dumps({'jsonrpc':'2.0','method':'notifications/message','params':{}})+'\\n'+json.dumps({'jsonrpc':'2.0','id':m['id'],'result':result}),flush=True)
''')
        for status in ('ok','degraded'):
            self.assertEqual(setup.mcp_health([sys.executable,str(fake),status])['overall'],status)
        with self.assertRaisesRegex(RuntimeError,'health failed'):
            setup.mcp_health([sys.executable,str(fake),'failed'])

    def test_authorized_keys_symlink_corrupt_sibling_and_custom_names(self):
        real_auth = self.home/'dotfiles_authorized_keys'
        real_auth.write_text(self.pub.strip()+' retained-key\n')
        self.auth.unlink()
        self.auth.symlink_to(real_auth)
        broken_dir = self.home/'.tacto/devices/corrupted'
        broken_dir.mkdir(parents=True)
        (broken_dir/'state.json').write_text('{corrupted-json')
        custom_req = dict(self.request, mcpName='tacto-office', skillName='tacto-office', windowsUser=r'azuread\Test User')
        state = setup.execute(custom_req, self.home)
        self.assertTrue(self.auth.is_symlink())
        self.assertIn('tacto:test-laptop:tunnel', real_auth.read_text())
        self.assertEqual(state['mcpName'], 'tacto-office')
        self.assertEqual(state['skillName'], 'tacto-office')
        folder = self.home/'.tacto/devices/test-laptop'
        ssh_cfg = subprocess.check_output(['ssh','-G','-F',str(folder/'ssh_config'),'windows'],text=True)
        self.assertIn('azuread\\test user', ssh_cfg.lower())
        cfg = self.home/'multi-agent.json'
        custom_skill = self.home/'skills/tacto-office/SKILL.md'
        custom_skill.parent.mkdir(parents=True)
        initial_skill = '---\nname: tacto-office\n---\nold custom skill'
        custom_skill.write_text(initial_skill)
        cfg.write_text(json.dumps({'mcpServers': {'tacto-office': state['mcp']}}))
        receipt = Path(str(cfg) + '.tacto-test-laptop.json')
        receipt.write_text(json.dumps(dict(
            schema=2, config=str(cfg), device='test-laptop', name='tacto-office',
            skillName='tacto-office', customNames=True, server=state['mcp'],
            skill=str(custom_skill), skillHash=hashlib.sha256(initial_skill.encode()).hexdigest(),
            files=[dict(root=str(custom_skill.parent), path=str(custom_skill), hash=hashlib.sha256(initial_skill.encode()).hexdigest())]
        )))
        (folder/'agent-integrations.json').write_text(json.dumps([dict(clientId='id-1', receipt=str(receipt))]))
        default_update = dict(
            action='configure', device='test-laptop', clientId='id-1',
            mcpName='tacto-mcp', skillName='tacto-computer',
            skillFiles={'SKILL.md': '---\nname: tacto-computer\ndescription: Operate via the tacto-mcp MCP server.\n---\nUse server `tacto-mcp` or {{VPS_CLI}}'}
        )
        reconciled = setup.execute(default_update, self.home)
        self.assertEqual(reconciled['preservedIntegrations'], [])
        self.assertEqual(set(json.loads(cfg.read_text())['mcpServers']), {'tacto-office'})
        self.assertTrue(custom_skill.exists())
        self.assertFalse((self.home/'skills/tacto-computer').exists())
        updated_text = custom_skill.read_text()
        self.assertIn('name: tacto-office', updated_text)
        self.assertIn('the tacto-office MCP server', updated_text)
        self.assertIn('server `tacto-office`', updated_text)
        setup.execute(dict(action='remove',device='test-laptop',clientId='id-1'), self.home)
        self.assertFalse(custom_skill.exists())
        self.assertFalse(receipt.exists())
        self.assertEqual(json.loads(cfg.read_text()), {'mcpServers': {}})
        self.assertTrue(self.auth.is_symlink())
        self.assertNotIn('tacto:test-laptop:tunnel', real_auth.read_text())

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
        with patch.object(setup,'mcp_health',return_value={'overall':'ok'}):
            self.assertTrue(setup.execute(dict(action='check',device='test-laptop',clientId='id-1'),self.home)['connected'])
        with patch.object(setup,'mcp_health',side_effect=RuntimeError('MCP failed')):
            with self.assertRaises(RuntimeError):
                setup.execute(dict(action='check',device='test-laptop',clientId='id-1'),self.home)
        payload=base64.b64encode(json.dumps(dict(self.request,device='../bad')).encode()).decode()
        code='import base64;code=base64.b64decode(%r).decode();exec(compile(code,"<bootstrap>","exec"),dict(__name__="__main__",__file__="<bootstrap>",BOOTSTRAP_SOURCE=code))'%base64.b64encode(source.read_bytes()).decode()
        proc=subprocess.run(['python3','-c',code,payload],capture_output=True,text=True)
        self.assertEqual(proc.returncode,1)
        self.assertIn('TACTO_SETUP_JSON=',proc.stdout)


if __name__=='__main__': unittest.main(verbosity=2)
