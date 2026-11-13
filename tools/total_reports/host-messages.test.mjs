import test from 'node:test';
import assert from 'node:assert/strict';
import {listenToHost} from './host-messages.mjs';

function fixture(native=false){
 const target=new EventTarget();
 target.location={origin:'http://127.0.0.1:12345'};target.parent={};
 if(native)target.chrome={webview:new EventTarget()};
 const received=[];const stop=listenToHost(target,'reports',m=>received.push(m));
 const message=(emitter,data,origin='',source=null)=>{
  const event=new Event('message');Object.assign(event,{data,origin,source});emitter.dispatchEvent(event);
 };
 return {target,received,stop,message};
}
test('native JSON result is delivered without iframe event source or origin',()=>{
 const {target,received,stop,message}=fixture(true);
 const result={channel:'reports',type:'apiResult',id:'catalog',result:{items:[]}};
 message(target.chrome.webview,result);
 assert.deepEqual(received,[result]);
 stop();message(target.chrome.webview,result);assert.equal(received.length,1);
});
test('browser messages still require same origin and exact parent',()=>{
 const {target,received,message}=fixture();
 const result=JSON.stringify({channel:'reports',type:'leave'});
 message(target,result,'http://attacker.invalid',target.parent);
 message(target,result,target.location.origin,{});
 message(target,'{',target.location.origin,target.parent);
 assert.deepEqual(received,[]);
 message(target,result,target.location.origin,target.parent);
 assert.equal(received.length,1);
});
