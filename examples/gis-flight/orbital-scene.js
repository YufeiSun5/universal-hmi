/* Art-directed orbital distances and speeds. No ephemeris or telemetry. */
'use strict';
window.createOrbitalScene = async function(viewer) {
  const C=Cesium,scene=viewer.scene;
  const load=src=>new Promise((resolve,reject)=>{const im=new Image();im.onload=()=>resolve(im);im.onerror=()=>reject(new Error(`无法读取太空贴图：${src}`));im.src=src;});
  const [moonImage,satelliteSource,normalSource]=await Promise.all([load('moon-lroc-2k.jpg'),load('satellite-v2.png'),load('satellite-normal.png')]);
  if(viewer.isDestroyed())return {update(){},dispose(){},state:{disposed:true}};
  // Small on-screen spacecraft need only a bounded GPU texture. Keep original
  // assets on disk, prepare each map once, never allocate textures per frame.
  function spriteTexture(source){const canvas=document.createElement('canvas');canvas.width=512;canvas.height=256;canvas.getContext('2d').drawImage(source,0,0,512,256);return canvas;}
  const satelliteImage=spriteTexture(satelliteSource),normalImage=spriteTexture(normalSource);
  const smooth=v=>{v=Math.max(0,Math.min(1,v));return v*v*(3-2*v);};
  const forward=C.Cartesian3.normalize(C.Cartesian3.fromDegrees(102,20),new C.Cartesian3());
  const right=C.Cartesian3.normalize(C.Cartesian3.cross(C.Cartesian3.UNIT_Z,forward,new C.Cartesian3()),new C.Cartesian3());
  const up=C.Cartesian3.normalize(C.Cartesian3.cross(forward,right,new C.Cartesian3()),new C.Cartesian3());
  function position(angle,radius,inclination){
    const x=Math.cos(angle)*radius,z=Math.sin(angle)*radius;
    return new C.Cartesian3(right.x*x+(forward.x*Math.cos(inclination)+up.x*Math.sin(inclination))*z,
      right.y*x+(forward.y*Math.cos(inclination)+up.y*Math.sin(inclination))*z,
      right.z*x+(forward.z*Math.cos(inclination)+up.z*Math.sin(inclination))*z);
  }
  const material=new C.Material({fabric:{type:'LunarSurface',uniforms:{image:moonImage,opacity:0},source:`
    czm_material czm_getMaterial(czm_materialInput materialInput) {
      czm_material m=czm_getDefaultMaterial(materialInput);
      // Cesium's +X seam is s=0; the LROC near side is centered at s=.5.
      vec3 texel=texture(image,vec2(fract(materialInput.st.s+.5),materialInput.st.t)).rgb;
      float gray=dot(texel,vec3(.2126,.7152,.0722));
      vec3 color=pow(vec3(clamp((gray-.5)*1.15+.5,0.0,1.0)),vec3(.8));
      // Presentation moon: a gentle gibbous phase keeps a visible terminator.
      // Eye-space art light leaves Earth/world sunlight and satellite glints alone.
      vec3 lunarLight=normalize(vec3(-.75,.16,.64));
      float sunlight=max(dot(normalize(materialInput.normalEC),lunarLight),0.0);
      m.diffuse=vec3(0.0);
      m.emission=color*(.025+.90*sunlight);
      m.specular=0.0;
      m.alpha=opacity;
      return m;
    }`},translucent:true});
  const moon=scene.primitives.add(new C.Primitive({
    geometryInstances:new C.GeometryInstance({geometry:new C.EllipsoidGeometry({radii:new C.Cartesian3(1350000,1350000,1350000),stackPartitions:40,slicePartitions:64,vertexFormat:C.MaterialAppearance.MaterialSupport.TEXTURED.vertexFormat})}),
    appearance:new C.MaterialAppearance({material,materialSupport:C.MaterialAppearance.MaterialSupport.TEXTURED,translucent:true,closed:true,faceForward:false}),
    asynchronous:false,allowPicking:false,show:false,
  }));
  const satellites=Array.from({length:3},()=>{
    const surface=new C.Material({fabric:{type:'SatelliteReflection',uniforms:{image:satelliteImage,normalMap:normalImage,opacity:0,halfVector:new C.Cartesian3(0,0,1)},source:`
      czm_material czm_getMaterial(czm_materialInput materialInput) {
        czm_material m=czm_getDefaultMaterial(materialInput);
        vec4 albedo=texture(image,materialInput.st);
        vec3 n=normalize(texture(normalMap,materialInput.st).rgb*2.0-1.0);
        float highlight=pow(max(dot(n,normalize(halfVector)),0.0),40.0);
        m.diffuse=vec3(0.0);
        m.emission=albedo.rgb*(0.65+highlight*1.8)+vec3(highlight*.35);
        m.alpha=albedo.a*opacity;
        return m;
      }`},translucent:true});
    const primitive=scene.primitives.add(new C.Primitive({geometryInstances:new C.GeometryInstance({geometry:new C.PlaneGeometry({vertexFormat:C.MaterialAppearance.MaterialSupport.TEXTURED.vertexFormat})}),appearance:new C.MaterialAppearance({material:surface,materialSupport:C.MaterialAppearance.MaterialSupport.TEXTURED,translucent:true,closed:false,faceForward:false}),asynchronous:false,allowPicking:false,show:false}));
    return {primitive,surface,glint:0};
  });
  const lunarOrbitRadius=19000000;
  const paths=scene.primitives.add(new C.PolylineCollection());
  const path=paths.add({positions:Array.from({length:25},(_,i)=>position(-Math.PI/2-.6+i/24*.44,lunarOrbitRadius,.15)),width:1,
    material:C.Material.fromType('Color',{color:new C.Color(.5,.65,.8,0)}),show:false});
  let seconds=0,alpha=0,draws=0,disposed=false,moonPosition,spaceStart=0,flow={x:-1,y:.25};
  function update(time,enabled=true){
    if(disposed||viewer.isDestroyed())return;
    seconds=time;
    alpha=enabled?smooth((viewer.camera.positionCartographic.height-2500000)/9500000):0;
    const visible=alpha>.001;
    moon.show=visible;path.show=visible;
    satellites.forEach(s=>s.primitive.show=visible);
    if(!visible){spaceStart=time;return;}
    draws++;
    // Begin beside the globe: starting directly behind Earth hid the Moon
    // throughout the short opening flight. The same continuous world orbit
    // still carries it behind Earth and beyond the viewport later in the tour.
    const angle=-.7+(seconds-spaceStart)*.12;
    moonPosition=position(angle,lunarOrbitRadius,.15);
    // One continuous world-space path; no screen-coordinate easing or reversal.
    // Keep the familiar near side (LROC longitude 0, texture center) facing
    // the audience, with lunar north up. Orbital travel must not spin the
    // visible face into the unfamiliar far-side crater field.
    const lunarFront=C.Cartesian3.normalize(C.Cartesian3.subtract(viewer.camera.positionWC,moonPosition,new C.Cartesian3()),new C.Cartesian3());
    const lunarRight=C.Cartesian3.normalize(C.Cartesian3.cross(viewer.camera.upWC,lunarFront,new C.Cartesian3()),new C.Cartesian3());
    const lunarNorth=C.Cartesian3.cross(lunarFront,lunarRight,new C.Cartesian3());
    const rotation=new C.Matrix3();
    C.Matrix3.setColumn(rotation,0,lunarFront,rotation);
    C.Matrix3.setColumn(rotation,1,lunarRight,rotation);
    C.Matrix3.setColumn(rotation,2,lunarNorth,rotation);
    const distance=C.Cartesian3.distance(viewer.camera.positionWC,moonPosition);
    const lunarScale=.63*Math.min(1,distance/24000000);
    moon.modelMatrix=C.Matrix4.multiplyByUniformScale(C.Matrix4.fromRotationTranslation(rotation,moonPosition,new C.Matrix4()),lunarScale,new C.Matrix4());
    material.uniforms.opacity=alpha;
    path.positions=Array.from({length:25},(_,i)=>position(angle-.6+i/24*.44,lunarOrbitRadius,.15));
    path.material.uniforms.color.alpha=alpha*.11;
    const sun=C.Cartesian3.negate(scene.light.direction,new C.Cartesian3());
    const occluder=new C.EllipsoidalOccluder(C.Ellipsoid.WGS84,viewer.camera.positionWC);
    let flowScore=-1;
    satellites.forEach((sat,i)=>{
      const p=position(seconds*(.12+i*.022)+i*2.2+.9,8500000+i*430000,(i-1)*.65);
      sat.position=p;
      const towardCamera=C.Cartesian3.normalize(C.Cartesian3.subtract(viewer.camera.positionWC,p,new C.Cartesian3()),new C.Cartesian3());
      const half=C.Cartesian3.normalize(C.Cartesian3.add(sun,towardCamera,new C.Cartesian3()),new C.Cartesian3());
      const spin=seconds*.14+i*1.9;
      const panel=C.Cartesian3.normalize(new C.Cartesian3(right.x*Math.cos(spin)+forward.x*Math.sin(spin),right.y*Math.cos(spin)+forward.y*Math.sin(spin),right.z*Math.cos(spin)+forward.z*Math.sin(spin)),new C.Cartesian3());
      const alignment=Math.abs(C.Cartesian3.dot(panel,half));
      const along=C.Cartesian3.dot(p,sun);
      const shadowDistance=Math.sqrt(Math.max(0,C.Cartesian3.magnitudeSquared(p)-along*along));
      const sunlight=along>=0?1:smooth((shadowDistance-6371000)/350000);
      // Broad, gradual reflection window lets the spacecraft remain readable
      // through a pass; darkness and Earth occlusion still hide it naturally.
      sat.glint=smooth((alignment-.60)/.34)*sunlight;
      if(occluder.isPointVisible(p)&&sat.glint>flowScore){
        const a=C.SceneTransforms.worldToWindowCoordinates(scene,p);
        const ahead=position((seconds+.3)*(.12+i*.022)+i*2.2+.9,8500000+i*430000,(i-1)*.65);
        const b=C.SceneTransforms.worldToWindowCoordinates(scene,ahead);
        if(a&&b){const dx=b.x-a.x,dy=b.y-a.y,len=Math.hypot(dx,dy);if(len>1){flow={x:dx/len,y:dy/len};flowScore=sat.glint;}}
      }
      sat.surface.uniforms.opacity=alpha*sat.glint;
      const tangent=C.Cartesian3.normalize(C.Cartesian3.cross(C.Cartesian3.UNIT_Z,panel,new C.Cartesian3()),new C.Cartesian3());
      const bitangent=C.Cartesian3.cross(panel,tangent,new C.Cartesian3());
      sat.surface.uniforms.halfVector=new C.Cartesian3(C.Cartesian3.dot(half,tangent),C.Cartesian3.dot(half,bitangent),alignment);
      const basis=new C.Matrix3();
      C.Matrix3.setColumn(basis,0,viewer.camera.rightWC,basis);
      C.Matrix3.setColumn(basis,1,viewer.camera.upWC,basis);
      C.Matrix3.setColumn(basis,2,towardCamera,basis);
      const matrix=C.Matrix4.fromRotationTranslation(basis,p,new C.Matrix4());
      sat.primitive.modelMatrix=C.Matrix4.multiplyByScale(matrix,new C.Cartesian3(1100000,550000,1),new C.Matrix4());
    });
    scene.requestRender();
  }
  return {update,get flow(){return flow;},
    get state(){const p=moonPosition&&C.SceneTransforms.worldToWindowCoordinates(scene,moonPosition);const occluder=new C.EllipsoidalOccluder(C.Ellipsoid.WGS84,viewer.camera.positionWC);return {seconds,alpha,draws,ready:true,moonWorld:moonPosition,moonScreen:p,satelliteCount:3,glints:satellites.map(s=>s.glint),satellites:satellites.map(s=>({screen:s.position&&C.SceneTransforms.worldToWindowCoordinates(scene,s.position),unoccluded:!!s.position&&occluder.isPointVisible(s.position),opacity:alpha*s.glint})),normalMapped:true,texture:'NASA LROC 2048x1024'};},
    dispose(){if(disposed)return;disposed=true;if(!viewer.isDestroyed()){scene.primitives.remove(moon);satellites.forEach(s=>scene.primitives.remove(s.primitive));scene.primitives.remove(paths);}},
  };
};

