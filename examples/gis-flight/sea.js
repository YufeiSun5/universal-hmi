/* Decorative sea shading; no live waves, tide or weather claims. */
window.createZhuangheSea = async function(viewer, {reducedMotion=false}={}) {
  const C=Cesium;
  const response=await fetch('imagery/water-source.json');
  if(!response.ok) throw new Error('海面资源清单不可用');
  const config=await response.json();
  // Decode before adding the primitive, so texture load failure can gracefully
  // disable this optional effect without affecting the map or flight.
  const [mask,normal]=await Promise.all([config.url,config.normalUrl].map(async url=>{
    const image=new Image();image.src=url;await image.decode();return image;
  }));
  if(viewer.isDestroyed()) throw new Error('地图已关闭');
  const material=new C.Material({fabric:{
    type:'ZhuangheCoastalSea',
    uniforms:{seaMask:mask,waveNormal:normal,seconds:0.0,amount:0.0},
    source:`
      czm_material czm_getMaterial(czm_materialInput mi) {
        czm_material m=czm_getDefaultMaterial(mi);
        vec2 uv=mi.st;
        float coast=texture(seaMask,uv).r;
        if(coast<0.004 || amount<0.001) discard;
        vec2 p=uv*vec2(19.0,14.0);
        vec2 a=texture(waveNormal,fract(p+vec2(seconds*0.006,seconds*0.002))).rg*2.0-1.0;
        vec2 b=texture(waveNormal,fract(p*1.73+vec2(-seconds*0.0035,seconds*0.0038)+0.37)).rg*2.0-1.0;
        // Slow broad swells change the glint envelope while small ripples flow
        // across it, so the destination stays alive after the flight has ended.
        vec2 swell=vec2(sin(dot(p,vec2(.7,.43))+seconds*.42+a.y*.6),
                        cos(dot(p,vec2(-.36,.61))-seconds*.31+b.x*.6));
        vec2 slope=a*0.65+b*0.35+swell*.12;
        // Gentle sun glints with a broad directional lobe. No neon coastline,
        // large sine bands, white surf stripes or screen-space scrolling sheet.
        float detail=1.0-smoothstep(2.0,7.0,length(fwidth(p))*512.0);
        vec3 n=normalize(vec3(slope*0.38*detail,1.0));
        vec3 toEye=normalize(transpose(mi.tangentToEyeMatrix)*mi.positionToEyeEC);
        vec3 halfLight=normalize(toEye+normalize(vec3(.35,-.45,.82)));
        float glint=pow(max(dot(n,halfLight),0.0),95.0);
        vec3 deep=vec3(.025,.125,.17);
        vec3 sheen=vec3(.56,.72,.72);
        m.diffuse=mix(deep,sheen,glint*.75);
        m.alpha=coast*amount*(.16+glint*.38);
        return m;
      }`,
  },translucent:()=>true});
  const primitive=viewer.scene.primitives.add(new C.Primitive({
    geometryInstances:new C.GeometryInstance({geometry:new C.RectangleGeometry({
      rectangle:C.Rectangle.fromDegrees(...config.bounds),height:8,
      granularity:C.Math.toRadians(.025),vertexFormat:C.EllipsoidSurfaceAppearance.VERTEX_FORMAT,
    })}),
    appearance:new C.EllipsoidSurfaceAppearance({material,flat:true,aboveGround:true,translucent:true}),
    asynchronous:false,allowPicking:false,show:false,
  }));
  const enabled=true;
  let visible=false,disposed=false,handle=0,last=0,time=0,draws=0;
  const motionQuery=matchMedia('(prefers-reduced-motion: reduce)');
  let motionReduced=reducedMotion;
  function animate(now) {
    handle=0;
    if(disposed || !visible || document.hidden || motionReduced) {last=0;return;}
    // 30 Hz water update ceiling; flight rendering retains its existing cadence.
    if(!last || now-last>=32){
      if(last) time+=Math.min((now-last)/1000,.1);
      last=now;material.uniforms.seconds=time;draws++;viewer.scene.requestRender();
    }
    handle=requestAnimationFrame(animate);
  }
  function schedule(){
    if(visible && !document.hidden && !motionReduced && !handle) handle=requestAnimationFrame(animate);
    else if(!visible || document.hidden || motionReduced){cancelAnimationFrame(handle);handle=0;last=0;}
  }
  function update(){
    if(disposed) return;
    const p=viewer.camera.positionCartographic;
    const lon=C.Math.toDegrees(p.longitude),lat=C.Math.toDegrees(p.latitude),b=config.bounds;
    const inArea=lon>b[0]&&lon<b[2]&&lat>b[1]&&lat<b[3];
    const t=Math.max(0,Math.min(1,(85000-p.height)/50000));
    material.uniforms.amount=enabled&&inArea?t*t*(3-2*t):0;
    visible=material.uniforms.amount>.001;
    primitive.show=visible;
    schedule();
  }
  function visibility(){last=0;schedule();}
  function reduce(event){motionReduced=event.matches;visibility();}
  document.addEventListener('visibilitychange',visibility);
  motionQuery.addEventListener('change',reduce);
  update();
  return {update,get state(){return {enabled,visible,animated:!!handle,time,draws,ready:primitive.ready,amount:material.uniforms.amount};},
    dispose(){disposed=true;cancelAnimationFrame(handle);
      document.removeEventListener('visibilitychange',visibility);motionQuery.removeEventListener('change',reduce);
      if(!viewer.isDestroyed()) viewer.scene.primitives.remove(primitive);
    }};
};
