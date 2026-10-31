// Deterministic presentation clock: full holds, no hidden-time catch-up, resets.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const scope={};vm.createContext(scope);
vm.runInContext(fs.readFileSync(path.join(__dirname,'../examples/gis-flight/tour.js'),'utf8'),scope);
const make=opts=>scope.createGisTour(opts);
const orbit=scope.createGisOrbitMotion();
assert.ok(orbit.duration<12&&orbit.duration>6);
assert.equal(orbit.at(0).turn,0);assert.equal(orbit.at(orbit.duration).turn,1);
let previous=0,asia=0,africa=0,americas=0,lastSpeed=1;
for(let t=0;t<orbit.duration;t+=.01){
  const s=orbit.at(t);assert.ok(s.turn>=previous);previous=s.turn;
  assert.ok(s.speedMultiplier>=1&&s.speedMultiplier<=2.6);
  assert.ok(Math.abs(s.speedMultiplier-lastSpeed)<.08,'speed changes continuously');lastSpeed=s.speedMultiplier;
  if(s.longitude>=80&&s.longitude<=140){assert.equal(s.speedMultiplier,1);asia++;}
  if(s.longitude>=-15&&s.longitude<=50){assert.equal(s.speedMultiplier,2.6);africa++;}
  if(s.longitude>=-130&&s.longitude<=-40){assert.equal(s.speedMultiplier,2.6);americas++;}
}
assert.ok(asia>0&&africa>0&&americas>0);
const accelerated=make({orbitDuration:orbit.duration});accelerated.setStationCount(0);accelerated.start({fromGlobe:true});accelerated.advance(6);accelerated.advance(3.5);accelerated.advance(1.4);assert.equal(accelerated.state.phase,'orbit');accelerated.advance(orbit.duration);assert.equal(accelerated.state.phase,'intro');
console.log(`PASS: Asia-only slow view, Africa/Americas fast regardless of daylight, continuous full orbit in ${orbit.duration.toFixed(3)} s`);
let tour=make();tour.setStationCount(2);tour.start({fromGlobe:true});
tour.advance(6);assert.equal(tour.state.phase,'travel');
tour.advance(.85);assert.equal(tour.state.phase,'station');assert.equal(tour.state.index,0);
tour.advance(3.49);assert.equal(tour.state.index,0);assert.equal(tour.state.phase,'station');
tour.advance(.01);assert.equal(tour.state.phase,'travel');assert.equal(tour.state.index,1);
tour.advance(.85);tour.advance(3.5);assert.equal(tour.state.phase,'return');
tour.advance(1.4);assert.equal(tour.state.phase,'orbit');
tour.advance(12);assert.equal(tour.state.phase,'intro');assert.equal(tour.state.cycles,1);
tour.advance(6.85);assert.equal(tour.state.phase,'station');assert.equal(tour.state.index,0);
tour.suspend(true);const elapsed=tour.state.elapsed;tour.advance(100);assert.equal(tour.state.elapsed,elapsed);
tour.suspend(false);tour.advance(2);tour.reset({duration:.4});assert.equal(tour.state.phase,'approach');assert.equal(tour.state.enabled,false);
tour.advance(.4);assert.equal(tour.state.phase,'idle');tour.advance(100);assert.equal(tour.state.phase,'idle');
tour.startNear(1,{duration:0});assert.equal(tour.state.phase,'station');assert.equal(tour.state.index,1);assert.equal(tour.state.enabled,true);
tour.reset({duration:0});assert.equal(tour.state.phase,'idle');assert.equal(tour.state.enabled,false);
tour.stop();tour.advance(100);assert.equal(tour.state.phase,'idle');
tour.reset();tour.advance(1.4);tour.advance(6);assert.equal(tour.state.phase,'idle');assert.equal(tour.state.enabled,false);
tour=make();tour.start({fromGlobe:true});tour.advance(6);assert.equal(tour.state.phase,'waiting');
tour.advance(500);assert.equal(tour.state.phase,'waiting');
tour.setStationCount(0);assert.equal(tour.state.phase,'empty');tour.advance(3.5);assert.equal(tour.state.phase,'return');
tour=make({reducedMotion:true});tour.setStationCount(1);tour.start({fromGlobe:true});
assert.equal(tour.state.phase,'station');tour.advance(3.5);assert.equal(tour.state.phase,'station');assert.equal(tour.state.cycles,1);
tour.setStationCount(3);tour.advance(3.5);assert.equal(tour.state.index,1);
tour.setStationCount(null);assert.equal(tour.state.phase,'waiting');tour.stop();tour.setStationCount(2);assert.equal(tour.state.phase,'idle');
console.log('PASS: 3.5 s station holds, order, full orbit, second cycle, suspension, stop/reset, config changes, empty and reduced motion');
const phases=[];tour=make({onPhase:s=>phases.push(s.phase)});tour.setStationCount(2);
tour.startNear(0,{duration:0});assert.equal(tour.state.mode,'static');
for(let i=0;i<20;i++)tour.advance(1);
assert.ok(tour.state.cycles>=2);assert.ok(!phases.includes('return'));assert.ok(!phases.includes('orbit'));
tour.startNear(0,{duration:0});tour.advance(.2);tour.startDemo();
assert.equal(tour.state.phase,'return');assert.equal(tour.state.mode,'demo');assert.equal(tour.state.elapsed,0);
tour.advance(.7);tour.startDemo();assert.equal(tour.state.elapsed,.7);
tour.advance(.7);assert.equal(tour.state.phase,'orbit');tour.advance(2);tour.startDemo();assert.equal(tour.state.elapsed,2);
tour.startNear(1,{duration:.5});assert.equal(tour.state.mode,'static');assert.equal(tour.state.phase,'approach');tour.advance(.5);assert.equal(tour.state.index,1);
tour.stop();tour.advance(30);assert.equal(tour.state.phase,'idle');
tour=make();tour.setStationCount(0);tour.startNear(0,{duration:0});tour.advance(20);assert.equal(tour.state.phase,'empty');assert.equal(tour.state.mode,'static');
tour=make({reducedMotion:true});tour.setStationCount(2);tour.startDemo();assert.equal(tour.state.phase,'station');tour.advance(20);assert.equal(tour.state.mode,'demo');assert.ok(!['orbit','return'].includes(tour.state.phase));
console.log('PASS: static map repeats without globe, demo immediately interrupts holds, repeated demo click keeps flight, mode switches, empty map and reduced motion');
