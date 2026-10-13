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
  sections: [{id: 's1', name: 'Onboarding', x: -100, y: -100, w: 2000, h: 1200,
    referenceFrameId: 'f1', task: 'Unify primary buttons using Home'}],
  frames: [{id: 'f1', label: 'Home', url: 'https://raw.githubusercontent.com/acme/site/main/index.html?token=legacy-secret', x: 0, y: 0, w: 1280, h: 800}],
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
  const frames = JSON.parse((await request(20, 'tools/call', {name: 'list_frames', arguments: {}})).result.content[0].text).frames;
  assert.equal(frames[0].flow, null);
  assert.equal(frames[0].deeplink, null);
  assert.equal(frames[0].sectionId, 's1');
  assert.equal(frames[0].isReference, true);
  const sections = JSON.parse((await request(21, 'tools/call', {name: 'list_sections', arguments: {}})).result.content[0].text).sections;
  assert.deepEqual(sections[0].frameIds, ['f1']);
  assert.equal(sections[0].referenceFrameId, 'f1');
  assert.equal(sections[0].referenceStatus, 'available');
  assert.equal(sections[0].reference.label, 'Home');
  assert.equal(sections[0].task, 'Unify primary buttons using Home');
  const detail = await request(3, 'tools/call', {name: 'get_comment', arguments: {id: 'a1'}});
  assert.equal(detail.result.content[1].type, 'image');
  assert.equal(detail.result.content[1].data, screenshot);
  const brief = await request(4, 'tools/call', {name: 'get_agent_brief', arguments: {}});
  assert.match(brief.result.content[0].text, /Increase heading size/);
  assert.match(brief.result.content[0].text, /Section: Onboarding/);
  assert.match(brief.result.content[0].text, /User-selected reference: Home · frame_id: f1/);
  assert.match(brief.result.content[0].text, /height, radius, color, font and padding/);
  assert.equal(payload.comments[0].frame.section, 'Onboarding');
  assert.match(brief.result.content[0].text, /Area: x 128, y 320, 384×160 CSS px of the viewport; contains div\.card "Revenue"/);
  assert.equal(payload.comments[0].element.area, null);
  assert.equal(payload.comments[1].element.area.width, 384);
  const updated = JSON.parse((await import('node:fs')).readFileSync(file, 'utf8'));
  updated.annotations[0].comment = 'Updated while Claude is connected';
  writeFileSync(file, JSON.stringify(updated));
  const live = await request(5, 'tools/call', {name: 'list_comments', arguments: {status: 'open'}});
  assert.equal(JSON.parse(live.result.content[0].text).comments[0].comment, 'Updated while Claude is connected');
  // Moving a reference out never silently chooses a different member.
  updated.frames[0].x = 4000;
  writeFileSync(file, JSON.stringify(updated));
  const missing = JSON.parse((await request(22, 'tools/call', {name: 'list_sections', arguments: {}})).result.content[0].text).sections[0];
  assert.equal(missing.referenceFrameId, 'f1');
  assert.equal(missing.referenceStatus, 'unavailable');
  assert.equal(missing.reference, null);
  assert.deepEqual(missing.frameIds, []);
  const unavailableBrief = (await request(23, 'tools/call', {name: 'get_agent_brief', arguments: {}})).result.content[0].text;
  assert.match(unavailableBrief, /UNAVAILABLE \(f1\)/);
  delete updated.sections[0].referenceFrameId;
  writeFileSync(file, JSON.stringify(updated));
  const cleared = JSON.parse((await request(24, 'tools/call', {name: 'list_sections', arguments: {}})).result.content[0].text).sections[0];
  assert.equal(cleared.referenceStatus, 'not_selected');
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
    version: 2, name: 'Package', frames: [{id: 'f1', label: 'Home', url: 'image://Home', w: 390, h: 844,
      isImage: true, imgUrl: `wf-image:images/${digest}.png`, imageUpdatedBy: 'MCP agent',
      flow: 'appId: app.essazanov.Comin\n---\n- launchApp\n- tapOn: Забыли пароль?',
      deeplink: 'comin://recovery?screen=reset&token=private-token',
      simulatorCapture: {platform: 'android', deviceID: 'android-avd:Comin', deviceName:'Comin', appBundleID:'com.essazanov.comin', steps:[{action:'type', value:'private-token'}], build:{projectPath:'/Private/Comin/Android', module:'app', variant:'Debug'}, testState:{name:'Recovery', account:'private-account', data:{email:'private-email'}, theme:'dark', launchArguments:['private-argument'], preparation:[{action:'type',value:'private-setup'}], readySelector:'private-ready'}, deeplink:'comin://recovery?token=private-token'}}],
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
  child.stdin.write(JSON.stringify({jsonrpc: '2.0', id: 3, method: 'tools/call', params: {name: 'list_frames', arguments: {}}}) + '\n');
  child.stdin.write(JSON.stringify({jsonrpc: '2.0', id: 4, method: 'tools/call', params: {name: 'get_frame', arguments: {frame_id: 'f1'}}}) + '\n');
  child.stdin.write(JSON.stringify({jsonrpc: '2.0', id: 5, method: 'tools/list'}) + '\n');
  child.stdin.write(JSON.stringify({jsonrpc: '2.0', id: 6, method: 'tools/call', params: {name: 'update_frame_image', arguments: {frame_id: 'missing', image_path: '/tmp/screen.png'}}}) + '\n');
  child.stdin.write(JSON.stringify({jsonrpc: '2.0', id: 7, method: 'tools/call', params: {name: 'get_agent_brief', arguments: {}}}) + '\n');
  try {
    for (let i = 0; i < 60 && replies.length < 7; i++) await new Promise(r => setTimeout(r, 50));
    const projects = JSON.parse(replies.find(r => r.id === 1).result.content[0].text);
    assert.equal(JSON.stringify(projects).includes('Package'), true);
    const detail = replies.find(r => r.id === 2).result;
    assert.equal(detail.content[1].type, 'image');
    assert.equal(detail.content[1].data, png.toString('base64'));
    const frames = JSON.parse(replies.find(r => r.id === 3).result.content[0].text).frames;
    assert.equal(frames[0].id, 'f1');
    assert.equal(frames[0].isImage, true);
    assert.equal(frames[0].imageHash, digest);
    assert.equal(frames[0].flow, 'appId: app.essazanov.Comin\n---\n- launchApp\n- tapOn: Забыли пароль?');
    assert.equal(frames[0].deeplink, 'comin://recovery?screen=reset');
    assert.equal(frames[0].simulatorCapture.stepCount, 1);
    assert.equal(frames[0].simulatorCapture.platform, 'android');
    assert.equal(frames[0].simulatorCapture.build.projectName, 'Android');
    assert.equal(frames[0].simulatorCapture.build.variant, 'Debug');
    assert.equal(JSON.stringify(frames[0].simulatorCapture).includes('/Private/'), false);
    assert.equal(frames[0].simulatorCapture.deeplink, 'comin://recovery');
    assert.deepEqual(frames[0].simulatorCapture.testState, {name:'Recovery', theme:'dark', dataKeys:['email'], preparationCount:1});
    for (const secret of ['private-account','private-email','private-argument','private-setup','private-ready']) {
      assert.equal(JSON.stringify(frames[0].simulatorCapture).includes(secret), false);
    }
    const current = replies.find(r => r.id === 4).result;
    assert.equal(current.content[1].data, png.toString('base64'));
    assert.equal(JSON.parse(current.content[0].text).frame.imageUpdatedBy, 'MCP agent');
    assert.equal(JSON.parse(current.content[0].text).frame.flow, frames[0].flow);
    assert.equal(JSON.parse(current.content[0].text).frame.deeplink, frames[0].deeplink);
    const brief = replies.find(r => r.id === 7).result.content[0].text;
    assert.match(brief, /capture_simulator_frame/);
    assert.match(brief, /keep the current frame image/);
    assert.ok(!JSON.stringify(replies).includes('private-token'));
    const updateTool = replies.find(r => r.id === 5).result.tools.find(tool => tool.name === 'update_frame_image');
    assert.deepEqual(updateTool.inputSchema.required, ['frame_id', 'image_path']);
    assert.equal(updateTool.annotations.readOnlyHint, false);
    const captureTool = replies.find(r => r.id === 5).result.tools.find(tool => tool.name === 'capture_simulator_frame');
    assert.deepEqual(captureTool.inputSchema.required, ['frame_id']);
    assert.equal(captureTool.inputSchema.additionalProperties, false);
    const batchTool = replies.find(r => r.id === 5).result.tools.find(tool => tool.name === 'capture_simulator_frames');
    assert.deepEqual(batchTool.inputSchema.required, ['frame_ids']);
    assert.equal(batchTool.inputSchema.properties.frame_ids.maxItems, 20);
    assert.equal(batchTool.inputSchema.properties.frame_ids.uniqueItems, true);
    assert.equal(batchTool.inputSchema.additionalProperties, false);
    assert.equal(replies.find(r => r.id === 6).result.isError, true);
  } finally {
    child.kill();
    rmSync(base, {recursive: true, force: true});
  }
});
