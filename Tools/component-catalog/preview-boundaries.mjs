import path from 'node:path';
import ts from 'typescript';
import {fileURLToPath} from 'node:url';

export function serverBoundary(code,id,root){
  const file=id.split('?')[0];
  if(!file.startsWith(root+path.sep)||file.includes('/node_modules/')||!/\.[cm]?[jt]sx?$/.test(file))return null;
  const ast=ts.createSourceFile(file,code,ts.ScriptTarget.Latest,true);
  const directive=ast.statements.some(s=>ts.isExpressionStatement(s)&&ts.isStringLiteral(s.expression)&&s.expression.text==='use server');
  const marked=ast.statements.some(s=>ts.isImportDeclaration(s)&&s.moduleSpecifier.text==='server-only');
  if(!directive&&!marked)return null;
  const names=new Set();let hasDefault=false;
  const exported=n=>n.modifiers?.some(m=>m.kind===ts.SyntaxKind.ExportKeyword);
  function binding(n){if(ts.isIdentifier(n))names.add(n.text);else if(ts.isObjectBindingPattern(n)||ts.isArrayBindingPattern(n))for(const e of n.elements)if(ts.isBindingElement(e))binding(e.name);}
  for(const n of ast.statements){
    if(ts.isExportAssignment(n)){hasDefault=true;continue;}
    if(ts.isExportDeclaration(n)&&!n.isTypeOnly){
      if(n.exportClause&&ts.isNamedExports(n.exportClause)){
        for(const e of n.exportClause.elements)if(!e.isTypeOnly){if(e.name.text==='default')hasDefault=true;else names.add(e.name.text);}
      }else throw Error(`Server-only wildcard exports need a preview adapter: ${path.relative(root,file)}`);
    }
    if(!exported(n)||ts.isInterfaceDeclaration(n)||ts.isTypeAliasDeclaration(n))continue;
    if(n.modifiers?.some(m=>m.kind===ts.SyntaxKind.DefaultKeyword)){hasDefault=true;continue;}
    if(ts.isVariableStatement(n))for(const d of n.declarationList.declarations)binding(d.name);
    else if(n.name&&ts.isIdentifier(n.name))names.add(n.name.text);
  }
  const message=`Server code is unavailable in component previews (${path.relative(root,file)}). Open the live page to use this action.`;
  // Never import or execute server code, credentials, databases or action bodies.
  const stub=`const unavailable=()=>{throw new Error(${JSON.stringify(message)})};\n`;
  return {code:stub+[...names].map((name,i)=>`const export${i}=unavailable;export {export${i} as ${JSON.stringify(name)}};`).join('\n')+(hasDefault?'\nexport default unavailable;':''),map:null};
}

export function previewBoundaries(root){
  const navigation=fileURLToPath(new URL('./client/next-navigation.mjs',import.meta.url));
  return {name:'webframes-preview-boundaries',enforce:'pre',
    resolveId(id){if(id==='next/navigation')return navigation;},
    transform(code,id){return serverBoundary(code,id,root);}
  };
}
