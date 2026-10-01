#!/usr/bin/env python3
"""Developer-only preparation; users never run npm to install Web Frames."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import urllib.request

# tarfile.extractall(filter='data') below rejects unsafe archive members;
# the filter argument exists from Python 3.12.
if sys.version_info < (3, 12):
    raise SystemExit('prepare_runtime.py needs Python 3.12 or later (for safe tar extraction).')

root = Path(__file__).resolve().parent
version = 'node-v22.23.2-darwin-arm64'
dist = root / 'runtime-dist'
dist.mkdir(exist_ok=True)
archive = dist / (version + '.tar.gz')
if not archive.exists():
    urllib.request.urlretrieve('https://nodejs.org/download/release/v22.23.2/' + archive.name, archive)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
if digest != '61130f394c1630d211dd50aecc4353d379480f36d3ac913cd85dbba1aed585c6':
    raise SystemExit('Node download checksum mismatch')
with tarfile.open(archive) as tar:
    tar.extractall(dist, filter='data')
runtime = dist / version
env = dict(os.environ, PATH=str(runtime / 'bin') + ':' + os.environ.get('PATH', ''))
env.pop('NODE_OPTIONS', None)
env.pop('NODE_PATH', None)
subprocess.run([str(runtime / 'bin/node'), str(runtime / 'lib/node_modules/npm/bin/npm-cli.js'),
                'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'],
               cwd=root / 'component-catalog', env=env, check=True)

from runtime_filelists import generate
generate(root)

# Keep the bundled third-party notices in step with the locked dependencies.
subprocess.run([sys.executable, str(Path(__file__).with_name('generate_notices.py'))], check=True)
