'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(require('node:path').join(__dirname,'../../app/web/hmi_start.js'),'utf8');
const key='universal-hmi.kp.web-session.v1';
function fixture({ticket='t'.repeat(43),blocked=false,android=false}={}) {
  const storage=new Map([[key,'old-token'],[key+'.logout-pending','1']]);
  const scripts=[],requests=[],failures=[],preloads=[];
  const scope={URL,URLSearchParams,AbortSignal,location:{pathname:android?'/':'/kp/',search:android?'?client=android':'',hash:ticket?'#ticket='+ticket:''},
    document:{getElementById:()=>null,createElement:()=>({}),body:{append:s=>scripts.push(s)},head:{append:s=>preloads.push(s)}},
    history:{state:null,replaceState:(_state,_title,path)=>{assert.ok(!path.includes('ticket'));scope.location.hash='';}},
    sessionStorage:{removeItem:k=>{if(blocked)throw Error('storage blocked');storage.delete(k);},setItem:(k,v)=>{if(blocked)throw Error('storage blocked');storage.set(k,v);}},
    fetch:(path,options)=>new Promise((resolve,reject)=>requests.push({path,options,reply:(data,ok=true)=>resolve({ok,json:async()=>data}),reject})),
    hmiLoading:{show:()=>{},fail:(...args)=>failures.push(args)}};
  scope.window=scope;scope.self=scope;scope.top=scope;
  const context=vm.createContext(scope),run=()=>vm.runInContext(source,context);
  run();return {scope,storage,scripts,requests,failures,preloads,run,flush:()=>new Promise(r=>setImmediate(r))};
}
(async()=>{
  {
    const f=fixture();assert.equal(f.scripts.length,0);assert.equal(f.requests.length,1);assert.equal(f.preloads.length,0);
    assert.equal(f.scope.location.hash,'');assert.equal(f.storage.has(key),false);assert.equal(f.storage.has(key+'.logout-pending'),false);
    const r=f.requests[0];assert.equal(r.path,'/api/v1/web/redeem');assert.equal(r.options.method,'POST');
    assert.equal(JSON.parse(r.options.body).ticket,'t'.repeat(43));assert.equal(r.options.redirect,'error');assert.equal(r.options.credentials,'same-origin');
    f.run();assert.equal(f.requests.length,1);assert.equal(f.scripts.length,0);
    r.reply({authenticated:true,webToken:'w'.repeat(43)});await f.flush();
    assert.equal(f.scope.hmiKpToken,'w'.repeat(43));assert.equal(f.storage.get(key),'w'.repeat(43));
    assert.equal(f.scripts.length,1);assert.equal(f.scripts[0].src,'flutter_bootstrap.js');
    assert.equal(f.preloads.length,2);assert.ok(f.preloads.every(p=>p.rel==='preload'&&p.as==='fetch'&&p.crossOrigin==='anonymous'));
  }
  {
    const f=fixture({blocked:true});f.requests[0].reply({authenticated:true,webToken:'w'.repeat(43)});await f.flush();
    assert.equal(f.scope.hmiKpToken,'w'.repeat(43));assert.equal(f.scripts.length,1);
  }
  {
    const f=fixture();f.requests[0].reply({error:{code:'ticket_used_or_expired',message:'untrusted response'}},false);await f.flush();
    assert.equal(f.scripts.length,0);assert.equal(f.scope.hmiKpToken,null);assert.equal(f.failures[0][1],false);
    assert.match(f.failures[0][0],/重新打开/);assert.ok(!f.failures[0][0].includes('untrusted'));
  }
  {
    const f=fixture();f.requests[0].reply({authenticated:false,webToken:'w'.repeat(43)});await f.flush();assert.equal(f.scripts.length,0);
  }
  {
    const f=fixture();f.requests[0].reject(new Error('timeout'));await f.flush();assert.equal(f.scripts.length,0);assert.match(f.failures[0][0],/网络/);
  }
  {
    const f=fixture({ticket:null});assert.equal(f.requests.length,0);assert.equal(f.scripts.length,1);assert.equal(f.storage.get(key),'old-token');
  }
  {
    const f=fixture({android:true,ticket:null});assert.equal(f.requests.length,0);assert.equal(f.scripts.length,1);assert.equal(f.preloads.length,0);
  }
  console.log('PASS 7 early KP entry contracts: redeem before renderer, single-use, storage-blocked memory, failure and existing entries');
})().catch(error=>{console.error(error);process.exitCode=1;});
