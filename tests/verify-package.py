import hashlib
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import subprocess
import zipfile

root = Path(__file__).resolve().parents[1]
metadata = json.loads((root / 'package.json').read_text())
required = ['bin/tacto.mjs', 'src/cli.mjs', 'src/probe.mjs', 'install/windows/Setup-Tacto.ps1',
            'install/linux/setup-vps.py', 'resources/cua-release.json', 'scripts/Package.ps1',
            'README.md', 'docs/VERIFICATION.md', 'docs/DEVELOPMENT.md', 'src/integration.mjs',
            'install/windows/Lifecycle.ps1', 'install/windows/McpHealth.ps1',
            'install/windows/AgentIntegration.ps1', 'install/windows/Update-Available.ps1',
            'resources/tacto-skill.md', 'src/driver-cli.mjs', 'src/skills.mjs',
            'resources/cua-skill/SKILL.md', 'resources/cua-skill/WINDOWS.md',
            'resources/cua-skill/source.json', 'resources/cua-skill/LICENSE',
            'install/skill-references.json', 'scripts/Build-Skill.mjs', 'src/product.mjs']
assert metadata['name'] == 'tacto-computer'
assert metadata['bin'] == {'tacto-cli': 'bin/tacto.mjs'}
assert metadata['tacto'] == {'skillName': 'tacto-computer', 'mcpName': 'tacto-mcp'}
if len(sys.argv) > 1:
    archive = Path(sys.argv[1])
    if archive.suffix == '.tgz':
        with tarfile.open(archive) as bundle:
            names = {member.name for member in bundle.getmembers() if member.isfile()}
            assert all('package/' + name in names for name in required)
            for name in names:
                relative = Path(name).relative_to('package')
                assert str(relative).split('/')[0] != '.Tacto-temp'
                assert bundle.extractfile(name).read() == (root / relative).read_bytes(), name
    else:
        with zipfile.ZipFile(archive) as bundle:
            prefix = 'Tacto-' + metadata['version'] + '/'
            manifest = json.loads(bundle.read(prefix+'manifest.json'))
            assert manifest['product'] == 'Tacto'
            for row in manifest['files']:
                content=bundle.read(prefix+row['path'])
                assert len(content)==row['bytes']
                assert hashlib.sha256(content).hexdigest()==row['sha256']
            assert all(prefix + name in bundle.namelist() for name in required)
    with tempfile.TemporaryDirectory(prefix='package space-', dir=root / '.Tacto-temp') as fixture:
        if archive.suffix == '.tgz':
            with tarfile.open(archive) as bundle:
                bundle.extractall(fixture, filter='data')
            packaged = Path(fixture) / 'package'
        else:
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(fixture)
            packaged = Path(fixture) / ('Tacto-' + metadata['version'])
        result = subprocess.run(['node', str(packaged / 'bin/tacto.mjs'), '--version'], cwd=fixture,
                                capture_output=True, text=True, encoding='utf-8', timeout=20)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == metadata['version']
    print('PASS: package content and integrity:',archive.name)
