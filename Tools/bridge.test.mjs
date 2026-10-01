import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,rm,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {createBridge,validateJob,codexArgs,claudeArgs,modelUnavailable} from './codex-bridge.mjs';

const png='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=';
const file={path:'styles.css',content:'.card { width: 420px; }'};file.hash=createHash('sha256').update(file.content).digest('hex');
const body=()=>({kind:'analyze',images:[png,png],dom:'{}',files:[file]});
const commentsBody=()=>({kind:'fix-comments',images:[png],files:[file],comments:[{
  id:'comment-1',comment:'Make this card fluid',frameLabel:'Dashboard',url:'http://localhost:3000',
  viewport:'1280×800',selector:'.card',screenshotIndex:0,
}]});

test('snapshot validation rejects traversal, hidden files and stale content',()=>{
  assert.equal(validateJob(body()).kind,'analyze');
  for(const p of ['../secret.css','/etc/foo.css','.env','x/.git/y.css','x\\y.css']) assert.throws(()=>validateJob({...body(),files:[{...file,path:p}]}));
  assert.throws(()=>validateJob({...body(),files:[{...file,hash:'wrong'}]}));
  assert.throws(()=>validateJob({...body(),images:['data:image/png;base64,YQ==',png]}));
});
test('comment-fix jobs are bounded and validate screenshot references',()=>{
  assert.equal(validateJob(commentsBody()).kind,'fix-comments');
  assert.throws(()=>validateJob({...commentsBody(),comments:[]}));
  assert.throws(()=>validateJob({...commentsBody(),comments:[{...commentsBody().comments[0],screenshotIndex:2}]}));
  assert.throws(()=>validateJob({...commentsBody(),comments:[{...commentsBody().comments[0],comment:'x'.repeat(8001)}]}));
});
test('Codex flags restrict execution and preserve saved auth',()=>{
  const args=codexArgs('/tmp/test','analyze');
  assert.ok(args.includes('--ignore-user-config'));assert.ok(args.includes('read-only'));
  assert.ok(args.includes('shell_tool'));assert.ok(args.includes('unified_exec'));assert.ok(args.includes('multi_agent'));
  assert.ok(args.includes('gpt-6-astra'));assert.ok(!args.includes('--dangerously-bypass-approvals-and-sandbox'));
  assert.ok(!codexArgs('/tmp/test','verify').some(a=>a.includes('mcp_servers')));
  const fixArgs=codexArgs('/tmp/test','fix-comments',1);
  assert.ok(fixArgs.some(a=>a.includes('mcp_servers.webframes_context')));
  assert.equal(fixArgs.filter(a=>a==='--image').length,1);
});
test('local connector requires pairing and rejects browser origins',async()=>{
  const root=await mkdtemp(path.join(tmpdir(),'wf-bridge-'));
  const bridge=await createBridge({root});
  try {
    assert.equal((await fetch(bridge.connection.url+'/health')).status,401);
    const headers={Authorization:'Bearer '+bridge.connection.token};
    const health=await fetch(bridge.connection.url+'/health',{headers});assert.equal(health.status,200);
    assert.ok((await health.json()).features.includes('fix-comments'));
    assert.equal((await fetch(bridge.connection.url+'/health',{headers:{...headers,Origin:'https://example.com'}})).status,403);
    assert.equal((await fetch(bridge.connection.url+'/jobs',{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({kind:'shell',command:'touch /tmp/oops'})})).status,400);
    const connection=JSON.parse(await readFile(bridge.connectionPath,'utf8'));assert.equal(connection.version,1);
  } finally {bridge.close();await rm(root,{recursive:true,force:true});}
});
test('MCP can read only the supplied snapshot and journals actual reads',async()=>{
  const root=await mkdtemp(path.join(tmpdir(),'wf-mcp-'));
  const context=path.join(root,'context.json'),journal=path.join(root,'reads.jsonl');
  await writeFile(context,JSON.stringify({files:[file]}));
  try {
    const result=await new Promise((resolve,reject)=>{
      const child=spawn(process.execPath,[new URL('./context-mcp.mjs',import.meta.url).pathname,context,journal]);
      let out='';child.stdout.on('data',c=>out+=c);child.on('error',reject);child.on('close',code=>code===0?resolve(out.trim().split('\n').map(JSON.parse)):reject(Error('MCP failed')));
      const requests=[{jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'read_code',arguments:{path:'styles.css'}}},{jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'read_code',arguments:{path:'/etc/passwd'}}}];
      child.stdin.end(requests.map(JSON.stringify).join('\n')+'\n');
    });
    assert.equal(JSON.parse(result[0].result.content[0].text).hash,file.hash);
    assert.equal(result[1].result.isError,true);
    assert.equal(JSON.parse((await readFile(journal,'utf8')).trim()).path,'styles.css');
  } finally {await rm(root,{recursive:true,force:true});}
});

