"""Per-computer SSH bridge setup; invoked by Setup-Tacto.ps1 over SSH."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import socket
import selectors
import shutil
import subprocess
import sys
import time


def run(args, data=None, timeout=45):
    result = subprocess.run(args, input=data, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('%s failed: %s' % (args[0], result.stderr[-1800:]))
    return result.stdout.strip()


def write(path, text, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.new')
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        stream.write(text)
    os.chmod(temp, mode)
    temp.replace(path)


def edit_authorized(path, marker, line=None):
    lines = path.read_text().splitlines() if path.exists() else []
    lines = [s for s in lines if not s.endswith(' ' + marker)]
    if line:
        lines.append(line + ' ' + marker)
    write(path, '\n'.join(lines) + '\n')


def public_key(value):
    fields = value.strip().split()
    if len(fields) < 2 or fields[0] != 'ssh-ed25519' or not re.fullmatch(r'[A-Za-z0-9+/=]+', fields[1]):
        raise ValueError('Expected an ed25519 public key.')
    return ' '.join(fields[:2])


def allocate_port(root, device, requested):
    reserved = set()
    for file in root.glob('*/state.json'):
        if file.parent.name != device:
            state = json.loads(file.read_text())
            if not state.get('removed'):
                reserved.add(state['reversePort'])
    ports = [int(requested)] if requested else range(22222, 23000)
    for port in ports:
        if not 1024 <= port <= 65535 or port in reserved:
            continue
        with socket.socket() as sock:
            try:
                sock.bind(('127.0.0.1', port))
            except OSError:
                continue
            return port
    raise RuntimeError('No free reverse port. Select another port and retry.')


def prepare(request, root, folder, auth):
    state_path = folder / 'state.json'
    previous = json.loads(state_path.read_text()) if state_path.exists() else None
    if previous and not previous.get('removed') and previous['clientId'] != request['clientId']:
        raise RuntimeError('This computer name already belongs to another installation. Choose a different name.')
    port = previous['reversePort'] if previous else allocate_port(root, request['device'], request.get('reversePort'))
    if previous and request.get('reversePort') and int(request['reversePort']) != port:
        raise RuntimeError('An existing installation keeps its assigned port. Remove it before changing ports.')
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(folder, 0o700)
    key = folder / 'windows'
    if not key.exists():
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)])
    callback_key = public_key(key.with_suffix('.pub').read_text())
    host_key = public_key(request['windowsHostKey'])
    user = request['windowsUser']
    driver = request['driverPath']
    if any(c in user + driver for c in '\r\n\0') or not re.fullmatch(r'[A-Za-z]:\\.+\\cua-driver\.exe', driver):
        raise ValueError('Invalid Windows account or CUA path.')
    config = ('Host windows\n HostName 127.0.0.1\n Port %d\n User %s\n IdentityFile %s\n'
              ' HostKeyAlias tacto-windows\n UserKnownHostsFile %s\n StrictHostKeyChecking yes\n'
              ' IdentitiesOnly yes\n BatchMode yes\n ConnectTimeout 12\n ServerAliveInterval 15\n ServerAliveCountMax 3\n') % (
                  port, json.dumps(user, ensure_ascii=False), json.dumps(str(key), ensure_ascii=False), json.dumps(str(folder / 'known_hosts'), ensure_ascii=False))
    write(folder / 'ssh_config', config)
    write(folder / 'known_hosts', 'tacto-windows ' + host_key + '\n')
    write(folder / 'cua-proxy', '#!/bin/sh\nexec /usr/bin/ssh -T -F %s windows cua-mcp\n' % (
        shlex.quote(str(folder / 'ssh_config'))), 0o700)
    source = globals().get('BOOTSTRAP_SOURCE')
    if source:
        write(folder / 'setup-vps.py', source, 0o700)
    state = dict(device=request['device'], clientId=request['clientId'], reversePort=port,
                 windowsKey=callback_key, driverPath=driver, vpsUser=run(['id', '-un']),
                 mcpName='computer-' + request['device'], managementVersion=1)
    if request.get('skillText'):
        write(folder / 'skill' / 'SKILL.md', request['skillText'])
    control = 'python3 %s --managed' % shlex.quote(str(folder / 'setup-vps.py'))
    edit_authorized(auth, 'tacto:' + request['device'] + ':tunnel',
                    'restrict,port-forwarding,permitlisten="127.0.0.1:%d",command="%s" %s' % (
                        port, control.replace('"', '\\"'), public_key(request['tunnelPublicKey'])))
    state['mcp'] = {'command': str(folder / 'cua-proxy'), 'args': []}
    write(folder / 'mcp.json', json.dumps({'mcpServers': {state['mcpName']: state['mcp']}}, indent=2) + '\n')
    write(state_path, json.dumps(state, indent=2) + '\n')
    return state


def mcp_health(command, core_only=False):
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, bufsize=1)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending_bytes = bytearray()
    def send(value):
        process.stdin.write(json.dumps(value) + '\n')
        process.stdin.flush()
    def request(number, method, params):
        send(dict(jsonrpc='2.0', id=number, method=method, params=params))
        deadline = time.monotonic() + (60 if method == 'tools/call' else 25)
        for _ in range(100):
            while b'\n' not in pending_bytes:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise RuntimeError('MCP health request timed out.')
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('MCP endpoint exited before its response.')
                pending_bytes.extend(chunk)
            line, _, rest = pending_bytes.partition(b'\n')
            pending_bytes[:] = rest
            message = json.loads(line)
            if 'method' in message and 'id' in message:
                send(dict(jsonrpc='2.0', id=message['id'], **({'result': {}} if message['method'] == 'ping' else {'error': {'code': -32601, 'message': 'Unsupported client method'}})))
                continue
            if message.get('id') == number and 'method' not in message:
                if 'error' in message:
                    raise RuntimeError('MCP endpoint rejected ' + method)
                return message['result']
        raise RuntimeError('Too many MCP notifications.')
    try:
        hello = request(1, 'initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='tacto-vps-check', version='1')))
        if hello.get('protocolVersion') not in ('2024-11-05', '2025-03-26', '2025-06-18'):
            raise RuntimeError('Unsupported MCP protocol version.')
        send(dict(jsonrpc='2.0', method='notifications/initialized'))
        listed = request(2, 'tools/list', {})
        if not any(t['name'] == 'health_report' for t in listed['tools']):
            raise RuntimeError('Missing health_report capability.')
        arguments = {'include': ['binary_version', 'platform_supported', 'session_active', 'screen_capture_capability']} if core_only else {}
        result = request(3, 'tools/call', dict(name='health_report', arguments=arguments))
        if result.get('isError'):
            raise RuntimeError('Driver health_report failed.')
        health = result.get('structuredContent', {})
        if 'schema_version' not in health:
            for content in result.get('content', []):
                if content.get('type') == 'text':
                    try:
                        candidate = json.loads(content['text'])
                        if 'schema_version' in candidate:
                            health = candidate
                    except (ValueError, TypeError):
                        pass
        required = {'binary_version', 'platform_supported', 'session_active'}
        passed = {c['name'] for c in health.get('checks', []) if c.get('status') == 'pass'}
        if str(health.get('schema_version')) != '1' or health.get('platform') != 'win32' or health.get('overall') not in ('ok', 'degraded') or not required <= passed:
            raise RuntimeError('Windows desktop health failed: ' + json.dumps(health))
        return health
    finally:
        selector.close()
        process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
        process.stdout.close()


def check(state, folder, core_only=False):
    health = mcp_health(['ssh', '-T', '-F', str(folder / 'ssh_config'), 'windows', 'cua-health'], core_only=core_only)
    return {'connected': True, 'status': 'Windows MCP health verified', 'health': health}


def reconcile_integrations(folder, state, replacement_skill=None):
    registry = folder / 'agent-integrations.json'
    preserved = []
    if not registry.exists():
        return preserved
    try:
        registrations = json.loads(registry.read_text())
        if not isinstance(registrations, list):
            raise ValueError('Expected registrations list')
    except (ValueError, OSError):
        return ['Agent registrations were unreadable; check the client configurations manually.']
    for registration in registrations:
        receipt = None
        try:
            receipt = Path(registration['receipt'])
            if registration.get('clientId') != state['clientId'] or not receipt.is_file():
                continue
            record = json.loads(receipt.read_text())
            config, skill = Path(record['config']), Path(record['skill'])
            expected_receipt = str(config) + '.tacto-' + state['device'] + '.json'
            if str(receipt) != expected_receipt or record['name'] != state['mcpName'] or record['server'] != state['mcp']:
                raise ValueError('Integration identity mismatch')
            edited = False
            if config.exists():
                document = json.loads(config.read_text(encoding='utf-8-sig'))
                entry = document.get('mcpServers', {}).get(record['name'])
                if entry == record['server'] and replacement_skill is None:
                    del document['mcpServers'][record['name']]
                    write(config, json.dumps(document, indent=2) + '\n')
                elif entry is not None and entry != record['server']:
                    preserved.append(str(config)); edited = True
            if skill.exists():
                if skill.name == 'SKILL.md' and skill.parent.name == 'tacto-' + state['device'] and hashlib.sha256(skill.read_bytes()).hexdigest() == record['skillHash']:
                    if replacement_skill is None:
                        skill.unlink()
                        if not any(skill.parent.iterdir()):
                            skill.parent.rmdir()
                    else:
                        write(skill, replacement_skill)
                        record['skillHash'] = hashlib.sha256(replacement_skill.encode('utf-8')).hexdigest()
                        write(receipt, json.dumps(record, indent=2) + '\n')
                else:
                    preserved.append(str(skill)); edited = True
            if not edited and replacement_skill is None:
                receipt.unlink()
        except (OSError, ValueError, KeyError, TypeError):
            preserved.append(str(receipt) if receipt else 'Invalid Agent registration; check client configurations manually.')
    return preserved


def execute(request, home=None):
    device = request['device']
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,23}', device):
        raise ValueError('Computer name must start with a-z and use up to 24 lowercase letters, digits or hyphens.')
    root = Path(home or Path.home()) / '.tacto' / 'devices'
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder = root / device
    if folder.is_symlink() or root.is_symlink() or folder.resolve().parent != root.resolve():
        raise ValueError('Expected a private device directory without links.')
    auth = Path(home or Path.home()) / '.ssh' / 'authorized_keys'
    auth.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root.parent / 'setup.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if request['action'] == 'prepare':
            return prepare(request, root, folder, auth)
        if request['action'] == 'remove' and not folder.exists():
            return {'removed': True, 'purged': True}
        state = json.loads((folder / 'state.json').read_text())
        if state['clientId'] != request['clientId']:
            raise RuntimeError('Installation identity mismatch.')
        if request['action'] == 'check':
            return check(state, folder, core_only=request.get('healthScope') == 'activation')
        if request['action'] == 'configure':
            skill = request.get('skillText')
            if not isinstance(skill, str) or len(skill) > 20000:
                raise ValueError('Expected a bounded target Skill.')
            write(folder / 'skill' / 'SKILL.md', skill)
            preserved = reconcile_integrations(folder, state, replacement_skill=skill)
            return {'configured': True, 'preservedIntegrations': preserved}
        if request['action'] == 'remove':
            preserved = reconcile_integrations(folder, state)
            for kind in ('tunnel',):
                edit_authorized(auth, 'tacto:' + device + ':' + kind)
            if request.get('purge', True):
                shutil.rmtree(folder)
                return {'removed': True, 'purged': True, 'preservedIntegrations': preserved}
            state['removed'] = True
            write(folder / 'state.json', json.dumps(state, indent=2) + '\n')
            return {'removed': True, 'retainedBackup': str(folder)}
        raise ValueError('Unknown action.')


if __name__ == '__main__':
    try:
        managed = sys.argv[1] == '--managed'
        encoded = os.environ.get('SSH_ORIGINAL_COMMAND', '') if managed else sys.argv[1]
        request = json.loads(base64.b64decode(encoded, validate=True))
        if managed and (request['device'] != Path(__file__).parent.name or request['action'] not in ('check', 'remove', 'configure')):
            raise ValueError('Unsupported managed request.')
        result = execute(request)
        print('TACTO_SETUP_JSON=' + json.dumps({'ok': True, 'result': result}, ensure_ascii=True))
    except Exception as error:
        print('TACTO_SETUP_JSON=' + json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=True))
        sys.exit(1)
