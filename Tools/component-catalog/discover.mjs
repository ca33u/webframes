import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import ts from 'typescript';
const skipped = new Set(['node_modules','dist','build','coverage','.git','.next','out']);
export function discover(root) {
  const files=[]; let bytes=0; const warnings=[];
  function walk(dir) {
    for(const ent of fs.readdirSync(dir,{withFileTypes:true})) {
      if(files.length>=1500 || bytes>12e6) { if(!warnings.length) warnings.push('Discovery limit reached (1,500 files / 12 MB).'); return; }
      if(ent.isSymbolicLink() || ent.name.startsWith('.') || skipped.has(ent.name)) continue;
      const abs=path.join(dir,ent.name);
      if(ent.isDirectory()) walk(abs);
      else if(/\.[jt]sx?$/.test(ent.name) && !/\.(test|spec|stories|d)\.[jt]sx?$/.test(ent.name)) {
        const size=fs.statSync(abs).size;if(size>300000)continue;bytes+=size; files.push(abs);
      }
    }
  }
  walk(root);
  const components=[]; const sourceTexts=new Map();
  for(const abs of files) {
    const source=path.relative(root,abs).replaceAll(path.sep,'/');
    // Screens already live in the Flow view. Keep Next route entry points
    // out of the component library so server pages do not become broken tiles.
    if(/(?:^|\/)(?:src\/)?app\/(?:.*\/)?(?:page|layout|route|error|not-found|loading|template|default|opengraph-image)\.[jt]sx?$/.test(source))continue;
    const text=fs.readFileSync(abs,'utf8'); sourceTexts.set(abs,text); const ast=ts.createSourceFile(abs,text,ts.ScriptTarget.Latest,true);
    const types=new Map(); const locals=new Map(); const exports=new Map();
    const mods=(n,k)=>n.modifiers?.some(m=>m.kind===k);
    function collect(n) {
      if(ts.isInterfaceDeclaration(n)||ts.isTypeAliasDeclaration(n)) types.set(n.name.text,n);
      if(ts.isFunctionDeclaration(n) && n.name) locals.set(n.name.text,n);
      if(ts.isVariableStatement(n)) for(const d of n.declarationList.declarations) if(ts.isIdentifier(d.name)) locals.set(d.name.text,d.initializer);
    }
    ast.statements.forEach(collect);
    for(const n of ast.statements) {
      if(mods(n,ts.SyntaxKind.ExportKeyword)) {
        if(ts.isFunctionDeclaration(n)||ts.isClassDeclaration(n)) {
          const name=n.name?.text || path.basename(abs).replace(/\.[^.]+$/,'');
          exports.set(mods(n,ts.SyntaxKind.DefaultKeyword)?'default':name,{name,node:n});
        }
        if(ts.isVariableStatement(n)) for(const d of n.declarationList.declarations) if(ts.isIdentifier(d.name)) exports.set(d.name.text,{name:d.name.text,node:d.initializer,annotation:d.type});
      }
      if(ts.isExportAssignment(n) && !n.isExportEquals) {
        const name=ts.isIdentifier(n.expression)?n.expression.text:path.basename(abs).replace(/\.[^.]+$/,'');
        exports.set('default',{name,node:locals.get(name)||n.expression});
      }
      if(ts.isExportDeclaration(n) && !n.moduleSpecifier && n.exportClause && ts.isNamedExports(n.exportClause)) for(const e of n.exportClause.elements) {
        const local=e.propertyName?.text||e.name.text;exports.set(e.name.text,{name:e.name.text,node:locals.get(local)});
      }
    }
    function hasJSX(n) { if(!n)return false; if(ts.isJsxElement(n)||ts.isJsxSelfClosingElement(n)||ts.isJsxFragment(n))return true;return Boolean(ts.forEachChild(n,hasJSX)); }
    function members(type,seen=new Set()) {
      if(!type)return[];
      if(ts.isTypeLiteralNode(type))return [...type.members];
      if(ts.isIntersectionTypeNode(type))return type.types.flatMap(t=>members(t,seen));
      if(ts.isTypeReferenceNode(type)) {
        const key=type.typeName.getText(ast);if(seen.has(key))return[];seen.add(key);
        const d=types.get(key);if(!d)return[];
        if(ts.isInterfaceDeclaration(d))return [...d.members,...(d.heritageClauses||[]).flatMap(h=>h.types.flatMap(t=>members(t,seen)))];
        return members(d.type,seen);
      }
      return[];
    }
    function literal(n) {
      if(!n)return undefined;
      if(ts.isStringLiteral(n))return n.text;if(ts.isNumericLiteral(n))return Number(n.text);
      if(n.kind===ts.SyntaxKind.TrueKeyword)return true;if(n.kind===ts.SyntaxKind.FalseKeyword)return false;
      if(n.kind===ts.SyntaxKind.NullKeyword)return null;
      return undefined;
    }
    for(const [exportName,item] of exports) {
      if(!/^[A-Z]/.test(item.name)||!hasJSX(item.node))continue;
      let fn=item.node;
      while(fn && ts.isCallExpression(fn)) fn=fn.arguments[0];
      const parameter=fn?.parameters?.[0];
      const annotation=parameter?.type || item.annotation?.typeArguments?.[0];
      const defaults={};
      if(parameter && ts.isObjectBindingPattern(parameter.name)) for(const e of parameter.name.elements) {
        const value=literal(e.initializer);if(value!==undefined)defaults[e.propertyName?.getText(ast)||e.name.getText(ast)]=value;
      }
      const props=members(annotation).filter(ts.isPropertySignature).map(p=>{
        const name=p.name.getText(ast).replace(/^['"]|['"]$/g,'');const t=p.type;const label=t?.getText(ast)||'unknown';
        const options=t && ts.isUnionTypeNode(t)?t.types.map(x=>ts.isLiteralTypeNode(x)?literal(x.literal):undefined).filter(x=>x!==undefined):[];
        const kind=options.length?'select':label==='boolean'?'boolean':label==='number'?'number':label==='string'?'string':/^on[A-Z]/.test(name)||t&&ts.isFunctionTypeNode(t)?'action':name==='children'?'string':'json';
        return {name,kind,type:label,required:!p.questionToken && !(name in defaults),options,default:defaults[name]};
      });
      // Untyped JS still exposes destructured props without pretending to know their type.
      if(!props.length && parameter && ts.isObjectBindingPattern(parameter.name)) for(const e of parameter.name.elements) {
        const name=e.propertyName?.getText(ast)||e.name.getText(ast);props.push({name,kind:/^on[A-Z]/.test(name)?'action':'json',type:'unknown',required:false,default:defaults[name]});
      }
      const id=crypto.createHash('sha256').update(source+'#'+exportName).digest('hex').slice(0,16);
      components.push({id,name:item.name,exportName,source,line:ast.getLineAndCharacterOfPosition(item.node.getStart(ast)).line+1,group:path.dirname(source),props,defaults,pages:[]});
    }
  }
  // Source references are disclosed as file-level references, not claimed as observed render instances.
  for(const c of components) {
    const base=path.basename(c.source).replace(/\.[^.]+$/,'');
    c.pages=files.filter(f=>path.relative(root,f)!==c.source && new RegExp(`(?:from\\s*|import\\s*)['"][^'"]*/?${base}['"]`).test(sourceTexts.get(f)||'')).map(f=>path.relative(root,f)).slice(0,40);
  }
  return {components:components.sort((a,b)=>a.name.localeCompare(b.name)),warnings};
}
