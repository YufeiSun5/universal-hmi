// Exercise the production pointer adapter with deterministic time and events.
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
class Target {
  listeners=new Map();
  addEventListener(type,fn){if(!this.listeners.has(type))this.listeners.set(type,new Set());this.listeners.get(type).add(fn);}
  removeEventListener(type,fn){this.listeners.get(type)?.delete(fn);}
  emit(type,event={}){for(const fn of this.listeners.get(type)||[])fn(event);}
}
const window=new Target();vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../examples/gis-flight/stations.js'),'utf8'),{window});
let time=0;
function fixture(){
  const root=new Target(),a={},b={},taps=[],outside=[];
  const input=window.createStationTouchInput(root,{resolve:t=>t===a||t===b?t:null,onTap:(s,double)=>taps.push([s,double]),onOutside:t=>outside.push(t),now:()=>time});
  function event(type,target=a,extra={}){root.emit(type,{pointerType:'touch',pointerId:1,clientX:50,clientY:50,target,...extra});}
  function tap(target=a,extra={}){event('pointerdown',target,extra);time+=30;event('pointerup',target,extra);}
  return {root,a,b,taps,outside,input,event,tap};
}
let f=fixture();f.tap();assert.deepEqual(f.taps,[[f.a,false]]);time+=160;f.tap();assert.deepEqual(f.taps,[[f.a,false],[f.a,true]]);
assert.equal(f.input.suppressClick({pointerType:'touch',detail:1}),true);
assert.equal(f.input.suppressClick({detail:1}),true);
assert.equal(f.input.suppressClick({pointerType:'mouse',detail:1}),false);
assert.equal(f.input.suppressClick({detail:0}),false); // keyboard activation
time+=100;f.tap();assert.equal(f.taps.at(-1)[1],false); // triple tap is not a second action
f.input.dispose();
f=fixture();f.tap();time+=400;f.tap();assert.ok(f.taps.every(t=>!t[1]));f.input.dispose();
f=fixture();f.tap();time+=50;f.tap(f.b);assert.ok(f.taps.every(t=>!t[1]));f.input.dispose();
for(const end of ['pointerup','pointercancel']){
  f=fixture();f.event('pointerdown');f.event('pointermove',f.a,{clientX:80});f.event(end);assert.equal(f.taps.length,0);f.tap();assert.equal(f.taps[0][1],false);f.input.dispose();
}
f=fixture();f.event('pointerdown');f.event('pointerup',f.a,{clientX:80});assert.equal(f.taps.length,0);f.input.dispose();
f=fixture();f.event('pointerdown');time+=700;f.event('pointerup');assert.equal(f.taps.length,0);f.input.dispose();
f=fixture();f.tap();f.event('pointerdown');f.event('pointerdown',f.b,{pointerId:2});f.event('pointerup');f.event('pointerup',f.b,{pointerId:2});assert.equal(f.taps.length,1);f.tap();assert.equal(f.taps.at(-1)[1],false);f.input.dispose();
f=fixture();f.tap();f.tap({});assert.equal(f.outside.length,1);f.tap();assert.equal(f.taps.at(-1)[1],false);f.input.dispose();
f=fixture();f.tap();window.emit('blur');f.tap();assert.equal(f.taps.at(-1)[1],false);f.input.dispose();f.tap();assert.equal(f.taps.length,2);
console.log('PASS GIS: single/double/triple tap, same target/time/distance, drag, pinch, cancel, long press, outside, keyboard/mouse, blur and disposal');
