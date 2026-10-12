import {test} from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import {renderToStaticMarkup} from 'react-dom/server';
import Link,{previewHref} from '../client/next-link.mjs';
import Image from '../client/next-image.mjs';
import {previewBoundaries} from '../preview-boundaries.mjs';

test('Next links render anchors, preserve URL objects and strip router-only props',()=>{
  assert.equal(previewHref({pathname:'/docs',query:{tag:['a','b'],empty:null},hash:'intro'}),'/docs?tag=a&tag=b#intro');
  const html=renderToStaticMarkup(React.createElement(Link,{href:'/docs',className:'link',prefetch:true,replace:true,onNavigate:()=>{}},'Docs'));
  assert.equal(html,'<a class="link" href="/docs">Docs</a>');
  assert.equal(renderToStaticMarkup(React.createElement(Link,{href:'/old',as:'/new',legacyBehavior:true,passHref:true},React.createElement('a',null,'Legacy'))),'<a href="/new">Legacy</a>');
});
test('Next images render original assets with intrinsic dimensions or fill layout',()=>{
  const html=renderToStaticMarkup(React.createElement(Image,{src:{src:'/shot.png',width:120,height:80},alt:'Preview',quality:90,unoptimized:true}));
  assert.match(html,/src="\/shot.png"/);assert.match(html,/width="120" height="80"/);assert.doesNotMatch(html,/quality|unoptimized|_next/);
  const fill=renderToStaticMarkup(React.createElement(Image,{src:'/fill.png',fill:true,style:{objectFit:'cover'}}));
  assert.match(fill,/position:absolute/);assert.match(fill,/object-fit:cover/);assert.doesNotMatch(fill,/ fill=/);
});
test('Only explicit Next preview adapters are resolved, server boundaries remain active',()=>{
  const plugin=previewBoundaries('/project');
  for(const name of ['navigation','link','image'])assert.ok(plugin.resolveId('next/'+name).endsWith('next-'+name+'.mjs'));
  assert.equal(plugin.resolveId('next/headers'),undefined);
  assert.match(plugin.transform('"use server";export async function save(){}','/project/action.ts').code,/Server code is unavailable/);
});
