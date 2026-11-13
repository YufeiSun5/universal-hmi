import {test} from 'node:test';
import assert from 'node:assert/strict';
import {historyDisplayOperations,pendingHistoryCells,historyNotice} from './history-display.mjs';
import {observedCells,changedCells} from './editor-session.mjs';
test('loading and provisional markers never change values or collaborative drafts',()=>{
 const sheets=[{id:'s',data:[[{v:null,m:'',lo:1},{v:0,m:'0',lo:1},{v:10,m:'10',f:'=2*5',lo:1}]]}];
 const items=[{address:'A1',eligible:true},{address:'B1',eligible:true,provisional:true,value:'0',sample_time:'2026-11-13T12:34:00+08:00'},{address:'C1',eligible:false}];
 const specs=sheets[0].data[0].map((v,c)=>({r:0,c,v}));const before=observedCells(sheets[0],specs);
 const ops=historyDisplayOperations(sheets,items,pendingHistoryCells(items));
 assert.deepEqual(ops.map(x=>x.value),['加载中…','0 *']);
 for(const op of ops)sheets[0].data[op.path[1]][op.path[2]][op.path[3]]=op.value;
 assert.deepEqual(changedCells(before,observedCells(sheets[0],specs)),[]);
 const cleared=historyDisplayOperations(sheets,items,new Set());assert.equal(cleared[0].value,'');
 assert.match(historyNotice(items),/12:34:00/);assert.match(historyNotice(items),/尚未结算/);
 items[1].provisional=false;assert.equal(historyDisplayOperations(sheets,items,new Set())[1].value,'0');
});
