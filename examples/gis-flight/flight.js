/* Presentation only: no live station data, credentials or control calls. */
(async function () {
  'use strict';
  const $ = id => document.getElementById(id);
  const showError = message => { $('error').hidden = false; $('error').textContent = message; $('loading').hidden = true; };
  if (!window.Cesium) { showError('地球组件未加载，请检查本地资源包。'); return; }
  const C = Cesium;
  C.Ion.defaultAccessToken = '';
  let viewer, imagery, surroundings, earthPortrait, regionalBase, region, timer = 0, progress = 0, playing = false, ready = false;
  let failures = 0;
  let sea;
  let orbital,orbitalTime=0;
  const orbitMotion=window.createGisOrbitMotion();
  let stations;
  let stationReadings = {};
  let stationGeneration = 0;
  let tour, tourEditable=false, tourConfigured=false, idleTimer=0, lastTick=0, lastPhase='idle';
  let cameraFrom, cameraTarget;
  async function loadStations(config, editable) {
    const generation = ++stationGeneration;
    tourEditable=editable;
    if(editable&&tour){stopTour();seek(1);finishIntro();}
    tour?.setStationCount(null);
    if (stations) { stations.dispose(); stations = null; }
    try {
      const layer = await window.createStationLayer(viewer, config, editable);
      if (viewer.isDestroyed() || generation !== stationGeneration) { layer.dispose(); return; }
      stations = layer;
      stations.setReadings(stationReadings);
      tourConfigured=true;
      tour?.setStationCount(stations.tourStops.length);
      updateTourControls();scheduleTour();
    } catch (error) { showError(`站区配置加载失败：${error.message}`); }
  }
  window.addEventListener('message', event => {
    if (event.origin !== location.origin || event.source !== parent || !viewer || viewer.isDestroyed()) return;
    try {
      const data = JSON.parse(event.data);
      if (data.type === 'gis-config') loadStations(data.config, data.editable === true);
      if (data.type === 'gis-readings' && data.readings && typeof data.readings === 'object') {
        stationReadings = data.readings;
        stations?.setReadings(stationReadings);
      }
    } catch { /* Other host messages do not belong to this contract. */ }
  });
  const introSeconds = 6;
  let introComplete = false, introStartedAt = 0, introElapsedMs = 0, returning = false;
  const params = new URLSearchParams(location.search);
  const embedded = params.get('embed') === '1';
  if (embedded) $('embed-link').hidden = true;
  if (params.get('shell') === '1') $('app').classList.add('in-shell');
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const clamp = (v,a,b) => Math.max(a, Math.min(b,v));
  const smooth = v => v*v*(3-2*v);
  const mix = (a,b,t) => a+(b-a)*t;
  let manifest;
  let detailConfig, surroundingsConfig;
  let lastReadout = -Infinity;
  const readoutNodes = Object.fromEntries(['source-title','source-detail'].map(id=>[id,$(id)]));
  const writeText = (id,text) => {if(readoutNodes[id].textContent!==text) readoutNodes[id].textContent=text;};
  // Decorative procedural sky, not an astronomical observation. Draw only on resize.
  const space = $('space'), sky = space.getContext('2d');
  const celestial = window.createCelestialIntro($('celestial'), {reducedMotion:reduceMotion});
  function drawSpace() {
    const width = $('app').clientWidth, height = $('app').clientHeight;
    const ratio = Math.min(devicePixelRatio || 1, 1.5);
    space.width = Math.round(width*ratio); space.height = Math.round(height*ratio);
    sky.setTransform(ratio,0,0,ratio,0,0);
    sky.fillStyle = '#02050c'; sky.fillRect(0,0,width,height);
    let seed = 91357;
    const random = () => {seed = (Math.imul(seed,1664525)+1013904223)>>>0; return seed/4294967296;};
    // Faint, irregular galactic haze, with restrained color rather than neon clouds.
    sky.save(); sky.translate(width*.66,height*.35); sky.rotate(-.48);
    for (let i=0;i<36;i++) {
      const x=(random()-.5)*width*1.8, y=(random()-.5)*height*.32;
      const radius=height*(.09+random()*.2);
      const glow=sky.createRadialGradient(x,y,0,x,y,radius);
      glow.addColorStop(0, i%3 ? 'rgba(55,82,118,.075)' : 'rgba(90,69,116,.065)');
      glow.addColorStop(1,'rgba(0,0,0,0)');
      sky.fillStyle=glow; sky.fillRect(x-radius,y-radius,radius*2,radius*2);
    }
    sky.restore();
    const count=Math.min(2200,Math.round(width*height/800));
    for(let i=0;i<count;i++) {
      const x=random()*width,y=random()*height, bright=random();
      const radius=bright>.992 ? 1.25 : .25+random()*.55;
      sky.fillStyle=`rgba(${bright>.7?'206,222,247':'164,182,209'},${.12+bright*.63})`;
      sky.beginPath();sky.arc(x,y,radius,0,Math.PI*2);sky.fill();
      if(bright>.992){
        const glow=sky.createRadialGradient(x,y,0,x,y,9);
        glow.addColorStop(0,'rgba(158,201,255,.23)');glow.addColorStop(1,'rgba(158,201,255,0)');
        sky.fillStyle=glow;sky.fillRect(x-9,y-9,18,18);
      }
    }
  }
  const skyResize = new ResizeObserver(() => {
    drawSpace();
    celestial.resize($('app').clientWidth,$('app').clientHeight);
    if(ready){viewer.resize();updateReadout(true);viewer.scene.requestRender();}
  });
  skyResize.observe($('app'));
  function pause() {
    playing = false;
    $('app').classList.remove('flying');
    cancelAnimationFrame(timer);
    timer = 0;
    clearTimeout(idleTimer);idleTimer=0;lastTick=0;
  }
  function revealStations() {
    if ($('app').classList.contains('stations-ready')) return;
    $('app').classList.add('stations-ready');
    $('app').dispatchEvent(new Event('stationsready'));
  }
  function finishIntro() {
    playing=false;
    introComplete = true;
    introElapsedMs = introStartedAt ? performance.now()-introStartedAt : 0;
    viewer.scene.screenSpaceCameraController.enableInputs = !tour?.state.enabled;
    revealStations();
    $('app').classList.add('map-ready');
    $('app').dispatchEvent(new Event('mapready'));
  }
  function coverageAlpha(layer, position) {
    // Reveal only after the entire rotated viewport lies inside the feathered
    // footprint. Pure geometry: no per-frame raycasts, masks or postprocessing.
    const lon=C.Math.toDegrees(position.longitude),lat=C.Math.toDegrees(position.latitude);
    const b=layer.bounds, cosine=Math.max(.1,Math.cos(position.latitude));
    const inset=layer.featherMeters*cosine;
    const marginX=Math.min(lon-b[0],b[2]-lon)*111320*cosine-inset;
    const marginY=Math.min(lat-b[1],b[3]-lat)*111320-inset;
    if(marginX<=0||marginY<=0) return 0;
    const halfY=position.height*Math.tan(viewer.camera.frustum.fovy/2);
    const halfX=halfY*viewer.camera.frustum.aspectRatio;
    const cs=Math.abs(Math.cos(viewer.camera.heading)),sn=Math.abs(Math.sin(viewer.camera.heading));
    const fit=Math.max((cs*halfX+sn*halfY)/marginX,(sn*halfX+cs*halfY)/marginY);
    return smooth(clamp((1-fit)/.3,0,1));
  }
  function updateReadout(force=false) {
    orbital?.update(orbitalTime,!reduceMotion);
    if(orbital)celestial.setFlow(orbital.flow);
    const h = viewer.camera.positionCartographic.height;
    const position = viewer.camera.positionCartographic;
    imagery.alpha = coverageAlpha(detailConfig,position);
    surroundings.alpha = coverageAlpha(surroundingsConfig,position);
    regionalBase.alpha = coverageAlpha(region,position);
    // Once a complete opaque footprint fills the view, skip covered base layers.
    // Keep the lower layer throughout a fade; complementary alpha would cause holes.
    surroundings.show = imagery.alpha<1;
    regionalBase.show = surroundings.alpha<1 && imagery.alpha<1;
    // Always retain the global fallback while newly visible local tiles stream.
    earthPortrait.show = true;
    if(sea) sea.update();
    // Keep the global photograph underneath throughout: no flat-color gap.
    // UI updates at 10 Hz; camera and layer opacity still follow each frame.
    const now=performance.now();
    if(!force && now-lastReadout<100) return;
    lastReadout=now;
    const detail = imagery.alpha>.5, regional=surroundings.alpha>.5;
    writeText('source-title',detail?'站区卫星影像':regional?'大连 · 低清背景':regionalBase.alpha>.5?'辽东 · 地形概览':h>3900000?'地球 · 太空视角':'区域 · 地理底图');
    writeText('source-detail',detail?`${manifest.acquired} · Sentinel-2 原始 10 m`:regional?'Sentinel-2 · 降采样约 120 m':'NASA Blue Marble · 2004 年合成影像');
  }
  function seek(value) {
    progress = clamp(value,0,1);
    // Beta(3,4) integral: continuous velocity/acceleration, earlier regional
    // arrival, longer controlled approach. Work in log altitude across scales.
    const t = progress**3*(20+progress*(-45+progress*(36-10*progress)));
    // Align with the regional imagery before descending below its footprint.
    const c = smooth(clamp(progress/0.44,0,1));
    const height = Math.exp(mix(Math.log(24000000), Math.log(18500), t));
    celestial.draw(progress,(height/24000000)**.65);
    // Positive camera heading turns the map counterclockwise: north ends at left.
    const turn = t;
    viewer.camera.setView({destination:C.Cartesian3.fromDegrees(mix(102,manifest.center[0],c),mix(20,manifest.center[1],c),height),orientation:{heading:Math.PI/2*turn,pitch:-Math.PI/2,roll:0}});
    updateReadout(!playing || progress===1);
    if (progress >= .9) revealStations();
    viewer.scene.requestRender();
  }
  function readCamera(){const p=viewer.camera.positionCartographic;return {lon:C.Math.toDegrees(p.longitude),lat:C.Math.toDegrees(p.latitude),height:p.height,heading:viewer.camera.heading};}
  const shortestAngle=(from,to,period)=>(to-from+period*1.5)%period-period*.5;
  function setCamera(lon,lat,height,heading){
    viewer.camera.setView({destination:C.Cartesian3.fromDegrees(lon,lat,height),orientation:{heading,pitch:-Math.PI/2,roll:0}});
    updateReadout();viewer.scene.requestRender();
  }
  function updateTourControls(){
    if(!tour)return;
    const s=tour.state;
    $('app').classList.toggle('tour-running',s.enabled);
    $('tour-controls').hidden=false;
    $('tour-toggle').hidden=tourEditable;
    const staticActive=s.enabled&&s.mode==='static';
    const label=staticActive?'暂停静态展示':'静态展示：地图浮窗轮播';
    $('tour-toggle').setAttribute('aria-label',label);
    $('tour-toggle').setAttribute('aria-pressed',String(staticActive));
    $('tour-toggle').title=label;
    $('tour-toggle').querySelector('.mode-mark').setAttribute('d',staticActive?'M16 14v6m4-6v6':'M16 13l5 4-5 4z');
    const demoLabel=tourEditable?'重置地图视角':'演示模式：地球与地图循环';
    $('replay').setAttribute('aria-label',demoLabel);
    $('replay').title=demoLabel;
    $('replay').setAttribute('aria-pressed',String(!tourEditable&&s.enabled&&s.mode==='demo'));
  }
  function tourPhase(s){
    if(lastPhase==='intro'&&progress>=1)finishIntro();
    lastPhase=s.phase;
    playing=['intro','approach','travel','return','orbit'].includes(s.phase);
    returning=s.phase==='return';
    $('app').classList.toggle('flying',playing);
    viewer.scene.screenSpaceCameraController.enableInputs=s.phase==='idle';
    if(s.phase==='intro'){
      introComplete=false;introStartedAt=performance.now();
      $('app').classList.remove('stations-ready','map-ready','tour-away');
      $('celestial').style.opacity='1';
    }
    if(s.phase==='approach'||s.phase==='travel'||s.phase==='return'){
      stations?.releaseTour({hide:true});
      cameraFrom=readCamera();
      const stop=stations?.tourStops[s.index];
      cameraTarget=s.phase==='return'?{lon:102,lat:20,height:24000000,heading:0}:
        {lon:stop?.longitude??manifest.center[0],lat:stop?.latitude??manifest.center[1],height:18500,heading:Math.PI/2};
      if(s.phase==='approach'){
        $('app').classList.remove('tour-away');
        $('celestial').style.opacity='1';
      }
      if(s.phase==='return'){
        $('app').classList.add('tour-away');
        $('celestial').style.opacity='0';
      }
    }
    if(s.phase==='station')stations?.showTour(s.index);
    if(s.phase==='orbit'){
      $('app').classList.remove('stations-ready','map-ready');
      $('celestial').style.opacity='1';
    }
    if(s.phase==='idle'){
      stations?.releaseTour();
      $('app').classList.remove('tour-away');
    }
    updateTourControls();
  }
  function tourFrame(s){
    if(s.phase==='intro')seek(s.progress);
    else if(s.phase==='approach'||s.phase==='travel'||s.phase==='return'){
      const t=smooth(s.progress),a=cameraFrom,b=cameraTarget;
      setCamera(a.lon+shortestAngle(a.lon,b.lon,360)*t,mix(a.lat,b.lat,t),Math.exp(mix(Math.log(Math.max(5000,a.height)),Math.log(b.height),t)),a.heading+shortestAngle(a.heading,b.heading,Math.PI*2)*t);
      if(s.phase==='approach'){
        const h=viewer.camera.positionCartographic.height;
        progress=clamp(1-Math.log(Math.max(18500,h)/18500)/Math.log(24000000/18500),0,1);
        celestial.draw(progress,(h/24000000)**.65);
        if(s.progress>=1){progress=1;finishIntro();}
      }
      if(s.phase==='return'&&s.elapsed>.4)celestial.clear();
    } else if(s.phase==='orbit'){
      setCamera(102+360*orbitMotion.at(s.elapsed).turn,20,24000000,0);
      const fade=smooth(clamp(Math.min(s.elapsed/.8,(s.duration-s.elapsed)/.8),0,1));
      celestial.drawOrbit(s.elapsed,fade);
    }
  }
  function queueTour(){
    if(document.hidden||!tour||tour.state.phase==='idle')return;
    if(['station','empty','waiting'].includes(tour.state.phase))idleTimer=setTimeout(()=>tickTour(performance.now()),100);
    else timer=requestAnimationFrame(tickTour);
  }
  function tickTour(now){
    timer=0;idleTimer=0;
    if(document.hidden||!tour)return;
    if(tour.state.phase==='orbit'&&lastTick&&now-lastTick<32){queueTour();return;}
    const elapsed=lastTick?Math.min((now-lastTick)/1000,.1):0;
    lastTick=now;orbitalTime+=elapsed;tour.advance(elapsed);queueTour();
  }
  function scheduleTour(){cancelAnimationFrame(timer);clearTimeout(idleTimer);timer=0;idleTimer=0;lastTick=0;queueTour();}
  function stopTour(){
    if(!tour)return;
    tour.stop();pause();
    // Keep the camera still; decoration dissolves instead of following manual pans.
    $('celestial').style.opacity='0';
    viewer.scene.screenSpaceCameraController.enableInputs=true;
    updateTourControls();
  }
  function approachDuration(target){
    const a=readCamera(),angle=Math.hypot(shortestAngle(a.lon,target.lon,360)*Math.cos(a.lat*Math.PI/180),a.lat-target.lat);
    const zoom=Math.abs(Math.log(Math.max(5000,a.height)/target.height)),turn=Math.abs(shortestAngle(a.heading,target.heading,Math.PI*2));
    if(angle<.0008&&zoom<.01&&turn<.01)return 0;
    return Math.min(2,Math.max(.18,zoom*.22+angle*.006+turn*.08));
  }
  function replay(){if(!ready)return;tour.reset({duration:approachDuration({lon:manifest.center[0],lat:manifest.center[1],height:18500,heading:Math.PI/2})});scheduleTour();}
  function playNearest(){
    const a=readCamera(),stops=stations?.tourStops||[];
    let index=0,best=Infinity;
    stops.forEach((stop,i)=>{const distance=Math.hypot(shortestAngle(a.lon,stop.longitude,360)*Math.cos(a.lat*Math.PI/180),a.lat-stop.latitude);if(distance<best){best=distance;index=i;}});
    const target=stops[index];
    tour.startNear(index,{duration:approachDuration({lon:target?.longitude??manifest.center[0],lat:target?.latitude??manifest.center[1],height:18500,heading:Math.PI/2})});scheduleTour();
  }
  try {
    const response = await fetch('imagery/manifest.json');
    if (!response.ok) throw new Error('缺少庄河影像清单');
    manifest = await response.json();
    detailConfig=manifest.layers.find(l=>l.id==='zhuanghe');
    surroundingsConfig=manifest.layers.find(l=>l.id==='dalian');
    const regionResponse=await fetch('imagery/region-source.json');
    if(!regionResponse.ok) throw new Error('缺少辽东过渡影像清单');
    region=await regionResponse.json();
    viewer = new C.Viewer('globe', {
      baseLayer:false, baseLayerPicker:false, geocoder:false, homeButton:false,
      sceneModePicker:false, navigationHelpButton:false, animation:false, timeline:false,
      fullscreenButton:false, infoBox:false, selectionIndicator:false,
      terrainProvider:new C.EllipsoidTerrainProvider(), requestRenderMode:true,
      maximumRenderTimeChange:Infinity, creditContainer:$('credits'),
      // Weighted OIT drops the lunar sphere on Edge/ANGLE D3D11 (RTX 4060).
      // Sorted alpha blending keeps its fade and ordinary Earth depth occlusion.
      orderIndependentTranslucency:false,
      contextOptions:{webgl:{alpha:true}},
    });
    viewer.resolutionScale = Math.min(1, 1.5/(window.devicePixelRatio||1));
    viewer.scene.backgroundColor = C.Color.TRANSPARENT;
    viewer.scene.skyBox.show = false;
    viewer.scene.globe.baseColor = C.Color.fromCssColorString('#142e42');
    viewer.scene.globe.enableLighting = true;
    viewer.scene.globe.lightingFadeOutDistance = 3000000;
    viewer.scene.globe.lightingFadeInDistance = 10000000;
    viewer.scene.light = new C.DirectionalLight({direction:C.Cartesian3.normalize(C.Cartesian3.negate(C.Cartesian3.fromDegrees(62,35),new C.Cartesian3()),new C.Cartesian3()),intensity:1.6});
    orbital=await window.createOrbitalScene(viewer);
    viewer.scene.globe.maximumScreenSpaceError = 2;
    viewer.scene.globe.tileCacheSize = 150;
    viewer.scene.screenSpaceCameraController.minimumZoomDistance = 5000;
    viewer.scene.screenSpaceCameraController.maximumZoomDistance = 40000000;
    viewer.scene.screenSpaceCameraController.enableTilt = false;
    viewer.scene.skyAtmosphere.show = true;
    viewer.scene.sun.show = false;
    viewer.scene.moon.show = false;
    viewer.scene.fog.enabled = false;
    const credit = new C.Credit('NASA Blue Marble (2004)',true);
    const portrait = await C.SingleTileImageryProvider.fromUrl('imagery/earth-portrait.jpg',{credit});
    earthPortrait = viewer.imageryLayers.addImageryProvider(portrait);
    earthPortrait.saturation = .85;
    earthPortrait.contrast = 1.08;
    const regionalProvider=await C.SingleTileImageryProvider.fromUrl(region.url,{
      rectangle:C.Rectangle.fromDegrees(...region.bounds),credit,
    });
    regionalBase=viewer.imageryLayers.addImageryProvider(regionalProvider);
    regionalBase.saturation=.85;
    regionalBase.contrast=1.08;
    for (const layer of manifest.layers) {
      const provider = new C.UrlTemplateImageryProvider({
        url:`imagery/${layer.id}/{z}/{x}/{y}.webp`, rectangle:C.Rectangle.fromDegrees(...layer.bounds),
        tilingScheme:new C.WebMercatorTilingScheme(), minimumLevel:layer.minZoom,
        maximumLevel:layer.maxZoom, credit:new C.Credit('Contains modified Copernicus Sentinel data (2025)',true),
        enablePickFeatures:false,
      });
      provider.errorEvent.addEventListener(() => {
        failures++;
        if (failures >= 3) showError('部分本地卫星瓦片无法读取，请检查资源包完整性后刷新。');
      });
      const rendered = viewer.imageryLayers.addImageryProvider(provider);
      if(layer.id === 'dalian') surroundings = rendered; else imagery = rendered;
    }
    viewer.camera.changed.addEventListener(() => {if(!playing) updateReadout(true);});
    viewer.scene.preRender.addEventListener(() => {if(returning) updateReadout();});
    viewer.scene.renderError.addEventListener((scene,error) => {stopTour();showError('三维画面渲染失败，请检查浏览器 WebGL 支持。');console.error(error);});
    viewer.screenSpaceEventHandler.removeInputAction(C.ScreenSpaceEventType.LEFT_DOUBLE_CLICK);
    $('replay').addEventListener('click',()=>{if(tourEditable)replay();else{tour.startDemo();scheduleTour();}});
    $('tour-toggle').addEventListener('click',()=>{if(tour.state.enabled&&tour.state.mode==='static')stopTour();else playNearest();});
    // Pointer-down is deliberate takeover; hover alone does not disrupt a tour.
    $('app').addEventListener('pointerdown',event=>{if(tour?.state.enabled&&!event.target.closest('#tour-controls,#replay'))stopTour();},true);
    $('app').addEventListener('keydown',event=>{if(event.key==='Escape'&&tour?.state.enabled)stopTour();});
    document.addEventListener('visibilitychange', () => {
      tour?.suspend(document.hidden);
      if(document.hidden){cancelAnimationFrame(timer);clearTimeout(idleTimer);timer=0;idleTimer=0;lastTick=0;}
      else if(ready){if(tour.state.phase==='station')stations?.showTour(tour.state.index);scheduleTour();}
    });
    window.addEventListener('pagehide', () => {pause();skyResize.disconnect();celestial.dispose();orbital?.dispose();if(stations) stations.dispose();if(sea) sea.dispose();if(!viewer.isDestroyed()) viewer.destroy();});
    tour=window.createGisTour({onPhase:tourPhase,onFrame:tourFrame,reducedMotion:reduceMotion,orbitDuration:orbitMotion.duration});
    seek(reduceMotion?1:0);
    ready = true;
    $('replay').disabled = false;
    $('tour-toggle').disabled = false;
    viewer.scene.screenSpaceCameraController.enableInputs = false;
    $('loading').hidden = true;
    // Read-only diagnostics support acceptance without a hidden control channel.
    window.gisDemo = {get state(){const center=C.SceneTransforms.worldToWindowCoordinates(viewer.scene,C.Cartesian3.fromDegrees(...manifest.center));const north=C.SceneTransforms.worldToWindowCoordinates(viewer.scene,C.Cartesian3.fromDegrees(manifest.center[0],manifest.center[1]+.01));return {ready,progress,playing,returning,failures,longitude:C.Math.toDegrees(viewer.camera.positionCartographic.longitude),latitude:C.Math.toDegrees(viewer.camera.positionCartographic.latitude),height:viewer.camera.positionCartographic.height,headingDegrees:C.Math.toDegrees(viewer.camera.heading),northScreenDelta:center&&north?{x:north.x-center.x,y:north.y-center.y}:null,tilesLoaded:viewer.scene.globe.tilesLoaded,imageryDate:manifest.acquired,center:manifest.center,cesium:C.VERSION,celestial:celestial.state,orbital:orbital?.state,sea:sea?.state,stations:stations?.state,tour:tour?.state,tourEditable,tourConfigured,introSeconds,introComplete,introElapsedMs};}};
    // Water is optional: failure must leave the existing flight usable.
    window.createZhuangheSea(viewer,{reducedMotion:reduceMotion}).then(effect=>{
      if(viewer.isDestroyed()){effect.dispose();return;}
      sea=effect;sea.update();viewer.scene.requestRender();
    }).catch(error=>{
      console.warn('海面资源未加载，地图与飞行仍可使用',error);
    });
    if(params.get('autoplay')==='0'){seek(1);finishIntro();updateTourControls();}
    else {tour.start({fromGlobe:true});tour.suspend(document.hidden);scheduleTour();}
    if (params.get('shell') === '1') parent.postMessage(JSON.stringify({type:'gis-ready'}),location.origin);
    else loadStations(null, false);
  } catch (error) {
    pause(); showError(`演示加载失败：${error.message}`); console.error(error);
  }
})();
