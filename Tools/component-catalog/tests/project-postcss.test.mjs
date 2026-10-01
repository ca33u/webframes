import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import postcss from 'postcss';
import {projectPostCSS} from '../project-postcss.mjs';

async function fixture(config,check){
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'wf-postcss-'));
  try{
    await fs.writeFile(path.join(root,'postcss.config.mjs'),config);
    await fs.writeFile(path.join(root,'plugin.cjs'),`module.exports=(options={})=>({postcssPlugin:'fixture',Declaration(d){if(d.prop==='color')d.value=options.color||'green'}});`);
    await check(root);
  }finally{await fs.rm(root,{recursive:true,force:true});}
}
test('Next string plugin arrays load from the project and process CSS',async()=>{
  await fixture(`export default {plugins:['./plugin.cjs']}`,async root=>{
    const config=await projectPostCSS(root);
    const result=await postcss(config.plugins).process('a { color: red }',{from:undefined});
    assert.match(result.css,/color: green/);
  });
});
test('Next tuples preserve options, disabled plugins and config context',async()=>{
  await fixture(`export default ctx=>({map:false,plugins:[['missing-plugin',false],['./plugin.cjs',{color:ctx.cwd?'blue':'bad'}]]})`,async root=>{
    const config=await projectPostCSS(root);
    assert.equal(config.map,false);assert.equal(config.plugins.length,1);
    assert.match((await postcss(config.plugins).process('a{color:red}',{from:undefined})).css,/color:blue/);
  });
});
test('Standard plugin maps are validated and normalized before starting Vite',async()=>{
  await fixture(`export default {plugins:{'./plugin.cjs':{color:'blue'}}}`,async root=>{
    const config=await projectPostCSS(root);
    assert.match((await postcss(config.plugins).process('a{color:red}',{from:undefined})).css,/color:blue/);
  });
});

test('missing object-map plugins fail early instead of crashing every CSS request',async()=>{
 await fixture(`export default {plugins:{'webframes-nonexistent-plugin':{}}}`,async root=>{
  await assert.rejects(projectPostCSS(root),/Cannot find/);
 });
});
