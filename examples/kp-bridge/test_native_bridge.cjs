'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {webcrypto} = require('node:crypto');
const source = fs.readFileSync(require('node:path').join(__dirname,'../../app/web/kp_bridge.js'),'utf8');
function fixture() {
  let user='alice', proof='proof-alice', serial=0;
  const timers=new Map(),requests=[],urls=[],logoffs=[];
  const scope={URL,Uint8Array,crypto:webcrypto,location:{host:'kp.test:11005'},sessionStorage:{getItem:()=>proof},
    setTimeout:(fn,ms)=>{timers.set(++serial,{fn,ms});return serial;},clearTimeout:id=>timers.delete(id),
    httpRequestExec:(base,path,method,body,type,callback)=>requests.push({base,path,body,callback}),
    LogOff:cb=>logoffs.push(cb),addEventListener:()=>{}};
  scope.window=scope;vm.runInNewContext(source,scope);
  const open=()=>scope.HMIKP.open('https://hmi.test',{setURL:url=>urls.push(url)},()=>user);
  const flush=()=>new Promise(resolve=>setImmediate(resolve));
  const boot=async(request=requests.at(-1))=>{request.callback({ok:true,...request.body,bridgeToken:'b'.repeat(43),ticket:'t'.repeat(43)});await flush();};
  const tick=async()=>{const timer=[...timers].find(([,t])=>t.ms===5000);assert.ok(timer);timers.delete(timer[0]);timer[1].fn();await flush();};
  return {scope,requests,urls,logoffs,open,boot,tick,flush,setUser:value=>user=value,setProof:value=>proof=value};
}
(async()=>{
  {
    const f=fixture();f.open();await f.boot();assert.match(f.urls.at(-1),/\/kp\/#ticket=/);
    await f.tick();const r=f.requests.at(-1);assert.equal(r.path,'/api/v1/kp/poll');assert.equal(r.body.identityProof,'proof-alice');
    f.setProof('refreshed-token');r.callback({ok:true,...r.body,command:'none'});await f.flush();await f.tick();assert.equal(f.requests.at(-1).body.identityProof,'refreshed-token');
    assert.ok(f.urls.every(url=>!url.includes('proof-alice')&&!url.includes('refreshed-token')));
  }
  {
    const f=fixture();f.open();const stale=f.requests.at(-1);f.setUser('bob');await f.boot(stale);
    assert.ok(!f.urls.some(url=>url.includes('#ticket')));assert.equal(f.requests.at(-1).body.userName,'bob');
    assert.ok(f.requests.some(r=>r.path==='/api/v1/kp/close'&&r.body.contextId===stale.body.contextId));
  }
  {
    const f=fixture();f.open();await f.boot();await f.tick();const stale=f.requests.at(-1);f.setUser('bob');stale.callback({ok:true,...stale.body,command:'logout'});await f.flush();
    assert.equal(f.logoffs.length,0);assert.equal(f.requests.at(-1).body.userName,'bob');
  }
  {
    const f=fixture();f.open();await f.boot();await f.tick();const r=f.requests.at(-1);r.callback({ok:true,...r.body,command:'logout'});await f.flush();
    assert.equal(f.logoffs.length,1);f.logoffs[0](false);await f.flush();assert.equal(f.requests.at(-1).body.success,false);
    await f.tick();const again=f.requests.at(-1);again.callback({ok:true,...again.body,command:'logout'});await f.flush();f.logoffs[1](true);await f.flush();
    assert.ok(f.requests.some(r=>r.path==='/api/v1/kp/logoff-result'&&r.body.success===true));
  }
  {
    const f=fixture();f.open();await f.boot();await f.tick();f.requests.at(-1).callback({error:{code:'identity_not_verified'}});await f.flush();
    assert.match(f.urls.at(-1),/kp-fallback.html$/);assert.equal(f.requests.at(-1).path,'/api/v1/kp/close');
  }
  {
    const f=fixture();f.open();f.requests.at(-1).callback({ok:true});await f.flush();assert.match(f.urls.at(-1),/kp-fallback.html$/);
  }
  {
    const f=fixture();f.open();await f.boot();await f.tick();const old=f.requests.at(-1);old.callback({ok:true,...old.body,command:'rebootstrap'});await f.flush();
    assert.equal(f.requests.at(-1).path,'/api/v1/kp/bootstrap');assert.notEqual(f.requests.at(-1).body.contextId,old.body.contextId);
  }
  {
    const f=fixture();f.open();const stale=f.requests.at(-1);f.scope.HMIKP.close();await f.boot(stale);
    assert.ok(!f.urls.some(url=>url.includes('#ticket')));assert.equal(f.requests.at(-1).path,'/api/v1/kp/close');
  }
  console.log('PASS 8 native KP script contracts');
})().catch(error=>{console.error(error);process.exitCode=1;});
