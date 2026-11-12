import {test} from 'node:test';
import assert from 'node:assert/strict';
import {LeaseQueue,observedCells,changedCells} from './editor-session.mjs';
test('late renewal cannot revive a released lease; queue continues after failure',async()=>{
 const queue=new LeaseQueue();let finish;const operations=[],server=new Set(['E7']);
 const renewal=queue.run(async()=>{await new Promise(resolve=>finish=resolve);server.add('E7');operations.push('renew');});
 await Promise.resolve();
 const release=queue.run(async()=>{server.clear();operations.push('release');});
 finish();await Promise.all([renewal,release]);assert.deepEqual(operations,['renew','release']);assert.equal(server.size,0);
 await assert.rejects(queue.run(()=>{throw new Error('conflict');}));
 await queue.run(()=>server.add('J14'));assert.deepEqual([...server],['J14']);
});
test('formula cache recalculation does not create edits or acquire unrelated cells',()=>{
 const specs=[{r:0,c:0,v:{}},{r:0,c:1,v:{}}];
 const a={data:[[{f:'=SUM(B1,1)',v:1,m:'1',ff:'Arial',fs:11},{v:0}]]};
 const b={data:[[{f:'=SUM(B1,1)',v:4,m:'4',ff:'Arial',fs:11},{v:3}]]};
 assert.deepEqual(changedCells(observedCells(a,specs),observedCells(b,specs)).map(c=>c.address),['B1']);
});
test('a fast Enter edit is preserved even before acquiring its lease; empty and zero differ',()=>{
 const specs=[{r:0,c:0,v:{}}];
 const edits=changedCells(observedCells({data:[[null]]},specs),observedCells({data:[[{v:0}]]},specs));
 assert.equal(edits.length,1);assert.equal(edits[0].value,'0');
});
