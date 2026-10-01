import {readFileSync, appendFileSync} from 'node:fs';
import {createInterface} from 'node:readline';

// This server sees only a bounded source snapshot. It cannot open arbitrary paths.
const context = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const journal = process.argv[3];
const tools = [
  {name:'search_code',description:'Search the selected source snapshot for a literal class, selector or text.',inputSchema:{type:'object',properties:{query:{type:'string',minLength:1,maxLength:120}},required:['query'],additionalProperties:false},annotations:{readOnlyHint:true}},
  {name:'read_code',description:'Read a selected source file and its SHA256. Use this before proposing a CSS patch.',inputSchema:{type:'object',properties:{path:{type:'string'}},required:['path'],additionalProperties:false},annotations:{readOnlyHint:true}},
];
function call(name,args) {
  if(name==='search_code') {
    if(typeof args.query!=='string'||!args.query||args.query.length>120) throw Error('Invalid query');
    const matches=[];
    for(const file of context.files) for(const [index,line] of file.content.split('\n').entries()) {
      if(line.toLowerCase().includes(args.query.toLowerCase())) matches.push({path:file.path,line:index+1,text:line.slice(0,350)});
      if(matches.length===20) return {matches};
    }
    return {matches};
  }
  if(name==='read_code') {
    const file=context.files.find(f=>f.path===args.path);
    if(!file) throw Error('File is outside the selected source snapshot');
    appendFileSync(journal,JSON.stringify({path:file.path,hash:file.hash})+'\n',{mode:0o600});
    return file;
  }
  throw Error('Unknown tool');
}
const lines=createInterface({input:process.stdin,crlfDelay:Infinity});
lines.on('line',line=>{
  let request;
  try {
    request=JSON.parse(line); if(request.id===undefined) return;
    let result;
    switch(request.method) {
      case 'initialize': result={protocolVersion:request.params?.protocolVersion||'2024-11-05',capabilities:{tools:{}},serverInfo:{name:'webframes-context',version:'0.1.0'}};break;
      case 'ping': result={};break;
      case 'tools/list': result={tools};break;
      case 'tools/call':
        try { result={content:[{type:'text',text:JSON.stringify(call(request.params.name,request.params.arguments||{}))}]}; }
        catch(e) { result={isError:true,content:[{type:'text',text:e.message}]}; } break;
      default: throw Error('Unsupported method');
    }
    process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,result})+'\n');
  } catch(e) { if(request?.id!==undefined) process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,error:{code:-32602,message:e.message}})+'\n'); }
});
