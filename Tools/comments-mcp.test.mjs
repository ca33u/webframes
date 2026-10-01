import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';

const root = mkdtempSync(path.join(tmpdir(), 'webframes-comments-mcp-'));
const projects = path.join(root, 'Projects');
mkdirSync(projects);
const file = path.join(projects, 'demo.webframes');
const screenshot = Buffer.from('fake-png').toString('base64');
writeFileSync(file, JSON.stringify({
  name: 'Demo',
  projectMap: {rootPath: '/tmp/demo-source', framework: 'Next.js'},
  frames: [{id: 'f1', label: 'Home', url: 'https://raw.githubusercontent.com/acme/site/main/index.html?token=legacy-secret', w: 1280, h: 800}],
  annotations: [{
    id: 'a1', num: 1, frameId: 'f1', comment: 'Increase heading size', resolved: false,
    xPct: 20, yPct: 30, color: 'orange', edits: {},
    element: {selector: 'h1', text: 'Hello', screenshot: `data:image/png;base64,${screenshot}`},
  }, {
    id: 'a2', num: 2, frameId: 'f1', comment: 'Tighten this card grid', resolved: false,
    xPct: 10, yPct: 40, area: {wPct: 30, hPct: 20}, color: 'blue', edits: {},
    element: {selector: 'section.cards', area: {x: 128, y: 320, width: 384, height: 160},
      areaElements: [{selector: 'div.card', text: 'Revenue'}]},
  }],
}));

const server = spawn(process.execPath, [new URL('./comments-mcp.mjs', import.meta.url).pathname], {
  env: {...process.env, WEBFRAMES_PROJECTS_DIR: projects},
  stdio: ['pipe', 'pipe', 'inherit'],
});

let buffer = '';
const pending = new Map();
server.stdout.on('data', chunk => {
  buffer += chunk;
  while (buffer.includes('\n')) {
    const end = buffer.indexOf('\n');
    const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
    if (!line) continue;
    const message = JSON.parse(line);
    pending.get(message.id)?.(message);
    pending.delete(message.id);
  }
});

function request(id, method, params = {}) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timed out: ${method}`)), 3000);
    pending.set(id, message => { clearTimeout(timer); resolve(message); });
    server.stdin.write(JSON.stringify({jsonrpc: '2.0', id, method, params}) + '\n');
  });
}

test('comments MCP lists, reads and briefs saved comments without secrets', async () => {
try {
  const init = await request(1, 'initialize', {protocolVersion: '2024-11-05'});
  assert.equal(init.result.serverInfo.name, 'webframes-comments');
  const list = await request(2, 'tools/call', {name: 'list_comments', arguments: {status: 'open'}});
  const payload = JSON.parse(list.result.content[0].text);
  assert.equal(payload.project.sourceRoot, '/tmp/demo-source');
  assert.equal(payload.comments[0].element.selector, 'h1');
  assert.equal(payload.comments[0].comment, 'Increase heading size');
  assert.ok(!payload.comments[0].frame.url.includes('legacy-secret'));
  assert.ok(!payload.comments[0].frame.url.includes('token='));
  const detail = await request(3, 'tools/call', {name: 'get_comment', arguments: {id: 'a1'}});
  assert.equal(detail.result.content[1].type, 'image');
  assert.equal(detail.result.content[1].data, screenshot);
  const brief = await request(4, 'tools/call', {name: 'get_agent_brief', arguments: {}});
  assert.match(brief.result.content[0].text, /Increase heading size/);
  assert.match(brief.result.content[0].text, /Area: x 128, y 320, 384×160 CSS px of the viewport; contains div\.card "Revenue"/);
  assert.equal(payload.comments[0].element.area, null);
  assert.equal(payload.comments[1].element.area.width, 384);
  const updated = JSON.parse((await import('node:fs')).readFileSync(file, 'utf8'));
  updated.annotations[0].comment = 'Updated while Claude is connected';
  writeFileSync(file, JSON.stringify(updated));
  const live = await request(5, 'tools/call', {name: 'list_comments', arguments: {status: 'open'}});
  assert.equal(JSON.parse(live.result.content[0].text).comments[0].comment, 'Updated while Claude is connected');
} finally {
  server.kill();
  rmSync(root, {recursive: true, force: true});
}
});


test('comments MCP reads package documents and their screenshot files', async () => {
  const {createHash} = await import('node:crypto');
  const base = mkdtempSync(path.join(tmpdir(), 'webframes-comments-pkg-'));
  const dir = path.join(base, 'Projects');
  const pkg = path.join(dir, 'pkg.webframes');
  mkdirSync(path.join(pkg, 'images'), {recursive: true});
  const png = Buffer.from('fake-png-bytes');
  const digest = createHash('sha256').update(png).digest('hex');
  writeFileSync(path.join(pkg, 'images', `${digest}.png`), png);
  writeFileSync(path.join(pkg, 'document.json'), JSON.stringify({
    version: 2, name: 'Package', frames: [{id: 'f1', label: 'Home', url: 'https://example.com', w: 390, h: 844}],
    annotations: [{id: 'a1', num: 1, frameId: 'f1', comment: 'Tighten spacing', resolved: false, xPct: 1, yPct: 2,
      color: 'blue', edits: {}, element: {selector: '.card', screenshot: `wf-image:images/${digest}.png`}}],
  }));
  const child = spawn(process.execPath, [new URL('./comments-mcp.mjs', import.meta.url).pathname], {
    env: {...process.env, WEBFRAMES_PROJECTS_DIR: dir}, stdio: ['pipe', 'pipe', 'inherit'],
  });
  const replies = [];
  child.stdout.on('data', chunk => replies.push(...chunk.toString().trim().split('\n').map(line => JSON.parse(line))));
  child.stdin.write(JSON.stringify({jsonrpc: '2.0', id: 1, method: 'tools/call', params: {name: 'list_projects', arguments: {}}}) + '\n');
  child.stdin.write(JSON.stringify({jsonrpc: '2.0', id: 2, method: 'tools/call', params: {name: 'get_comment', arguments: {id: 'a1'}}}) + '\n');
  try {
    for (let i = 0; i < 60 && replies.length < 2; i++) await new Promise(r => setTimeout(r, 50));
    const projects = JSON.parse(replies.find(r => r.id === 1).result.content[0].text);
    assert.equal(JSON.stringify(projects).includes('Package'), true);
    const detail = replies.find(r => r.id === 2).result;
    assert.equal(detail.content[1].type, 'image');
    assert.equal(detail.content[1].data, png.toString('base64'));
  } finally {
    child.kill();
    rmSync(base, {recursive: true, force: true});
  }
});
