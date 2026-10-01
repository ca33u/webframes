import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
import {pathToFileURL} from 'node:url';

// Normalize project configuration before Vite starts, so a missing plugin can
// be reported without taking down the catalogue shell itself.
export async function projectPostCSS(root) {
  const names=['postcss.config.mjs','postcss.config.cjs','postcss.config.js','.postcssrc.mjs','.postcssrc.cjs','.postcssrc.js','postcss.config.json','.postcssrc.json','.postcssrc'];
  const file=names.map(name=>path.join(root,name)).find(file=>fs.existsSync(file));
  let value;
  if(file) {
    if(/\.[cm]?js$/.test(file)) {
      const exported=await import(pathToFileURL(file).href); value=exported.default??exported;
    } else value=JSON.parse(fs.readFileSync(file,'utf8'));
  } else {
    const pkg=path.join(root,'package.json');
    value=fs.existsSync(pkg)?JSON.parse(fs.readFileSync(pkg,'utf8')).postcss:undefined;
    if(!value) {
      if(['postcss.config.ts','.postcssrc.yaml','.postcssrc.yml'].some(name=>fs.existsSync(path.join(root,name)))) throw Error('Use a JS or JSON PostCSS config for component previews.');
      return {plugins:[]};
    }
  }
  const config=typeof value==='function'?await value({cwd:root,env:process.env.NODE_ENV||'development'}):value;
  if(!config || typeof config!=='object')throw Error('Invalid project PostCSS configuration.');
  const require=createRequire(file||path.join(root,'package.json'));
  const load=async name=>{const module=await import(pathToFileURL(require.resolve(name)).href);return module.default??module;};
  const entries=Array.isArray(config.plugins)?config.plugins:Object.entries(config.plugins||{});
  const plugins=[];
  for(const entry of entries){
    if(!entry)continue;
    if(typeof entry!=='string'&&!Array.isArray(entry)){plugins.push(entry);continue;}
    const [name,options]=typeof entry==='string'?[entry,undefined]:entry;
    if(options===false)continue;
    if(typeof name!=='string')throw Error('Invalid project PostCSS plugin.');
    const plugin=await load(name);
    plugins.push(typeof plugin==='function'?plugin(options===true?undefined:options):plugin);
  }
  const result={...config,plugins};
  for(const key of ['parser','syntax','stringifier'])if(typeof result[key]==='string')result[key]=await load(result[key]);
  return result;
}