test('concurrent submissions reserve a single Codex run',async()=>{
  const {EventEmitter}=await import('node:events');
  const {PassThrough}=await import('node:stream');
  const root=await mkdtemp(path.join(tmpdir(),'wf-concurrent-'));
  let started=0;
  const bridge=await createBridge({root,spawnProcess:()=>{
    started++;
    const child=new EventEmitter();child.stdin=new PassThrough();child.stdout=new PassThrough();child.stderr=new PassThrough();
    child.kill=()=>{child.emit('close',1);return true;};return child;
  }});
  try {
    const request=()=>fetch(bridge.connection.url+'/jobs',{method:'POST',headers:{Authorization:'Bearer '+bridge.connection.token,'Content-Type':'application/json'},body:JSON.stringify(body())});
    const responses=await Promise.all([request(),request()]);
    assert.deepEqual(responses.map(r=>r.status).sort(),[202,400]);assert.equal(started,1);
    const accepted=await responses.find(r=>r.status===202).json();
    await fetch(bridge.connection.url+'/jobs/'+accepted.id,{method:'DELETE',headers:{Authorization:'Bearer '+bridge.connection.token}});
  } finally {bridge.close();await rm(root,{recursive:true,force:true});}
});


test('screenshot fixes preserve visual context and accept bounded project source',()=>{
  const request=commentsBody();
  Object.assign(request.comments[0],{projectName:'Pala',url:'image://screen',frameLabel:'Settings',xPct:0.25,yPct:0.75});
  const content='x'.repeat(100000);
  const files=Array.from({length:13},(_,i)=>({path:`screen${i}.tsx`,content,hash:createHash('sha256').update(content).digest('hex')}));
  assert.equal(validateJob({...request,files}).comments[0].xPct,0.25);
  assert.throws(()=>validateJob({...body(),files}),/512 KB/);
  assert.throws(()=>validateJob({...request,files:[...files,...files.slice(0,8).map((f,i)=>({...f,path:`extra${i}.tsx`}))]}),/2000 KB/);
});

test('Claude Code provider: locked-down arguments, images via Read, structured result',async()=>{
  const {EventEmitter}=await import('node:events');
  const {PassThrough}=await import('node:stream');
  const root=await mkdtemp(path.join(tmpdir(),'wf-claude-'));
  let seen=null,prompt='';
  const bridge=await createBridge({root,provider:'claude',model:'claude-sonnet-5',codex:'/fake/claude',spawnProcess:(binary,args,options)=>{
    seen={binary,args,options};
    const child=new EventEmitter();child.stdin=new PassThrough();child.stdout=new PassThrough();child.stderr=new PassThrough();
    child.stdin.on('data',chunk=>{prompt+=chunk;});
    child.stdin.on('finish',()=>{
      child.stdout.write(JSON.stringify({type:'result',is_error:false,structured_output:{summary:'ok',checks:[{id:'f1',status:'verified',evidence:'Heading is 36px'}]}})+'\n');
      setTimeout(()=>child.emit('close',0),10);
    });
    child.kill=()=>true;return child;
  }});
  try {
    const auth={Authorization:'Bearer '+bridge.connection.token};
    const health=await (await fetch(bridge.connection.url+'/health',{headers:auth})).json();
    assert.equal(health.name,'Claude');assert.equal(health.model,'claude-sonnet-5');
    const job=await (await fetch(bridge.connection.url+'/jobs',{method:'POST',headers:{...auth,'Content-Type':'application/json'},
      body:JSON.stringify({kind:'verify',images:[png,png,png],dom:'{}',findings:[{id:'f1',selector:'h1',mismatch:'small',expected:'36px'}]})})).json();
    let status;
    for(let i=0;i<50;i++){status=await (await fetch(bridge.connection.url+'/jobs/'+job.id,{headers:auth})).json();if(status.status!=='running')break;await new Promise(r=>setTimeout(r,20));}
    assert.equal(status.status,'completed',status.error);
    assert.equal(status.result.checks[0].status,'verified');
    assert.equal(seen.binary,'/fake/claude');
    for(const flag of ['-p','--json-schema','--strict-mcp-config','--no-session-persistence']) assert.ok(seen.args.includes(flag),flag);
    assert.deepEqual(seen.args.slice(seen.args.indexOf('--model'),seen.args.indexOf('--model')+2),['--model','claude-sonnet-5']);
    assert.ok(seen.args.includes('Bash')&&seen.args.includes('WebFetch'),'shell and web are disallowed');
    assert.match(prompt,/\.\/image-0\.png, \.\/image-1\.png, \.\/image-2\.png/);
    assert.equal(seen.options.env.ANTHROPIC_API_KEY,undefined);
  } finally {bridge.close();await rm(root,{recursive:true,force:true});}
});

test('provider arguments and model errors',()=>{
  assert.ok(codexArgs('/run','analyze',0,'gpt-x').includes('gpt-x'));
  const args=claudeArgs('/run','fix-comments',1,null,{});
  assert.ok(!args.includes('--model'),'Claude uses its default model when none is set');
  assert.ok(args.includes('mcp__webframes_context__read_code'));
  assert.ok(modelUnavailable('Error: model "gpt-6-astra" is not available for your account'));
  assert.ok(!modelUnavailable('Rate limit reached'));
});
