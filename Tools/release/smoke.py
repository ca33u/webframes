"""Exercise packaged helpers, never launch the Web Frames GUI or an AI job."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.error
from urllib.parse import quote

app = Path(sys.argv[1]).resolve()
node = app / 'Contents/Helpers/node'
tools = app / 'Contents/Resources/Tools'
env = dict(os.environ, PATH='/usr/bin:/bin')
env.pop('NODE_OPTIONS', None)
env.pop('NODE_PATH', None)

def read(url, headers=None):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=3) as r:
        return r.read()

def eventually(fn, process):
    for _ in range(200):
        if process.poll() is not None: raise RuntimeError('Helper exited early')
        try: return fn()
        except (OSError, ValueError): time.sleep(.1)
    raise RuntimeError('Helper timed out')

with tempfile.TemporaryDirectory(prefix='Web Frames Installed Smoke ') as directory:
    root = Path(directory)
    project = root / 'Project With Spaces'
    project.mkdir()
    (project / 'package.json').write_text('{"name":"smoke","type":"module"}')
    (project / 'Button.tsx').write_text('import {save} from "./actions"; export function Button(){return <button onClick={()=>save()}>Hello</button>}')
    (project / 'actions.ts').write_text('"use server"; import "server-only"; import {db} from "unavailable-database"; export async function save(){return db.write()}')
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]
    with (root / 'catalog.log').open('w+') as log:
        child = subprocess.Popen([str(node), str(tools / 'component-catalog/server.mjs'), str(project), str(port)],
                                 cwd=root, env=env, stdout=log, stderr=log)
        try:
            base = f'http://127.0.0.1:{port}'
            manifest = json.loads(eventually(lambda: read(base + '/catalog.json'), child))
            assert manifest['protocol'] == 'webframes-catalog-v1'
            assert any(c['exportName'] == 'Button' for c in manifest['components'])
            assert b'<html' in read(base + '/')
            # Exercise the native transform addon under Hardened Runtime.
            assert b'Hello' in read(base + '/@fs/' + quote(str((project / 'Button.tsx').resolve())))
            assert b'import' in read(base + '/catalog.jsx')
            component = next(c for c in manifest['components'] if c['exportName'] == 'Button')
            registry = read(base + '/@id/__x00__virtual:webframes/' + component['id'])
            assert registry.count(b'export const load=') == 1
            action = read(base + '/@fs/' + quote(str((project / 'actions.ts').resolve())))
            assert b'Server code is unavailable' in action
            assert b'unavailable-database' not in action and b'server-only' not in action
            print('PASS: packaged per-component registry and server-action boundary', flush=True)
            print('PASS: packaged catalogue discovery, HTML and TSX transformation', flush=True)
        except Exception:
            log.flush(); log.seek(0); print(log.read(), file=sys.stderr); raise
        finally:
            child.terminate(); child.wait(timeout=10)
    bridgeRoot = root / 'connector'
    with (root / 'bridge.log').open('w+') as log:
        child = subprocess.Popen([str(node), str(tools / 'codex-bridge.mjs')], cwd=root,
                                 env=dict(env, WEBFRAMES_BRIDGE_ROOT=str(bridgeRoot), WEBFRAMES_CODEX_BINARY='/usr/bin/false'), stdout=log, stderr=log)
        try:
            connection = eventually(lambda: json.loads((bridgeRoot / 'connection.json').read_text()), child)
            url = connection['url'] + '/health'
            assert json.loads(read(url, {'Authorization': 'Bearer ' + connection['token']}))['ok']
            try: read(url)
            except urllib.error.HTTPError as e: assert e.code == 401
            else: raise AssertionError('Unauthenticated request accepted')
            assert (bridgeRoot / 'connection.json').stat().st_mode & 0o777 == 0o600
            print('PASS: packaged connector health, pairing rejection and private credentials', flush=True)
        finally:
            child.terminate(); child.wait(timeout=10)
    messages = [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2024-11-05', 'capabilities': {}, 'clientInfo': {'name':'smoke','version':'1'}}},
        {'jsonrpc':'2.0','method':'notifications/initialized'},
        {'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}}
    ]
    result = subprocess.run([str(node), str(tools / 'comments-mcp.mjs')],
        input=''.join(json.dumps(m)+'\n' for m in messages), text=True, capture_output=True, cwd=root, env=env, timeout=10, check=True)
    assert 'list_comments' in result.stdout and 'set_comment_status' in result.stdout
    print('PASS: packaged comments MCP initializes and advertises tools')
