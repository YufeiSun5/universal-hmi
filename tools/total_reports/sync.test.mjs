import {test} from 'node:test';
import assert from 'node:assert/strict';
import {CellSync, numeric} from './sync.mjs';
test('format changes batch, survive retries and do not lose later toolbar changes',()=>{
 const s=new CellSync([{address:'D2',value:'10',revision:1,format:{bg:'#FFFFFF'}}],1);
 s.edit('D2','10',{bg:'#FFFF00'});const batch=s.batch('format-a');
 s.edit('D2','10',{bg:'#00FF00'});assert.equal(s.batch('format-b'),batch);
 s.acknowledge({revision:2,cells:[{address:'D2',value:'10',revision:2,format:{bg:'#FFFF00'}}]});
 assert.deepEqual(s.pending.get('D2').format,{bg:'#00FF00'});assert.equal(s.pending.get('D2').expected,2);
});
test('timeout retries exact operation and later edits remain pending', () => {
  const s = new CellSync([{address:'D2', value:'10', revision:1}],1);
  s.edit('D2','20'); const b=s.batch('operation-a'); s.edit('D2','30');
  assert.equal(s.batch('operation-b'),b);
  s.acknowledge({revision:3,cells:[{address:'D2',value:'20',revision:3}]});
  assert.equal(s.pending.get('D2').value,'30'); assert.equal(s.pending.get('D2').expected,3);
  assert.equal(s.revision,1);
});
test('same-cell conflict preserves draft; distinct cell merges; explicit resolution rebases', () => {
  const s=new CellSync(); s.edit('D2','20'); s.batch('a'); s.rejectConflict();
  s.merge({revision:2,cells:[{address:'D2',value:'15',revision:1,actor:'other'},{address:'E2',value:'40',revision:2}]});
  assert.equal(s.value('D2'),'20'); assert.equal(s.value('E2'),'40'); assert.equal(s.batch('b'),null);
  s.resolve('D2',true); assert.equal(s.batch('c').changes[0].expected,1);
});
test('complete polling delta includes edits omitted by own receipt',()=>{
  const s=new CellSync(); s.edit('D2','8'); s.batch('a');
  s.acknowledge({revision:2,cells:[{address:'D2',value:'8',revision:2}]});
  assert.equal(s.revision,0);
  s.merge({revision:2,cells:[{address:'D2',value:'8',revision:2},{address:'E2',value:'9',revision:1}]});
  assert.equal(s.value('E2'),'9'); assert.equal(s.conflicts.size,0);
});
test('polling own in-flight save does not leave a false conflict after receipt',()=>{
 const s=new CellSync([{address:'J14',value:'',revision:0}],0);
 s.edit('J14','2323');s.batch('enter');
 const receipt={revision:1,cells:[{address:'J14',value:'2323',revision:1}]};
 s.merge(receipt);s.acknowledge(receipt);
 assert.equal(s.dirty,false);assert.equal(s.conflicts.size,0);
 s.merge({revision:0,cells:[]});assert.equal(s.revision,1);
});
test('invalid numbers and formulas rejected; empty and zero remain distinct',()=>{
  for(const v of ['=1+1','NaN','Infinity',' ','0x10','1,000']) assert.equal(numeric(v),false,v);
  for(const v of ['', '0','-2.4','1e3']) assert.equal(numeric(v),true,v);
});
