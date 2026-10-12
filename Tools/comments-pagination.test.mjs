import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';

test('large MCP lists page completely, bind cursors to saved data and bound brief output', async () => {
  const root = mkdtempSync(path.join(tmpdir(), 'wf-mcp-pages-'));
  const frames = Array.from({length: 350}, (_, i) => ({id: `f${i}`, label: `Screen ${i}`, x: i * 400, y: 0, w: 100, h: 100}));
  const sections = Array.from({length: 260}, (_, i) => ({id: `s${i}`, name: `Pool ${i}`, task: 'Unify with the chosen reference', referenceFrameId: `f${i}`, x: i * 400, y: 0, w: 200, h: 200}));
  sections.push({id: 'big-pool', name: 'All variants', x: -100, y: -100, w: 200000, h: 1000});
  const annotations = Array.from({length: 950}, (_, i) => ({id: `a${i}`, num: i, frameId: `f${i % 350}`, resolved: i % 3 === 0, comment: `Change ${i}: ` + 'layout '.repeat(100)}));
  const file = path.join(root, 'large.webframes');
  writeFileSync(file, JSON.stringify({name: 'Large QA', frames, sections, annotations}));
  for (let i = 0; i < 260; i++) writeFileSync(path.join(root, `empty-${i}.webframes`), JSON.stringify({name: `Empty ${i}`}));
  const child = spawn(process.execPath, [new URL('./comments-mcp.mjs', import.meta.url).pathname], {
    env: {...process.env, WEBFRAMES_PROJECTS_DIR: root}, stdio: ['pipe', 'pipe', 'pipe'],
  });
  let buffer = '', id = 0;
  const pending = new Map();
  child.stdout.on('data', chunk => {
    buffer += chunk;
    while (buffer.includes('\n')) {
      const end = buffer.indexOf('\n'), line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      const value = JSON.parse(line); pending.get(value.id)?.(value); pending.delete(value.id);
    }
  });
  function call(name, args = {}) {
    return new Promise((resolve, reject) => {
      const key = ++id, timer = setTimeout(() => reject(new Error(`Timeout ${name}`)), 10000);
      pending.set(key, reply => { clearTimeout(timer); resolve(reply.result); });
      child.stdin.write(JSON.stringify({jsonrpc: '2.0', id: key, method: 'tools/call', params: {name, arguments: args}}) + '\n');
    });
  }
  const payload = result => { assert.ok(!result.isError, result.content[0].text); return JSON.parse(result.content[0].text); };
  async function walk(name, key, args, expected) {
    let cursor, ids = [], pages = 0;
    do {
      const result = await call(name, {...args, limit: 37, ...(cursor ? {cursor} : {})});
      assert.ok(Buffer.byteLength(result.content[0].text) < 110000);
      const data = payload(result);
      assert.equal(data.pagination.total, expected);
      assert.ok(data.pagination.returned <= 37);
      ids.push(...data[key].map(x => x.id)); cursor = data.pagination.nextCursor;
      assert.ok(++pages < 100);
    } while (cursor);
    assert.equal(ids.length, expected); assert.equal(new Set(ids).size, expected);
  }
  try {
    await walk('list_projects', 'projects', {}, 261);
    await walk('list_frames', 'frames', {project: 'large'}, 350);
    await walk('list_sections', 'sections', {project: 'large'}, 261);
    await walk('list_comments', 'comments', {project: 'large', status: 'all'}, 950);
    await walk('list_comments', 'comments', {project: 'large', status: 'open'}, annotations.filter(a => !a.resolved).length);
    await walk('list_comments', 'comments', {project: 'large', status: 'resolved'}, annotations.filter(a => a.resolved).length);
    const first = payload(await call('list_frames', {project: 'large'}));
    assert.equal(first.frames.length, 100);
    const cursor = first.pagination.nextCursor;
    assert.equal((await call('list_sections', {project: 'large', cursor})).isError, true);
    for (const limit of [0, 201, -1, 1.5, '20']) assert.equal((await call('list_frames', {project: 'large', limit})).isError, true);
    assert.equal((await call('list_frames', {project: 'large', cursor: 'garbage'})).isError, true);
    const brief = await call('get_agent_brief', {project: 'large', limit: 17});
    assert.ok(Buffer.byteLength(brief.content[0].text) < 220000);
    const commentPage = JSON.parse(brief.content[0].text.match(/Comment pagination: (.*)/)[1]);
    const sectionPage = JSON.parse(brief.content[0].text.match(/Section pagination \(continue with section_cursor\): (.*)/)[1]);
    const secondBrief = await call('get_agent_brief', {project: 'large', limit: 17, cursor: commentPage.nextCursor, section_cursor: sectionPage.nextCursor});
    assert.ok(!secondBrief.isError);
    assert.ok(!secondBrief.content[0].text.includes('#1 [a1]'));
    assert.ok(secondBrief.content[0].text.includes('Section pool: Pool 17'));
    const section = payload(await call('get_section', {project: 'large', id: 'big-pool', limit: 17}));
    assert.equal(section.section.frameIds.length, 17);
    assert.equal(section.pagination.total, 90); // the other 260 belong to smaller sections
    const modified = JSON.parse(readFileSync(file, 'utf8'));
    modified.frames[0].label = 'Edited'; modified.annotations[1].comment = 'x'.repeat(150000);
    writeFileSync(file, JSON.stringify(modified));
    const stale = await call('list_frames', {project: 'large', cursor});
    assert.equal(stale.isError, true); assert.match(stale.content[0].text, /stale cursor/);
    const large = payload(await call('list_comments', {project: 'large', limit: 1}));
    assert.equal(large.comments[0].id, 'a1'); assert.equal(large.comments[0].detailsOmitted, true);
    const detail = payload(await call('get_comment', {project: 'large', id: 'a1'}));
    assert.equal(detail.comment.comment.length, 150000);
    mkdirSync(path.join(root, 'package.webframes'));
    writeFileSync(path.join(root, 'package.webframes', 'document.json'), JSON.stringify({name: 'Package', frames: []}));
    assert.equal(payload(await call('list_frames', {project: 'package'})).pagination.nextCursor, null);
  } finally { child.kill(); rmSync(root, {recursive: true, force: true}); }
});
