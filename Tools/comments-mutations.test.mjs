import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, readdir, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {inboxFor,setCommentStatus} from './comments-mutations.mjs';

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
