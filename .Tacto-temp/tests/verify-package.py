import hashlib
import json
from pathlib import Path
import sys
import tarfile
import zipfile

root = Path(__file__).resolve().parents[2]
if len(sys.argv) > 1:
    archive = Path(sys.argv[1])
    if archive.suffix == '.tgz':
        with tarfile.open(archive) as bundle:
            names = {member.name for member in bundle.getmembers() if member.isfile()}
            assert 'package/bin/tacto.mjs' in names
            assert 'package/Setup-Tacto.ps1' in names
            assert 'package/README.md' in names
            for name in names:
                relative = Path(name).relative_to('package')
                assert str(relative).split('/')[0] != '.Tacto-temp'
                assert bundle.extractfile(name).read() == (root / relative).read_bytes(), name
    else:
        with zipfile.ZipFile(archive) as bundle:
            prefix = 'Tacto-0.1.0/'
            manifest = json.loads(bundle.read(prefix+'manifest.json'))
            assert manifest['product'] == 'Tacto'
            for row in manifest['files']:
                content=bundle.read(prefix+row['path'])
                assert len(content)==row['bytes']
                assert hashlib.sha256(content).hexdigest()==row['sha256']
            assert prefix+'bin/tacto.mjs' in bundle.namelist()
    print('PASS: package content and integrity:',archive.name)
