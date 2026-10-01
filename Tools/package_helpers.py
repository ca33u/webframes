#!/usr/bin/env python3
"""Xcode build phase: embed and sign locked offline helpers (Apple Silicon)."""
import json
import os
from pathlib import Path
import shutil
import subprocess

root = Path(os.environ['SRCROOT'])
contents = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['WRAPPER_NAME'] / 'Contents'
runtime = root / 'Tools/runtime-dist/node-v22.23.2-darwin-arm64'
catalog = root / 'Tools/component-catalog'
if 'x86_64' in os.environ.get('ARCHS', ''):
    raise SystemExit('This runtime supports arm64 only.')
if not (runtime / 'bin/node').is_file() or not (catalog / 'node_modules/vite/package.json').is_file():
    raise SystemExit('Run python3 Tools/prepare_runtime.py before building.')
dest = contents / 'Resources/Tools'
dest.mkdir(parents=True, exist_ok=True)
for name in ('codex-bridge.mjs', 'context-mcp.mjs', 'comments-mcp.mjs', 'comments-mutations.mjs'):
    shutil.copy2(root / 'Tools' / name, dest / name)
target = dest / 'component-catalog'
if target.exists():
    shutil.rmtree(target)
target.mkdir()
for name in ('server.mjs','project-postcss.mjs','preview-boundaries.mjs', 'discover.mjs', 'package.json', 'package-lock.json'):
    shutil.copy2(catalog / name, target / name)
for name in ('client', 'node_modules'):
    shutil.copytree(catalog / name, target / name, symlinks=True,
                    ignore=shutil.ignore_patterns('.DS_Store', '.cache', '.vite'))
node = contents / 'Helpers/node'
node.parent.mkdir(exist_ok=True)
shutil.copy2(runtime / 'bin/node', node)
notices = contents / 'Resources/ThirdPartyNotices'
notices.mkdir(exist_ok=True)
shutil.copy2(runtime / 'LICENSE', notices / 'Node.js-LICENSE.txt')
identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
flags = ['--force', '--sign', identity, '--options', 'runtime']
flags += ['--timestamp' if identity != '-' and os.environ.get('CONFIGURATION') == 'Release' else '--timestamp=none']
for addon in target.rglob('*.node'):
    subprocess.run(['/usr/bin/codesign', *flags, str(addon)], check=True)
subprocess.run(['/usr/bin/codesign', *flags, '--identifier', 'app.essazanov.webframes.node', '--entitlements', str(root / 'Tools/node.entitlements'), str(node)], check=True)
(dest / 'runtime-manifest.json').write_text(json.dumps({
    'node': '22.23.2', 'architecture': 'arm64', 'nodeEntitlements': ['com.apple.security.cs.allow-jit'],
    'dependencies': json.loads((catalog / 'package.json').read_text())['dependencies']
}, indent=2) + '\n')
