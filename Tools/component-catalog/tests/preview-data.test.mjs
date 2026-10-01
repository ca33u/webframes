import {test} from 'node:test';
import assert from 'node:assert/strict';
import {missingProps, validExamples, initialState} from '../client/preview-data.mjs';
test('required data is checked before rendering without blocking callbacks and false/zero values',()=>{
  const c={props:[{name:'rows',required:true,kind:'json'},{name:'onSave',required:true,kind:'action'},{name:'count',required:true},{name:'active',required:true},{name:'optional',required:false}]};
  assert.deepEqual(missingProps(c,{count:0,active:false}),['rows']);
  assert.deepEqual(missingProps(c,{rows:[],count:0,active:false}),[]);
});
test('malformed examples cannot crash the entire catalogue',()=>{
  assert.deepEqual(validExamples(null),{});
  assert.deepEqual(validExamples({A:null,B:'invalid',C:[null,{name:'ok',args:{rows:[]}}, {name:'bad',args:[]}]}),{C:[{name:'ok',args:{rows:[]}}]});
});
test('saved data is reused in the grid and inspector before project examples',()=>{
  const c={id:'a',name:'A',defaults:{active:false}}, m={examples:{A:[{name:'Demo',args:{rows:[1]}}]}};
  assert.deepEqual(initialState(c,m).args,{active:false,rows:[1]});
  const saved={args:{rows:[2]},theme:'dark',width:640};
  assert.equal(initialState(c,m,{a:{Saved:saved}}),saved);
});
