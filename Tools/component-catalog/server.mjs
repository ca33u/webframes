import {createServer} from 'vite';
import react from '@vitejs/plugin-react';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import net from 'node:net';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import crypto from 'node:crypto';
import {discover} from './discover.mjs';
import {projectPostCSS} from './project-postcss.mjs';
import {previewBoundaries} from './preview-boundaries.mjs';
import {validExamples} from './client/preview-data.mjs';
const runtime=path.dirname(fileURLToPath(import.meta.url));
const root=fs.realpathSync(process.argv[2]||process.cwd());
const requestedPort=Number(process.argv[3]||4319);
if(!Number.isInteger(requestedPort)||requestedPort<1024||requestedPort>65535)throw Error('Use a port from 1024 to 65535.');
// The app derives the port from the project path; another project or an
// unrelated service may already hold it, so try the next ten ports.
const isFree=candidate=>new Promise(resolve=>{const probe=net.createServer();probe.once('error',()=>resolve(false));probe.listen(candidate,'127.0.0.1',()=>probe.close(()=>resolve(true)));});
let port=0;
for(let candidate=requestedPort;candidate<Math.min(requestedPort+10,65536);candidate++){if(await isFree(candidate)){port=candidate;break;}}
if(!port)throw Error(`Ports ${requestedPort}–${requestedPort+9} are busy. Close other local servers and click Refresh.`);
// Machine-readable line for Web Frames; keep it first on stdout.
console.log(`WEBFRAMES_CATALOG_PORT=${port}`);
const projectId=crypto.createHash('sha256').update(root).digest('hex').slice(0,20);
const cache=path.join(os.tmpdir(),'webframes-catalog',projectId,String(port));fs.mkdirSync(cache,{recursive:true});
const wrapper=path.join(root,'.webframes/preview.tsx');
const configPath=path.join(root,'.webframes/catalog.json');
const automaticStyles=[
  'src/app/globals.css','app/globals.css','src/styles/globals.css','styles/globals.css',
  'src/index.css','src/main.css','index.css'
].map(file=>path.join(root,file)).find(file=>fs.existsSync(file));
function manifest(){
  const result=discover(root);let config={};
  if(fs.existsSync(configPath))try{config=JSON.parse(fs.readFileSync(configPath,'utf8'));}catch(e){result.warnings.push('Invalid .webframes/catalog.json: '+e.message);}
  return {protocol:'webframes-catalog-v1',projectId,root,name:path.basename(root),...result,components:result.components.map(c=>({...c,projectId})),wrapper:fs.existsSync(wrapper),examples:validExamples(config.examples)};
}
let current=manifest();
let postcss;
try { postcss = await projectPostCSS(root); }
catch (error) {
  postcss = {plugins: []};
  current.warnings.push('Project styles could not be loaded: ' + error.message + '. Fix the project PostCSS setup and restart previews.');
}
const setupWarnings = [...current.warnings];
const toURL=p=>'/@fs/'+p;
const projectRequire=createRequire(path.join(root,'package.json'));
const fallbackRequire=createRequire(import.meta.url);
const resolvePackage=name=>{try{return projectRequire.resolve(name+'/package.json')}catch{return fallbackRequire.resolve(name+'/package.json')}};
const reactRoot=path.dirname(resolvePackage('react')), domRoot=path.dirname(resolvePackage('react-dom'));
const server=await createServer({
  configFile:false,root:path.join(runtime,'client'),envDir:cache,cacheDir:path.join(cache,'vite'),
  plugins:[previewBoundaries(root),react({exclude:[/\/client\/catalog\.jsx$/, /\/client\/preview\.jsx$/]}),{
    name:'webframes-registry',
    resolveId(id){if(id.startsWith('virtual:webframes/'))return '\0'+id;},
    load(id){
      if(!id.startsWith('\0virtual:webframes/'))return;
      const component=current.components.find(c=>c.id===id.slice('\0virtual:webframes/'.length));
      if(!component)throw Error('Component is no longer available. Refresh the catalogue.');
      return `${!fs.existsSync(wrapper)&&automaticStyles?`import ${JSON.stringify(toURL(automaticStyles))};\n`:''}export const load=()=>import(${JSON.stringify(toURL(path.join(root,component.source)))}).then(m=>m[${JSON.stringify(component.exportName)}]);\nexport const wrapper=${fs.existsSync(wrapper)?`()=>import(${JSON.stringify(toURL(wrapper))}).then(m=>m.Wrapper||m.default)`:'async()=>null'};`;
    },
    configureServer(vite){
      vite.middlewares.use((req,res,next)=>{
        if(req.headers.host!==`127.0.0.1:${port}` || req.headers.origin && req.headers.origin!==`http://127.0.0.1:${port}`){res.statusCode=403;res.end('Local catalogue only');return;}
        const url=new URL(req.url,'http://127.0.0.1');
        if(url.pathname==='/catalog.json'){
          if(req.method!=='GET'){res.statusCode=405;res.end();return;}
          res.setHeader('Content-Type','application/json');res.setHeader('Cache-Control','no-store');res.end(JSON.stringify(current));return;
        }
        next();
      });
      let timer;
      vite.watcher.add(root);
      vite.watcher.on('all',(_event,file)=>{
        if(!file.startsWith(root+path.sep)||file.includes('/node_modules/')||file.includes('/.git/'))return;
        clearTimeout(timer);timer=setTimeout(()=>{
          try{current=manifest();current.warnings=[...new Set([...current.warnings,...setupWarnings])];for(const module of vite.moduleGraph.idToModuleMap.values())if(module.id?.startsWith('\0virtual:webframes/'))vite.moduleGraph.invalidateModule(module);vite.ws.send({type:'full-reload'});}catch(e){console.error(e.message);}
        },400);
      });
    }
  }],
  resolve:{alias:[{find:/^react-dom(?=\/|$)/,replacement:domRoot},{find:/^react(?=\/|$)/,replacement:reactRoot},{find:'@',replacement:path.join(root,fs.existsSync(path.join(root,'src'))?'src':'')},{find:'~',replacement:path.join(root,fs.existsSync(path.join(root,'src'))?'src':'')}],dedupe:['react','react-dom']},
  css:{postcss},
  server:{hmr:{overlay:false},host:'127.0.0.1',port,strictPort:true,allowedHosts:['127.0.0.1'],fs:{strict:true,allow:[root,runtime,reactRoot,domRoot]},watch:{ignored:['**/node_modules/**','**/.git/**','**/.next/**','**/dist/**']}},
});
await server.listen();
console.log(`Web Frames component catalog: http://127.0.0.1:${port}\nProject: ${root}\n${current.components.length} components. Source files remain unchanged.`);
for(const signal of ['SIGTERM','SIGINT'])process.on(signal,async()=>{await server.close();process.exit(0)});
