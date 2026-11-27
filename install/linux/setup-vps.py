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


# Include the previous layout so older runtimes can still roll back and remove files.
SKILL_PATH = re.compile(r'SKILL\.md|(?:official|references)/[A-Za-z0-9_.-]+')
MCP_NAME_RE = re.compile(r'[a-zA-Z][a-zA-Z0-9_-]{0,63}')
SKILL_NAME_RE = re.compile(r'[a-z][a-z0-9-]{0,63}')


def run(args, data=None, timeout=45):
    result = subprocess.run(args, input=data, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('%s failed: %s' % (args[0], result.stderr[-1800:]))
    return result.stdout.strip()


def write(path, text, mode=0o600):
    target = path
    if path.is_symlink():
        resolved = path.resolve(strict=False)
        if resolved.is_symlink():
            raise ValueError('Refusing chained symbolic link: ' + str(path))
        target = resolved
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = target.with_name(f'.{target.name}.{os.getpid()}.new')
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(text)
        os.chmod(temp, mode)
        temp.replace(target)
    except Exception:
        temp.unlink(missing_ok=True)
        raise


def edit_authorized(path, marker, line=None):
    lines = path.read_text(encoding='utf-8').splitlines() if path.exists() else []
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
            try:
                state = json.loads(file.read_text(encoding='utf-8'))
                if isinstance(state, dict) and not state.get('removed') and isinstance(state.get('reversePort'), int):
                    reserved.add(state['reversePort'])
            except (OSError, ValueError, TypeError):
                continue
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
    mcp_name, skill_name = target_names(request)
    state_path = folder / 'state.json'
    previous = json.loads(state_path.read_text(encoding='utf-8')) if state_path.exists() else None
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
    callback_key = public_key(key.with_suffix('.pub').read_text(encoding='utf-8'))
    host_key = public_key(request['windowsHostKey'])
    user = request['windowsUser']
    driver = request['driverPath']
    if any(c in user + driver for c in '\r\n\0') or not re.fullmatch(r'[A-Za-z]:\\.+\\cua-driver\.exe', driver):
        raise ValueError('Invalid Windows account or CUA path.')
    ssh_bin = shutil.which('ssh') or '/usr/bin/ssh'
    config = ('Host windows\n HostName 127.0.0.1\n Port %d\n User %s\n IdentityFile %s\n'
              ' HostKeyAlias tacto-windows\n UserKnownHostsFile %s\n StrictHostKeyChecking yes\n'
              ' IdentitiesOnly yes\n BatchMode yes\n ConnectTimeout 12\n ServerAliveInterval 15\n ServerAliveCountMax 3\n') % (
                  port, json.dumps(user, ensure_ascii=False), json.dumps(str(key), ensure_ascii=False), json.dumps(str(folder / 'known_hosts'), ensure_ascii=False))
    write(folder / 'ssh_config', config)
    write(folder / 'known_hosts', 'tacto-windows ' + host_key + '\n')
    write(folder / 'cua-proxy', '#!/bin/sh\nexec %s -T -F %s windows cua-mcp\n' % (
        shlex.quote(ssh_bin), shlex.quote(str(folder / 'ssh_config'))), 0o700)
    source = globals().get('BOOTSTRAP_SOURCE')
    if source:
        write(folder / 'setup-vps.py', source, 0o700)
    state = dict(device=request['device'], clientId=request['clientId'], reversePort=port,
                 windowsKey=callback_key, driverPath=driver, vpsUser=run(['id', '-un']),
                 mcpName=mcp_name, skillName=skill_name, managementVersion=3)
    if request.get('skillText') or request.get('skillFiles'):
        install_skill(folder, skill_files(request, folder))
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
                               stderr=subprocess.DEVNULL, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending_bytes = bytearray()
    def send(value):
        process.stdin.write((json.dumps(value) + '\n').encode('utf-8'))
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
            message = json.loads(line.decode('utf-8'))
            if 'method' in message and 'id' in message:
                send(dict(jsonrpc='2.0', id=message['id'], **({'result': {}} if message['method'] == 'ping' else {'error': {'code': -32601, 'message': 'Unsupported client method'}})))
                continue
            if message.get('id') == number and 'method' not in message:
                if 'error' in message:
                    raise RuntimeError('MCP endpoint rejected ' + method)
                return message['result']
        raise RuntimeError('Too many MCP notifications.')
    try:
        next_id = 1
        hello = request(next_id, 'initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='tacto-vps-check', version='1')))
        next_id += 1
        if hello.get('protocolVersion') not in ('2024-11-05', '2025-03-26', '2025-06-18'):
            raise RuntimeError('Unsupported MCP protocol version.')
        send(dict(jsonrpc='2.0', method='notifications/initialized'))
        tools = []
        cursors = set()
        cursor = None
        for page in range(100):
            listed = request(next_id, 'tools/list', {'cursor': cursor} if cursor is not None else {})
            next_id += 1
            tools.extend(listed.get('tools', []))
            cursor = listed.get('nextCursor')
            if cursor is None:
                break
            if not isinstance(cursor, str) or not cursor or cursor in cursors or page == 99:
                raise RuntimeError('Invalid MCP pagination.')
            cursors.add(cursor)
        if not any(t.get('name') == 'health_report' for t in tools):
            raise RuntimeError('Missing health_report capability.')
        arguments = {'include': ['binary_version', 'platform_supported', 'session_active', 'screen_capture_capability']} if core_only else {}
        result = request(next_id, 'tools/call', dict(name='health_report', arguments=arguments))
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
    ssh_bin = shutil.which('ssh') or '/usr/bin/ssh'
    health = mcp_health([ssh_bin, '-T', '-F', str(folder / 'ssh_config'), 'windows', 'cua-health'], core_only=core_only)
    return {'connected': True, 'status': 'Windows MCP health verified', 'health': health}


def target_names(request):
    legacy = ('computer-' + request['device'], 'tacto-' + request['device'])
    mcp_name = request.get('mcpName', legacy[0])
    skill_name = request.get('skillName', legacy[1])
    if not isinstance(mcp_name, str) or not isinstance(skill_name, str) or not MCP_NAME_RE.fullmatch(mcp_name) or not SKILL_NAME_RE.fullmatch(skill_name):
        raise ValueError('Invalid target naming contract.')
    return (mcp_name, skill_name)


def skill_files(request, folder):
    files = request.get('skillFiles', {'SKILL.md': request.get('skillText')})
    if not isinstance(files, dict) or 'SKILL.md' not in files or len(files) > 64:
        raise ValueError('Expected a bounded target Skill pack.')
    if sum(len(value.encode('utf-8')) for value in files.values() if isinstance(value, str)) > 2 * 1024 * 1024:
        raise ValueError('Skill pack exceeds 2 MiB.')
    for name, value in files.items():
        if not SKILL_PATH.fullmatch(name) or not isinstance(value, str):
            raise ValueError('Invalid Skill file.')
    prefix = request.get('cliPrefix', 'npx -y tacto-mcp@latest driver') + ' --proxy ' + shlex.quote(str(folder / 'cua-proxy'))
    return {name: value.replace('{{VPS_CLI}}', prefix) if name == 'SKILL.md' else value for name, value in files.items()}


def install_skill(folder, files):
    manifest = folder / 'skill-manifest.json'
    previous = json.loads(manifest.read_text(encoding='utf-8')) if manifest.exists() else ['SKILL.md']
    for name in previous:
        if not SKILL_PATH.fullmatch(name):
            raise ValueError('Invalid Skill manifest path.')
    for name, value in files.items():
        write(folder / 'skill' / name, value)
    for name in set(previous) - set(files):
        (folder / 'skill' / name).unlink(missing_ok=True)
    prune_skill([dict(root=str(folder / 'skill'), path=str(folder / 'skill' / name)) for name in previous])
    write(manifest, json.dumps(list(files)))


def integration_files(record, device):
    files = record.get('files')
    if files is None:
        files = [dict(path=record['skill'], hash=record['skillHash'], root=str(Path(record['skill']).parent))] if record.get('skill') else []
    expected_root = record.get('skillName') or ('tacto-computer' if record['name'] == 'tacto-mcp' else ('tacto-' + record['name'][9:] if record['name'].startswith('computer-') else 'tacto-computer'))
    if not isinstance(expected_root, str) or not SKILL_NAME_RE.fullmatch(expected_root):
        raise ValueError('Invalid integration path.')
    for file in files:
        root, path = Path(file['root']), Path(file['path'])
        name = path.relative_to(root).as_posix()
        if root.name != expected_root or not SKILL_PATH.fullmatch(name):
            raise ValueError('Invalid integration path.')
    return files


def prune_skill(files):
    directories = {Path(file['root']) for file in files} | {Path(file['path']).parent for file in files}
    for directory in sorted(directories, key=lambda path: len(path.parts), reverse=True):
        if directory.is_dir() and not any(directory.iterdir()):
            directory.rmdir()


def reconcile_integrations(folder, state, replacement_skill=None, replacement_names=None):
    registry = folder / 'agent-integrations.json'
    preserved = []
    if not registry.exists():
        return preserved
    try:
        registrations = json.loads(registry.read_text(encoding='utf-8'))
        if not isinstance(registrations, list):
            raise ValueError('Expected registrations list')
    except (ValueError, OSError):
        return ['Agent registrations were unreadable; check the client configurations manually.']
    for registration in registrations:
        receipt = None
        originals = {}
        try:
            receipt = Path(registration['receipt'])
            if registration.get('clientId') != state['clientId'] or not receipt.is_file():
                continue
            record = json.loads(receipt.read_text(encoding='utf-8'))
            config = Path(record['config'])
            expected_receipt = str(config) + '.tacto-' + state['device'] + '.json'
            if str(receipt) != expected_receipt or not isinstance(record.get('name'), str) or not MCP_NAME_RE.fullmatch(record['name']) or record.get('device', state['device']) != state['device'] or record['server'] != state['mcp']:
                raise ValueError('Integration identity mismatch')
            if 'device' not in record and record['name'] not in ('tacto-mcp', 'computer-' + state['device']):
                raise ValueError('Integration identity mismatch')
            files = integration_files(record, state['device'])
            effective_names = replacement_names
            effective_skill = replacement_skill
            if replacement_skill is not None and record.get('customNames'):
                effective_names = (record['name'], record.get('skillName') or replacement_names[1])
                if effective_names != replacement_names and 'SKILL.md' in replacement_skill:
                    adapted_entry = replacement_skill['SKILL.md']
                    adapted_entry = re.sub(r'^name:\s*\S+', 'name: ' + effective_names[1], adapted_entry, count=1, flags=re.MULTILINE)
                    adapted_entry = adapted_entry.replace('the ' + replacement_names[0] + ' MCP server', 'the ' + effective_names[0] + ' MCP server')
                    adapted_entry = adapted_entry.replace('server `' + replacement_names[0] + '`', 'server `' + effective_names[0] + '`')
                    effective_skill = {**replacement_skill, 'SKILL.md': adapted_entry}
            desired = []
            if effective_skill is not None:
                for root in {str(Path(file['root']).parent / effective_names[1]) for file in files}:
                    desired.extend(dict(root=root, path=str(Path(root) / name), hash=hashlib.sha256(text.encode('utf-8')).hexdigest(), text=text) for name, text in effective_skill.items())
            old = {file['path']: file for file in files}
            conflicts = []
            for file in files + desired:
                path = Path(file['path'])
                if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != old.get(str(path), {}).get('hash'):
                    conflicts.append(str(path))
            if effective_skill is not None and conflicts:
                preserved.extend(sorted(set(conflicts)))
                continue
            edited = bool(conflicts)
            for path in [config, receipt] + [Path(file['path']) for file in files + desired]:
                if path not in originals:
                    originals[path] = path.read_bytes() if path.exists() else None
            if config.exists():
                raw_cfg = config.read_text(encoding='utf-8-sig').strip()
                document = json.loads(raw_cfg) if raw_cfg else {}
                entry = document.get('mcpServers', {}).get(record['name'])
                if entry == record['server'] and effective_skill is None:
                    del document['mcpServers'][record['name']]
                    write(config, json.dumps(document, indent=2) + '\n')
                elif entry is not None and entry != record['server']:
                    preserved.append(str(config)); edited = True
                    if effective_skill is not None:
                        continue
                if effective_skill is not None:
                    name = effective_names[0]
                    existing = document.get('mcpServers', {}).get(name)
                    if name != record['name'] and existing is not None:
                        preserved.append(str(config))
                        continue
                    if entry is not None:
                        del document['mcpServers'][record['name']]
                        document['mcpServers'][name] = record['server']
                        write(config, json.dumps(document, indent=2) + '\n')
            desired_paths = {file['path'] for file in desired}
            for file in files:
                path = Path(file['path'])
                if path.exists() and str(path) not in desired_paths and str(path) not in conflicts:
                    path.unlink()
            preserved.extend(sorted(set(conflicts)))
            for file in desired:
                write(Path(file['path']), file['text'])
            prune_skill(files)
            if effective_skill is None:
                if not edited:
                    receipt.unlink()
            else:
                record['schema'] = 2
                record['device'] = state['device']
                record['name'] = effective_names[0]
                record['skillName'] = effective_names[1]
                record['skill'] = next((file['path'] for file in desired if Path(file['path']) == Path(file['root']) / 'SKILL.md'), None)
                record['files'] = [{key: value for key, value in file.items() if key != 'text'} for file in desired]
                record['skillHash'] = hashlib.sha256(effective_skill['SKILL.md'].encode('utf-8')).hexdigest() if record.get('skill') else None
                write(receipt, json.dumps(record, indent=2) + '\n')
        except (OSError, ValueError, KeyError, TypeError):
            for path, original in originals.items():
                if original is None:
                    path.unlink(missing_ok=True)
                else:
                    write(path, original.decode('utf-8'))
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
        state = json.loads((folder / 'state.json').read_text(encoding='utf-8'))
        if state['clientId'] != request['clientId']:
            raise RuntimeError('Installation identity mismatch.')
        if request['action'] == 'check':
            return check(state, folder, core_only=request.get('healthScope') == 'activation')
        if request['action'] == 'configure':
            names = target_names(request)
            files = skill_files(request, folder)
            install_skill(folder, files)
            preserved = reconcile_integrations(folder, state, replacement_skill=files, replacement_names=names)
            state['mcpName'] = names[0]
            state['skillName'] = names[1]
            write(folder / 'state.json', json.dumps(state, indent=2) + '\n')
            write(folder / 'mcp.json', json.dumps({'mcpServers': {names[0]: state['mcp']}}, indent=2) + '\n')
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
        if encoded == 'tacto-stdin-v2':
            raw = sys.stdin.buffer.read(3 * 1024 * 1024 + 1)
            if len(raw) > 3 * 1024 * 1024:
                raise ValueError('Management request exceeds 3 MiB.')
            request = json.loads(raw)
        else:
            request = json.loads(base64.b64decode(encoded, validate=True))
        if managed and (request['device'] != Path(__file__).parent.name or request['action'] not in ('check', 'remove', 'configure')):
            raise ValueError('Unsupported managed request.')
        result = execute(request)
        print('TACTO_SETUP_JSON=' + json.dumps({'ok': True, 'result': result}, ensure_ascii=True))
    except Exception as error:
        print('TACTO_SETUP_JSON=' + json.dumps({'ok': False, 'error': str(error)}, ensure_ascii=True))
        sys.exit(1)
