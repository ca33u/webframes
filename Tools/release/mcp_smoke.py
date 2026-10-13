"""Offline MCP integration: packaged runtime, large data and optional Claude Code.

Uses throwaway board data and a private CLAUDE_CONFIG_DIR. No AI prompt or
real client configuration is changed. Run: python3 Tools/release/mcp_smoke.py App.app
"""
import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--claude', type=Path)
    args = parser.parse_args()
    contents = args.app.resolve() / 'Contents'
    node, helper = contents / 'Helpers/node', contents / 'Resources/Tools/comments-mcp.mjs'
    assert node.is_file() and helper.is_file(), 'Packaged MCP runtime missing'
    with tempfile.TemporaryDirectory(prefix='wf06-mcp-') as directory:
        root = Path(directory)
        projects = root / 'boards'; projects.mkdir()
        frames = [dict(id=f'f{i}', label=f'Screen {i}', x=i*400, y=0, w=100, h=100) for i in range(350)]
        annotations = [dict(id=f'a{i}', num=i, frameId=f'f{i%350}', comment=f'Update {i}', resolved=i%3==0) for i in range(950)]
        sections = [dict(id=f's{i}', name=f'Pool {i}', x=i*400, y=0, w=200, h=200, referenceFrameId=f'f{i}', task='Match reference') for i in range(261)]
        board = projects / "QA board's variants.webframes"; board.mkdir()
        (board / 'document.json').write_text(json.dumps(dict(name='Large QA', frames=frames, annotations=annotations, sections=sections)))
        for i in range(260): (projects / f'p{i}.webframes').write_text(json.dumps(dict(name=f'Project {i}')))
        environment = dict(PATH='/usr/bin:/bin', WEBFRAMES_PROJECTS_DIR=str(projects))
        child = subprocess.Popen([str(node), str(helper)], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        replies = queue.Queue()
        def reader():
            for line in child.stdout:
                try: replies.put(json.loads(line))
                except Exception as error: replies.put(error)
        threading.Thread(target=reader, daemon=True).start()
        request_id = 0
        def request(method, params=None):
            nonlocal request_id
            request_id += 1
            child.stdin.write(json.dumps(dict(jsonrpc='2.0', id=request_id, method=method, params=params or {}))+'\n'); child.stdin.flush()
            reply = replies.get(timeout=15)
            assert isinstance(reply, dict) and reply.get('id') == request_id, reply
            assert 'error' not in reply, reply
            return reply['result']
        def call(name, arguments=None):
            result = request('tools/call', dict(name=name, arguments=arguments or {}))
            assert not result.get('isError'), result
            return json.loads(result['content'][0]['text'])
        try:
            assert request('initialize', dict(protocolVersion='2024-11-05', capabilities={}, clientInfo=dict(name='Python stdio QA', version='1')))['serverInfo']['version'] == '0.2.0'
            child.stdin.write(json.dumps(dict(jsonrpc='2.0', method='notifications/initialized'))+'\n'); child.stdin.flush()
            tools = request('tools/list')['tools']
            expected_tools = {
                'list_projects', 'list_frames', 'get_frame', 'list_comments', 'get_comment',
                'get_agent_brief', 'set_comment_status', 'list_sections', 'get_section',
                'update_frame_image', 'capture_simulator_frame', 'capture_simulator_frames',
            }
            assert len(tools) == len(expected_tools) and {tool['name'] for tool in tools} == expected_tools
            print('PASS: packaged MCP advertises all 12 tools, including saved native single/batch capture', flush=True)
            for name, key, total, scope in [('list_projects','projects',261,{}), ('list_frames','frames',350,dict(project=board.stem)), ('list_comments','comments',950,dict(project=board.stem,status='all')), ('list_sections','sections',261,dict(project=board.stem))]:
                cursor, ids, pages = None, [], 0
                while True:
                    data = call(name, dict(scope, limit=41, **({'cursor':cursor} if cursor else {})))
                    assert data['pagination']['total'] == total
                    ids.extend(item['id'] for item in data[key]); pages += 1
                    cursor = data['pagination']['nextCursor']
                    if cursor is None: break
                    assert pages < 100
                assert len(ids) == total and len(set(ids)) == total
                print(f'PASS: packaged {name}: {total} items, {pages} pages, no duplicates or omissions', flush=True)
            first = call('list_frames', dict(project=board.stem,limit=1))
            cursor = first['pagination']['nextCursor']
            saved = json.loads((board/'document.json').read_text()); saved['frames'][0]['label']='Changed'
            (board/'document.json').write_text(json.dumps(saved))
            stale = request('tools/call', dict(name='list_frames',arguments=dict(project=board.stem,cursor=cursor)))
            assert stale.get('isError') and 'stale cursor' in stale['content'][0]['text']
            print('PASS: packaged helper rejects a cursor after the board changes', flush=True)
        finally:
            child.stdin.close(); child.wait(timeout=5)
        binary = args.claude or shutil.which('claude')
        if binary:
            profile = root/'claude-profile'; profile.mkdir(mode=0o700)
            config = profile/'.claude.json'
            config.write_text(json.dumps(dict(mcpServers={'webframes-qa':dict(command=str(node),args=[str(helper),'--project',str(board)])})))
            config.chmod(0o600)
            environment = dict(PATH='/usr/bin:/bin', CLAUDE_CONFIG_DIR=str(profile), CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1')
            result = subprocess.run([str(binary),'mcp','get','webframes-qa'], cwd=root, env=environment, capture_output=True, text=True, timeout=25)
            assert result.returncode == 0 and 'Connected' in result.stdout, 'Claude Code MCP health check failed'
            print('PASS: installed Claude Code connects to packaged MCP in an isolated profile; no AI run', flush=True)
        else: print('NOT RUN: Claude Code is not installed; stdio client checks passed', flush=True)


if __name__ == '__main__': main()
