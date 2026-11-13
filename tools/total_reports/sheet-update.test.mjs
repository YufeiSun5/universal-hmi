import test from 'node:test';
import assert from 'node:assert/strict';
import {remoteOperations} from './sheet-update.mjs';
test('remote values and dependent displays update atomically without mutating local history input',()=>{
 const sheets=[{id:'total',name:'Sheet',data:[[{v:10,m:'10',ct:{t:'n',fa:'General'}},{v:20,m:'20'},{f:'=SUM(A1:B1)',v:30,m:'30'}]],calcChain:[{r:0,c:2,id:'total'}]}];
 const ops=remoteOperations(sheets,[{address:'A1',value:'15',format:{nf:'0.00',bg:'#FFFF00'}}]);
 assert.equal(sheets[0].data[0][0].v,10);
 const first=ops.find(x=>x.path[2]===0).value,last=ops.find(x=>x.path[2]===2).value;
 assert.equal(first.v,15);assert.equal(first.m,'15.00');assert.equal(first.bg,'#FFFF00');assert.equal(last.v,35);assert.equal(last.m,'35');assert.equal(last.f,'=SUM(A1:B1)');
});

test('top-of-sheet monthly and seasonal rollups recalculate from later daily rows',()=>{
 let sheets=[{id:'total',name:'Heat',data:[
  [{f:'=IF(COUNT(A2:A3)=0,"",SUM(A2:A3))'}],
  [{f:'=IF(COUNT(A6:A7)=0,"",SUM(A6:A7))'}],
  [{f:'=IF(COUNT(A8)=0,"",SUM(A8))'}],
  [{v:0}], [{v:100.25}],
  [{f:'=IF(COUNT(A4,A5)<>2,"",SUM(A5)-SUM(A4))'}],
  [{f:'=IF(COUNT(A4,A5)<>2,"",SUM(A5)-SUM(A4))'}],
  [{f:'=IF(COUNT(A4,A5)<>2,"",SUM(A5)-SUM(A4))'}],
 ],calcChain:[0,1,2,5,6,7].map(r=>({r,c:0,id:'total'}))}];
 const apply=cells=>{for(const op of remoteOperations(sheets,cells))sheets[0].data[op.path[1]][op.path[2]]=op.value;};
 apply([]);
 assert.equal(sheets[0].data[0][0].v,300.75);
 assert.equal(sheets[0].data[1][0].v,200.5);
 assert.equal(sheets[0].data[2][0].v,100.25);
 apply([{address:'A5',value:'200'}]);
 assert.equal(sheets[0].data[0][0].v,600);
 apply([{address:'A5',value:''}]);
 assert.equal(sheets[0].data[0][0].v??'','');
 assert.ok(sheets[0].data[0][0].f);
});
