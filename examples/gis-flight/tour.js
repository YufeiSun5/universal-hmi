/* Presentation clock only. No station values, persistence, network or controls. */
'use strict';
// Re-time the existing 12 s eased path: its local speed is the minimum.
// Only the Asian overview keeps that speed. Other regions run at 2.6x,
// regardless of sunlight; blend across the Asian margins without a speed step.
globalThis.createGisOrbitMotion = function(){
  const smooth=t=>t*t*(3-2*t),rad=Math.PI/180,steps=720,times=[0];
  const lightAt=q=>Math.sin(20*rad)*Math.sin(35*rad)+Math.cos(20*rad)*Math.cos(35*rad)*Math.cos((102+360*smooth(q)-62)*rad);
  const longitudeAt=q=>102+360*smooth(q);
  const speedAt=q=>{
    const asiaDistance=Math.abs(((longitudeAt(q)-110+540)%360)-180);
    return 1+1.6*smooth(Math.max(0,Math.min(1,(asiaDistance-30)/20)));
  };
  for(let i=1;i<=steps;i++)times[i]=times[i-1]+12/steps/speedAt((i-.5)/steps);
  const duration=times[steps];
  return {duration,at(seconds){
    const t=Math.max(0,Math.min(duration,seconds));let lo=0,hi=steps;
    while(hi-lo>1){const mid=(lo+hi)>>1;if(times[mid]<=t)lo=mid;else hi=mid;}
    const q=(lo+(t-times[lo])/(times[hi]-times[lo]))/steps;
    return {turn:smooth(q),speedMultiplier:speedAt(q),illumination:lightAt(q),longitude:((longitudeAt(q)+180)%360)-180};
  }};
};
globalThis.createGisTour = function({onPhase=()=>{},onFrame=()=>{},reducedMotion=false,orbitDuration=12}={}) {
  let phase='idle',elapsed=0,index=-1,count=null,enabled=false,suspended=false,cycles=0;
  let returnNext='intro',mode='demo';
  const durations={intro:reducedMotion?0:6,approach:0,travel:reducedMotion?0:.85,station:3.5,empty:3.5,return:reducedMotion?0:1.4,orbit:orbitDuration};
  const state=()=>({phase,elapsed,index,count,enabled,suspended,cycles,mode,
    duration:durations[phase]??0,progress:durations[phase]?Math.min(1,elapsed/durations[phase]):1});
  function enter(next){phase=next;elapsed=0;onPhase(state());onFrame(state());}
  function firstStation(){index=0;enter(count===null?'waiting':count?'travel':'empty');}
  function next(){
    if(phase==='approach'){enter(enabled?(count?'station':'empty'):'idle');}
    else if(phase==='intro'){if(enabled)firstStation();else enter('idle');}
    else if(phase==='travel')enter('station');
    else if(phase==='station'&&index+1<count){index++;enter('travel');}
    else if(phase==='station'||phase==='empty'){
      if(reducedMotion||mode==='static'){cycles++;firstStation();}
      else {returnNext='orbit';enter('return');}
    } else if(phase==='return')enter(returnNext);
    else if(phase==='orbit'){cycles++;enter('intro');}
  }
  function advance(seconds){
    if(suspended||phase==='idle'||phase==='waiting')return;
    let remaining=Math.max(0,Number.isFinite(seconds)?seconds:0);
    // Bound work for callers with a very large clock jump. The browser passes
    // at most 100 ms, and suspension never accrues missed display time.
    for(let transitions=0;transitions<16;transitions++){
      const duration=durations[phase];
      if(duration===undefined)break;
      const used=Math.min(remaining,Math.max(0,duration-elapsed));
      elapsed+=used;remaining-=used;onFrame(state());
      if(elapsed+1e-9<duration)break;
      next();
      if(remaining<=0&&(durations[phase]??1)>0)break;
    }
  }
  function restart(loop,fromGlobe){
    mode='demo';enabled=loop;index=-1;returnNext='intro';
    enter(fromGlobe||reducedMotion?'intro':'return');advance(0);
  }
  return {
    get state(){return state();},advance,
    start({loop=true,fromGlobe=false}={}){restart(loop,fromGlobe);},
    startDemo(){
      if(enabled&&mode==='demo'&&['return','orbit'].includes(phase))return;
      mode='demo';enabled=true;returnNext='orbit';
      if(reducedMotion)firstStation();else enter('return');
      advance(0);
    },
    startNear(stationIndex,{duration=.6}={}){
      mode='static';enabled=true;index=Math.max(0,Math.min((count||1)-1,stationIndex));
      durations.approach=reducedMotion?0:Math.max(0,Math.min(2,duration));
      enter(count===null?'waiting':'approach');advance(0);
    },
    reset({duration=.6}={}){enabled=false;index=-1;durations.approach=reducedMotion?0:Math.max(0,Math.min(2,duration));enter('approach');advance(0);},
    stop(){enabled=false;enter('idle');},
    suspend(value){suspended=!!value;},
    setStationCount(value){
      count=value===null?null:Math.max(0,Math.min(100,Math.floor(value)));
      if(enabled&&['approach','travel','station','waiting','empty'].includes(phase)){firstStation();advance(0);}
    },
  };
};
