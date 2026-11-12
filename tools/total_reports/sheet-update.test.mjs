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
