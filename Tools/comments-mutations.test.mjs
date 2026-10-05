import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, readdir, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {inboxFor,setCommentStatus,updateFrameImage,storedImage,MAX_IMAGE_BYTES} from './comments-mutations.mjs';
import {createHash} from 'node:crypto';

test('MCP sends a bounded request to the app without overwriting the project',async()=>{
 const root=await mkdtemp(path.join(os.tmpdir(),'wf-mutations-'));
 try {
  const file=path.join(root,'test.webframes');await writeFile(file,'original');
  const project={file,annotations:[{id:'a',comment:'Fix it',resolved:false}]};
  const base=path.join(root,'requests'), inbox=inboxFor(file,base);await mkdir(inbox,{recursive:true});
  const response=setCommentStatus(project,{ids:['a'],resolved:true},{base,timeout:1000});
  let name;
  for(let i=0;i<20&&!name;i++){name=(await readdir(inbox)).find(n=>n.endsWith('.request.json'));if(!name)await delay(20);}
  assert.ok(name);
  const request=JSON.parse(await readFile(path.join(inbox,name),'utf8'));
  assert.deepEqual(request.comments,[{id:'a',comment:'Fix it',resolved:false}]);
  await writeFile(path.join(inbox,request.id+'.response.json'),JSON.stringify({ok:true,ids:['a'],resolved:true}));
  assert.equal((await response).ok,true);
  assert.equal(await readFile(file,'utf8'),'original');
  assert.deepEqual(await readdir(inbox),[]);
  await assert.rejects(setCommentStatus(project,{ids:['missing'],resolved:true},{base}),/Unknown/);
  await assert.rejects(setCommentStatus(project,{ids:['a','a'],resolved:true},{base}),/unique/);
  await assert.rejects(setCommentStatus(project,{ids:['a'],resolved:'true'},{base}),/boolean/);
  await assert.rejects(setCommentStatus(project,{ids:['a'],resolved:true},{base,timeout:100}),/did not confirm/);
  assert.deepEqual(await readdir(inbox),[]);
 } finally {await rm(root,{recursive:true,force:true});}
});

test('image updates send captured bytes and an expected hash, preserve the document, and clean up replies', async () => {
 const root = await mkdtemp(path.join(os.tmpdir(), 'wf-images-'));
 try {
  const file = path.join(root, 'test.webframes'); await writeFile(file, 'original document');
  const previous = Buffer.from('original image');
  const hash = createHash('sha256').update(previous).digest('hex');
  const packageRoot = path.join(root, 'package'); await mkdir(path.join(packageRoot, 'images'), {recursive: true});
  await writeFile(path.join(packageRoot, 'images', hash + '.jpg'), previous);
  const frame = {id: 'f', isImage: true, imgUrl: `wf-image:images/${hash}.jpg`};
  const project = {file, packageRoot, byFrame: new Map([['f', frame]])};
  const image = Buffer.from([137,80,78,71,13,10,26,10,1,2,3]);
  const imagePath = path.join(root, 'screen.png'); await writeFile(imagePath, image);
  const base = path.join(root, 'requests'), inbox = inboxFor(file, base); await mkdir(inbox, {recursive: true});
  const response = updateFrameImage(project, {frame_id: 'f', image_path: imagePath}, {base, timeout: 2000});
  let name;
  for (let i = 0; i < 50 && !name; i++) { name = (await readdir(inbox)).find(n => n.endsWith('.request.json')); if (!name) await delay(20); }
  assert.ok(name);
  const request = JSON.parse(await readFile(path.join(inbox, name), 'utf8'));
  assert.deepEqual(request.comments, []);
  assert.equal(request.frameImage.frameID, 'f');
  assert.equal(request.frameImage.beforeHash, hash);
  assert.equal(request.frameImage.dataURL, `data:image/png;base64,${image.toString('base64')}`);
  // The screenshot has been copied into the request; temporary emulator outputs can disappear.
  await rm(imagePath);
  await writeFile(path.join(inbox, request.id + '.response.json'), JSON.stringify({ok: true, frame_id: 'f'}));
  assert.equal((await response).ok, true);
  assert.equal(await readFile(file, 'utf8'), 'original document');
  assert.deepEqual(await readdir(inbox), []);
  assert.equal(storedImage(frame.imgUrl, packageRoot).hash, hash);
  assert.equal(storedImage(`data:image/jpeg;base64,${previous.toString('base64')}`).hash, hash);
  assert.equal(storedImage('wf-image:images/' + '0'.repeat(64) + '.png', packageRoot), null);
 } finally { await rm(root, {recursive: true, force: true}); }
});

test('image updates reject invalid frames, paths, sizes and content; app failures and timeouts are surfaced', async () => {
 const root = await mkdtemp(path.join(os.tmpdir(), 'wf-invalid-images-'));
 try {
  const file = path.join(root, 'test.webframes'); await writeFile(file, 'original');
  const imagePath = path.join(root, 'screen.jpg');
  const project = {file, byFrame: new Map([['f', {id: 'f', isImage: true, imgUrl: 'data:image/png;base64,b2xk'}], ['live', {id: 'live'}]])};
  const base = path.join(root, 'requests'), inbox = inboxFor(file, base); await mkdir(inbox, {recursive: true});
  const args = {frame_id: 'f', image_path: imagePath};
  await assert.rejects(updateFrameImage(project, {...args, frame_id: 'missing'}, {base}), /image frame/);
  await assert.rejects(updateFrameImage(project, {...args, frame_id: 'live'}, {base}), /image frame/);
  await assert.rejects(updateFrameImage(project, {...args, image_path: 'relative.png'}, {base}), /absolute/);
  await assert.rejects(updateFrameImage(project, {...args, image_path: root}, {base}), /regular/);
  await writeFile(imagePath, 'not image bytes');
  await assert.rejects(updateFrameImage(project, args, {base}), /PNG or JPEG/);
  await writeFile(imagePath, Buffer.alloc(MAX_IMAGE_BYTES + 1));
  await assert.rejects(updateFrameImage(project, args, {base}), /8 MiB/);
  await writeFile(imagePath, Buffer.from([255,216,255,1,2]));
  const response = updateFrameImage(project, args, {base, timeout: 2000});
  let name;
  for (let i = 0; i < 50 && !name; i++) { name = (await readdir(inbox)).find(n => n.endsWith('.request.json')); if (!name) await delay(20); }
  assert.ok(name);
  const request = JSON.parse(await readFile(path.join(inbox, name), 'utf8'));
  assert.match(request.frameImage.dataURL, /^data:image\/jpeg;base64,/);
  await writeFile(path.join(inbox, request.id + '.response.json'), JSON.stringify({error: 'Frame image changes are disabled'}));
  await assert.rejects(response, /disabled/);
  await assert.rejects(updateFrameImage(project, args, {base, timeout: 100}), /did not confirm/);
  assert.deepEqual(await readdir(inbox), []);
  await rm(inbox, {recursive: true});
  await assert.rejects(updateFrameImage(project, args, {base}), /Allow agents to update frame images/);
  assert.equal(await readFile(file, 'utf8'), 'original');
 } finally { await rm(root, {recursive: true, force: true}); }
});
