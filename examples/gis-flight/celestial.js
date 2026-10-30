/* Bounded cinematic meteor trails; bodies and flow direction come from 3D. */
'use strict';
window.createCelestialIntro=function(canvas,{reducedMotion=false}={}){
  const ctx=canvas.getContext('2d');
  let width=0,height=0,frames=0,cleared=true,lastProgress=1,mode='intro',orbitTime=0;
  let flow={x:-1,y:.25},activeMeteors=0,meteorSequence=0,meteorScale=1;
  const tracks=[null,null];
  const clamp=v=>Math.max(0,Math.min(1,v)),smooth=v=>{v=clamp(v);return v*v*(3-2*v);};
  const glow=document.createElement('canvas');glow.width=glow.height=64;
  const gc=glow.getContext('2d'),halo=gc.createRadialGradient(32,32,0,32,32,32);
  halo.addColorStop(0,'rgba(255,250,230,1)');halo.addColorStop(.08,'rgba(245,251,255,.95)');
  halo.addColorStop(.23,'rgba(142,208,255,.34)');halo.addColorStop(1,'rgba(75,151,235,0)');
  gc.fillStyle=halo;gc.fillRect(0,0,64,64);
  function clear(){if(!cleared){ctx?.clearRect(0,0,width,height);cleared=true;}activeMeteors=0;}
  function meteor(seconds,slot,period,start,duration,alpha){
    const cycle=Math.floor(seconds/period),t=(seconds-cycle*period-start)/duration;
    if(t<=0||t>=1)return;
    activeMeteors++;
    if(!tracks[slot]||tracks[slot].cycle!==cycle){
      const len=Math.hypot(flow.x,flow.y)||1,dx=flow.x/len,dy=flow.y/len;
      const seed=++meteorSequence+slot*17;
      const random=n=>{const value=Math.sin(seed*12.9898+n*78.233)*43758.5453;return value-Math.floor(value);};
      // Coherent direction, varied origins. Every pass gets its own placement;
      // neither an orbit restart nor the two slots reuse one fixed launch point.
      tracks[slot]={cycle,dx,dy,x:((dx<0?.42:.06)+random(1)*.48)*width,
        y:(.08+random(2)*.82)*height,distance:Math.min(width*(.26+.17*random(3)),600),bend:(random(4)-.5)*22};
    }
    const a=tracks[slot],distance=a.distance,head=t*distance;
    const tail=Math.min(width*.22,290)*smooth(t/.16)*meteorScale,nx=-a.dy,ny=a.dx;
    const bend=a.bend;
    const point=d=>({x:a.x+a.dx*d+nx*bend*(d/distance)**2,y:a.y+a.dy*d+ny*bend*(d/distance)**2});
    const p=point(head),back=point(head-tail);
    const strength=alpha*smooth(t/.12)*(1-smooth((t-.66)/.34));
    ctx.save();ctx.globalCompositeOperation='lighter';ctx.lineCap='round';
    const gradient=ctx.createLinearGradient(back.x,back.y,p.x,p.y);
    gradient.addColorStop(0,'rgba(65,132,218,0)');gradient.addColorStop(.32,`rgba(83,157,238,${strength*.08})`);
    gradient.addColorStop(.78,`rgba(142,211,255,${strength*.45})`);gradient.addColorStop(1,`rgba(255,249,223,${strength*.95})`);
    // Wide translucent wake, then a tapered core: no opaque straight slash.
    ctx.strokeStyle=gradient;ctx.lineWidth=7*meteorScale;ctx.globalAlpha=.24;
    ctx.beginPath();ctx.moveTo(back.x,back.y);const mid=point(head-tail*.5);ctx.quadraticCurveTo(mid.x,mid.y,p.x,p.y);ctx.stroke();
    ctx.globalAlpha=1;ctx.fillStyle=gradient;ctx.beginPath();
    for(let side=-1;side<=1;side+=2){for(let k=0;k<=16;k++){
      const u=side<0?k/16:1-k/16,q=point(head-tail+tail*u),w=(.12+1.35*u*u)*strength*meteorScale;
      if(side<0&&k===0)ctx.moveTo(q.x+nx*w*side,q.y+ny*w*side);else ctx.lineTo(q.x+nx*w*side,q.y+ny*w*side);
    }}ctx.closePath();ctx.fill();
    // Seven faint fragments are evaluated analytically; nothing is accumulated.
    for(let k=0;k<7;k++){
      const u=(k+1)/8,q=point(head-tail*u),scatter=Math.sin(k*2.7+slot)*6*u*meteorScale;
      ctx.globalAlpha=strength*(1-u)*.36;ctx.fillStyle=k%3?'#a9d9ff':'#ffe3b5';
      ctx.beginPath();ctx.ellipse(q.x+nx*scatter,q.y+ny*scatter,(.45+.45*(1-u))*meteorScale,.45*meteorScale,0,0,Math.PI*2);ctx.fill();
    }
    ctx.globalAlpha=strength;const size=32*meteorScale;
    ctx.drawImage(glow,p.x-size/2,p.y-size/2,size,size);
    ctx.fillStyle='#fff8e7';ctx.beginPath();ctx.ellipse(p.x,p.y,1.9*meteorScale,1.05*meteorScale,Math.atan2(a.dy,a.dx),0,Math.PI*2);ctx.fill();
    ctx.restore();
  }
  function render(seconds,alpha){
    if(!ctx||!width||reducedMotion||alpha<=0||meteorScale<.02){clear();return;}
    if(document.hidden)return;
    ctx.clearRect(0,0,width,height);cleared=false;frames++;activeMeteors=0;
    meteor(seconds,0,6.4,.18,1.4,alpha);
    meteor(seconds,1,9.1,3.2,1.55,alpha*.72);
  }
  function draw(progress,scale=meteorScale){if(mode!=='intro'||progress<lastProgress)tracks.fill(null);mode='intro';lastProgress=progress;meteorScale=clamp(scale);const t=clamp((progress-.28)/.22);render(progress*6,1-t*t*(3-2*t));}
  function drawOrbit(seconds,alpha=1){if(mode!=='orbit'||seconds<orbitTime)tracks.fill(null);mode='orbit';orbitTime=seconds;meteorScale=1;render(seconds,alpha);}
  function resize(w,h){width=w;height=h;tracks.fill(null);const r=Math.min(devicePixelRatio||1,1.5);canvas.width=Math.round(w*r);canvas.height=Math.round(h*r);ctx?.setTransform(r,0,0,r,0,0);cleared=true;if(mode==='orbit')drawOrbit(orbitTime);else draw(lastProgress);}
  return {draw,drawOrbit,clear,resize,setFlow(value){if(value&&Number.isFinite(value.x)&&Number.isFinite(value.y))flow=value;},dispose:clear,get state(){return {progress:lastProgress,mode,visible:!cleared,frames,reducedMotion,activeMeteors,flow,scale:meteorScale};}};
};
