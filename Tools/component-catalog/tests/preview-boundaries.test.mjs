import {test} from 'node:test';
import assert from 'node:assert/strict';
import {serverBoundary} from '../preview-boundaries.mjs';

test('server actions expose inert exports without loading server imports or executing bodies',async()=>{
  const code=`"use server"; import 'server-only'; import {db} from './database';
    globalThis.webframesUnexpectedServerExecution=true;
    export async function save(){return db.write()}
    export const remove=async()=>db.remove();
    export default async function submit(){return db.write()}`;
  const result=serverBoundary(code,'/project/actions.ts','/project');
  assert.ok(result);assert.doesNotMatch(result.code,/database|db\.write|UnexpectedServerExecution/);
  const module=await import('data:text/javascript,'+encodeURIComponent(result.code));
  for(const key of ['save','remove','default'])assert.throws(()=>module[key](),/Server code is unavailable/);
  assert.equal(globalThis.webframesUnexpectedServerExecution,undefined);
});
test('server-only utilities and aliased exports stop at the browser boundary',()=>{
  const result=serverBoundary(`import 'server-only';export {notify as send} from './private';export type {Secret} from './private'`, '/project/notify.ts','/project');
  assert.match(result.code,/as "send"/);assert.doesNotMatch(result.code,/private|Secret/);
});
test('client modules, string mentions and dependencies remain untouched',()=>{
  assert.equal(serverBoundary(`"use client";export const hint="use server"`, '/project/Button.tsx','/project'),null);
  assert.equal(serverBoundary(`"use server";export const x=1`, '/project/node_modules/lib/index.js','/project'),null);
  assert.equal(serverBoundary(`"use server";export const x=1`, '/other/actions.ts','/project'),null);
});

test('mixed type exports are ignored and wildcard server exports fail clearly',()=>{
  const result=serverBoundary(`"use server";export {type Secret, save} from './private'`, '/project/actions.ts','/project');
  assert.match(result.code,/as "save"/);assert.doesNotMatch(result.code,/Secret|private/);
  assert.throws(()=>serverBoundary(`"use server";export * from './private'`, '/project/actions.ts','/project'),/preview adapter/);
});
