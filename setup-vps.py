"""Per-computer SSH bridge setup; invoked by Setup-Tacto.ps1 over SSH."""
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import sys


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
            reserved.add(json.loads(file.read_text())['reversePort'])
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
                 mcpName='computer-' + request['device'])
    control = 'python3 %s --managed' % shlex.quote(str(folder / 'setup-vps.py'))
    edit_authorized(auth, 'tacto:' + request['device'] + ':tunnel',
                    'restrict,port-forwarding,permitlisten="127.0.0.1:%d",command="%s" %s' % (
                        port, control.replace('"', '\\"'), public_key(request['tunnelPublicKey'])))
    state['mcp'] = {'command': str(folder / 'cua-proxy'), 'args': []}
    write(folder / 'mcp.json', json.dumps({'mcpServers': {state['mcpName']: state['mcp']}}, indent=2) + '\n')
    write(state_path, json.dumps(state, indent=2) + '\n')
    return state


def check(state, folder):
    version = run(['ssh', '-T', '-F', str(folder / 'ssh_config'), 'windows', 'cua-status'], timeout=35)
    if 'daemon is running' not in version:
        raise RuntimeError('Windows CUA is not running: ' + version)
    return {'connected': True, 'status': version}


def execute(request, home=None):
    device = request['device']
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,23}', device):
        raise ValueError('Computer name must start with a-z and use up to 24 lowercase letters, digits or hyphens.')
    root = Path(home or Path.home()) / '.tacto' / 'devices'
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder = root / device
    auth = Path(home or Path.home()) / '.ssh' / 'authorized_keys'
    auth.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root.parent / 'setup.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if request['action'] == 'prepare':
            return prepare(request, root, folder, auth)
        state = json.loads((folder / 'state.json').read_text())
        if state['clientId'] != request['clientId']:
            raise RuntimeError('Installation identity mismatch.')
        if request['action'] == 'check':
            return check(state, folder)
        if request['action'] == 'remove':
            for kind in ('tunnel',):
                edit_authorized(auth, 'tacto:' + device + ':' + kind)
            state['removed'] = True
            write(folder / 'state.json', json.dumps(state, indent=2) + '\n')
            return {'removed': True, 'retainedBackup': str(folder)}
        raise ValueError('Unknown action.')


if __name__ == '__main__':
    try:
        managed = sys.argv[1] == '--managed'
        encoded = os.environ.get('SSH_ORIGINAL_COMMAND', '') if managed else sys.argv[1]
        request = json.loads(base64.b64decode(encoded, validate=True))
        if managed and (request['device'] != Path(__file__).parent.name or request['action'] not in ('check', 'remove')):
            raise ValueError('Unsupported managed request.')
        result = execute(request)
        print('TACTO_SETUP_JSON=' + json.dumps({'ok': True, 'result': result}, ensure_ascii=True))
    except Exception as error:
        print('TACTO_SETUP_JSON=' + json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=True))
        sys.exit(1)
