/* Station presentation adapter: no polling, credentials, or equipment control. */
window.createStationLayer = async function(viewer, suppliedConfig, editable=false) {
  const C=Cesium, root=document.getElementById('app');
  const runtimeView=new URLSearchParams(location.search).get('shell')==='1';
  root.classList.toggle('gis-editing',editable);
  let config;
  if(suppliedConfig) config={schemaVersion:1,placement:'configured',...suppliedConfig};
  else {
    const response=await fetch('stations.json');
    if(!response.ok) throw new Error('站区配置加载失败');
    config=await response.json();
  }
  if(config.schemaVersion!==1 || !Array.isArray(config.stations) || config.stations.length>100) throw new Error('站区配置格式无效');
  const ids=new Set();
  for(const s of config.stations){
    if(typeof s.id!=='string'||!s.id||ids.has(s.id)||typeof s.name!=='string'||!s.name||!validPosition(s.longitude,s.latitude)) throw new Error('站区名称、标识或坐标无效');
    ids.add(s.id);
    if(s.zones!==undefined){
      if(!Array.isArray(s.zones)||s.zones.length>16)throw new Error('分区配置无效');
      const zones=new Set();
      for(const z of s.zones){if(typeof z.id!=='string'||!z.id||zones.has(z.id)||typeof z.name!=='string'||!z.name.trim())throw new Error('分区名称或标识无效');zones.add(z.id);}
    }
  }
  if(viewer.isDestroyed()) throw new Error('地图已关闭');
  const layer=document.createElement('div');layer.id='station-overlay';layer.setAttribute('aria-label','站区位置');
  const card=document.createElement('section');card.id='station-card';card.hidden=true;
  card.setAttribute('role','region');card.setAttribute('aria-label','站区概况');
  const hint=document.createElement('div');hint.id='station-hint';hint.textContent=config.placement==='illustrative'?(runtimeView?'站区示意 · 悬浮查看':'站区示意 · 拖动调整位置 / 悬浮查看'):'悬浮查看站区概况';hint.setAttribute('role','status');hint.hidden=true;
  root.append(layer,card,hint);
  const storageKey='universal-hmi.gis.demo-station-positions.v1';
  let saved={};
  if(!runtimeView) try {const value=JSON.parse(localStorage.getItem(storageKey)||'{}');if(value&&typeof value==='object'&&!Array.isArray(value))saved=value;}catch { /* Browser storage is optional for this visual demo. */ }
  let active=null,closeTimer=0,entranceTimer=0,entrancePlayed=false,lastKey='',disposed=false;
  let touring=false,hideTimer=0,revealFrame=0;
  let drag=null;
  let readings={};
  const positions=new Map();
  const stations=config.stations.map((source,index)=>{
    const s={...source,original:[source.longitude,source.latitude]};
    const override=saved[s.id];
    if(config.placement==='illustrative'&&override&&validPosition(override.longitude,override.latitude))Object.assign(s,{longitude:override.longitude,latitude:override.latitude});
    s.world=C.Cartesian3.fromDegrees(s.longitude,s.latitude,20);
    const button=document.createElement('button');button.className='station-marker';button.type='button';
    button.style.setProperty('--sprout-delay',`${Math.min(index,15)*90}ms`);
    button.dataset.stationId=s.id;button.setAttribute('aria-label',`${s.name}，查看站区概况`);
    if(runtimeView&&!editable&&s.target_screen_id)button.setAttribute('aria-label',s.name+'，打开工艺画面');
    button.setAttribute('aria-expanded','false');button.setAttribute('aria-controls','station-card');
    const icon=document.createElement('img');icon.src='station-pin.png';icon.alt='';icon.draggable=false;
    const label=document.createElement('span');label.className='station-name';label.textContent=s.name;
    button.append(icon,label);layer.append(button);s.button=button;
    button.addEventListener('pointerenter',()=>{clearTimeout(closeTimer);if(!drag&&!touring)open(s);});
    button.addEventListener('pointerleave',scheduleClose);
    button.addEventListener('focus',()=>{if(!drag&&!touring)open(s);});
    button.addEventListener('blur',scheduleClose);
    button.addEventListener('click',event=>{if(s.suppressClick){s.suppressClick=false;event.preventDefault();return;}if(runtimeView&&!editable&&s.target_screen_id){parent.postMessage(JSON.stringify({type:'gis-open-station',id:s.id}),location.origin);return;}open(s);});
    if(editable){
      button.classList.add('is-movable');
      button.addEventListener('pointerdown',event=>startDrag(event,s));
      button.addEventListener('pointermove',moveDrag);
      button.addEventListener('pointerup',event=>endDrag(event,false));
      button.addEventListener('pointercancel',event=>endDrag(event,true));
      button.addEventListener('lostpointercapture',event=>endDrag(event,true));
    }
    return s;
  });
  function validPosition(lon,lat){return Number.isFinite(lon)&&Number.isFinite(lat)&&lon>=-180&&lon<=180&&lat>=-85&&lat<=85;}
  function scheduleClose(event){if(touring)return;const pointer=event?.type==='pointerleave';clearTimeout(closeTimer);closeTimer=setTimeout(()=>{
    if(!drag&&!card.matches(':hover')&&!active?.button.matches(':hover')&&(pointer||(!card.contains(document.activeElement)&&!active?.button.matches(':focus-visible'))))close();
  },180);}
  function close(){clearTimeout(closeTimer);clearTimeout(hideTimer);cancelAnimationFrame(revealFrame);card.classList.remove('is-visible');active=null;refreshSelection();hideTimer=setTimeout(()=>{card.hidden=true;},260);}
  function refreshSelection(){for(const s of stations){s.button.classList.toggle('is-active',s===active);s.button.setAttribute('aria-expanded',String(s===active));}}
  function element(tag,className,text){const el=document.createElement(tag);if(className)el.className=className;if(text!==undefined)el.textContent=text;return el;}
  function open(s){
    clearTimeout(hideTimer);cancelAnimationFrame(revealFrame);
    clearTimeout(closeTimer);
    if(active!==s || card.hidden){
      active=s;card.replaceChildren();
      const head=element('div','station-card-head'),titles=element('div');
      titles.append(element('div','station-kicker','热力站 / 站区概况'),element('h2','',s.name));
      const badge=document.createElement('img');badge.src='station-pin.png';badge.alt='';badge.className='station-card-badge';
      head.append(badge,titles);
      const meta=element('div','station-meta');meta.append(element('span','station-data-status','数据待绑定'));
      if(config.placement==='illustrative')meta.append(element('span','station-placement','位置示意'));
      const zones=s.zones||[];
      card.classList.toggle('has-zones',zones.length>0);
      const readings=element('div','station-readings');
      for(const [title,kind] of [['一次侧','primary'],['二次侧','secondary']]){
        const group=element('section',`station-circuit ${kind}`);
        group.append(element('h3','',title));
        const grid=element('div','station-temperature-grid');
        for(const [label,suffix] of [['供水温度','supply'],['回水温度','return']]){
          const metric=element('div','station-metric'),value=element('div','station-value');
          value.dataset.metric=`${kind}_${suffix}`;
          value.append(element('b','','—'),element('small','','°C'));
          metric.append(element('span','station-metric-label',label),value);grid.append(metric);
        }
        group.append(grid);readings.append(group);
      }
      const pressure=element('div','station-pressure'),pressureValue=element('div','station-value');
      pressureValue.dataset.metric='supply_pressure';
      pressureValue.append(element('b','','—'),element('small','','MPa'));
      pressure.append(element('span','','供水压力'),pressureValue);readings.append(pressure);
      if(zones.length){
        readings.replaceChildren();readings.classList.add('station-sections');
        for(const [index,section] of [s,...zones].entries()){
          const block=element('section',index===0?'station-section station-common':'station-section');
          block.append(element('h3','',index===0?'站公共数据':section.name));
          const grid=element('div','station-zone-grid');
          for(const [metric,label,unit] of [
            ['primary_supply','一次供温','°C'],['primary_return','一次回温','°C'],
            ['secondary_supply','二次供温','°C'],['secondary_return','二次回温','°C'],['supply_pressure','供水压力','MPa']]){
            const field=element('div','station-zone-field'),value=element('div','station-value');
            value.dataset.metric=metric;value.dataset.section=String(index);
            value.append(element('b','','—'),element('small','',unit));
            field.append(element('span','station-metric-label',label),value);grid.append(field);
          }
          block.append(grid);readings.append(block);
        }
      }
      const foot=element('div','station-foot');foot.append(element('span','','尚未接入实时测点'));
      if(editable){
        const bind=element('button','station-bind','绑定变量');bind.type='button';
        bind.addEventListener('click',()=>parent.postMessage(JSON.stringify({type:'gis-edit-station',id:s.id}),location.origin));
        foot.append(bind);
      }
      card.append(head,meta,readings,foot);
    }
    card.hidden=false;refreshSelection();refreshReadings();positionCard();
    revealFrame=requestAnimationFrame(()=>{revealFrame=requestAnimationFrame(()=>card.classList.add('is-visible'));});
  }
  function refreshReadings(){
    if(!active)return;
    const sections=[active,...(active.zones||[])];
    let count=0,good=0;
    for(const el of card.querySelectorAll('[data-metric]')){
      const bindings=sections[Number(el.dataset.section||0)]?.bindings||{};
      const id=bindings[el.dataset.metric],value=id&&readings[id];
      if(id)count++;
      const valid=value?.quality==='good';if(valid)good++;
      el.querySelector('b').textContent=valid?value.text:'—';
      el.querySelector('small').textContent=id?(value?.unit||''):(el.dataset.metric==='supply_pressure'?'MPa':'°C');
      el.title=id?(value?.tooltip||`点位 ID：${id}\n等待数据`):'未绑定';
      let status=el.querySelector('.metric-quality');
      if(!status){status=element('span','metric-quality');el.append(status);}
      status.textContent=id?(value?.status||'等待数据'):'未绑定';
      status.hidden=valid;
    }
    card.querySelector('.station-data-status').textContent=count?`已绑定 ${count}/${sections.length*5} 项`:'数据待绑定';
    card.querySelector('.station-foot>span').textContent=count?`有效数据 ${good}/${count} 项`:'尚未接入实时测点';
  }
  function setPosition(s,lon,lat){
    s.longitude=lon;s.latitude=lat;s.world=C.Cartesian3.fromDegrees(lon,lat,20);
    lastKey='';update();viewer.scene.requestRender();
  }
  function startDrag(event,s){
    if(event.button!==0||!event.isPrimary||drag||!root.classList.contains('map-ready'))return;
    const anchor=positions.get(s.id);if(!anchor)return;
    const rect=viewer.canvas.getBoundingClientRect();
    drag={s,id:event.pointerId,x:event.clientX,y:event.clientY,
      offsetX:anchor.x-(event.clientX-rect.left),offsetY:anchor.y-(event.clientY-rect.top),
      original:[s.longitude,s.latitude],moved:false,valid:true,
      inputs:viewer.scene.screenSpaceCameraController.enableInputs};
    s.suppressClick=false;
    viewer.scene.screenSpaceCameraController.enableInputs=false;
    clearTimeout(closeTimer);s.button.setPointerCapture(event.pointerId);
    event.stopPropagation();
  }
  function moveDrag(event){
    if(!drag||event.pointerId!==drag.id)return;
    const d=drag;
    if(!d.moved&&Math.hypot(event.clientX-d.x,event.clientY-d.y)<5)return;
    if(!d.moved){d.moved=true;d.s.suppressClick=true;close();d.s.button.classList.add('is-dragging');root.classList.add('station-dragging');}
    const rect=viewer.canvas.getBoundingClientRect();
    const x=event.clientX-rect.left+d.offsetX,y=event.clientY-rect.top+d.offsetY;
    d.valid=x>20&&x<rect.width-20&&y>80&&y<rect.height-42;
    const world=d.valid&&viewer.camera.pickEllipsoid(new C.Cartesian2(x,y),viewer.scene.globe.ellipsoid);
    d.valid=!!world;
    if(world){
      const geo=C.Cartographic.fromCartesian(world),lon=C.Math.toDegrees(geo.longitude),lat=C.Math.toDegrees(geo.latitude);
      d.valid=validPosition(lon,lat);if(d.valid)setPosition(d.s,lon,lat);
    }
    hint.textContent=d.valid?'松开更新草稿 · Esc 取消':'此处无法放置 · 松开恢复原位置';
    event.preventDefault();event.stopPropagation();
  }
  function endDrag(event,cancel){
    if(!drag||(event&&event.pointerId!==drag.id))return;
    const d=drag;drag=null;
    viewer.scene.screenSpaceCameraController.enableInputs=d.inputs;
    d.s.button.classList.remove('is-dragging');root.classList.remove('station-dragging');
    if(d.s.button.hasPointerCapture(d.id))d.s.button.releasePointerCapture(d.id);
    if(!d.moved)return;
    if(cancel||!d.valid){setPosition(d.s,...d.original);hint.textContent='已取消移动，恢复原位置';return;}
    if(editable) {parent.postMessage(JSON.stringify({type:'gis-stations-changed',config:exportConfig()}),location.origin);hint.textContent='位置已更新 · 请保存画面';}
  }
  function positionCard(){
    if(!active||card.hidden)return;
    const p=positions.get(active.id),w=root.clientWidth,h=root.clientHeight;if(!p)return;
    const top=runtimeView?(w<1000?120:84):66,bottom=66;
    card.style.maxHeight=`${Math.max(40,h-top-bottom)}px`;
    const cw=card.offsetWidth,ch=card.offsetHeight;
    let x=p.x+42;if(x+cw>w-12)x=p.x-cw-42;
    card.style.left=`${Math.max(12,Math.min(w-cw-12,x))}px`;
    card.style.top=`${Math.max(top,Math.min(h-ch-bottom,p.y-ch*.4))}px`;
  }
  function update(){
    if(disposed)return;
    const w=root.clientWidth,h=root.clientHeight,alt=viewer.camera.positionCartographic.height;
    const ready=root.classList.contains('stations-ready');
    const key=`${ready}:${w}:${h}:${Array.from(viewer.camera.viewMatrix).map(v=>v.toFixed(5)).join(',')}`;
    if(lastKey===key)return;lastKey=key;
    if(!ready){entrancePlayed=false;clearTimeout(entranceTimer);layer.classList.remove('station-entering');}
    const show=ready&&alt<115000;layer.hidden=!show;hint.hidden=!show;
    if(!show){close();return;}
    for(const s of stations){
      const p=C.SceneTransforms.worldToWindowCoordinates(viewer.scene,s.world);
      const visible=p&&p.x>20&&p.x<w-20&&p.y>80&&p.y<h-42&&C.Cartesian3.distance(viewer.camera.positionWC,s.world)<alt*5+50000;
      s.button.hidden=!visible;
      if(visible){positions.set(s.id,{x:p.x,y:p.y});s.button.style.transform=`translate(${p.x.toFixed(1)}px,${p.y.toFixed(1)}px)`;}
    }
    if(!entrancePlayed&&stations.some(s=>!s.button.hidden)){
      entrancePlayed=true;layer.classList.add('station-entering');
      entranceTimer=setTimeout(()=>layer.classList.remove('station-entering'),Math.min(stations.length,16)*90+650);
    }
    if(active?.button.hidden)close();
    positionCard();
  }
  const onReady=()=>{
    lastKey='';update();
  };root.addEventListener('stationsready',onReady);
  const removeRender=viewer.scene.postRender.addEventListener(update);
  const resize=new ResizeObserver(()=>{lastKey='';update();});resize.observe(root);
  const escape=event=>{if(event.key==='Escape'){if(drag){endDrag(null,true);event.preventDefault();}close();}};root.addEventListener('keydown',escape);
  card.addEventListener('pointerenter',()=>clearTimeout(closeTimer));card.addEventListener('pointerleave',scheduleClose);
  card.addEventListener('focusout',scheduleClose);
  const cancelDrag=()=>endDrag(null,true);
  const onVisibility=()=>{if(document.hidden){cancelDrag();close();}};
  window.addEventListener('blur',cancelDrag);document.addEventListener('visibilitychange',onVisibility);
  onReady();viewer.scene.requestRender();
  function exportConfig(){return {stations:stations.map(s=>({id:s.id,name:s.name,longitude:s.longitude,latitude:s.latitude,...(s.target_screen_id?{target_screen_id:s.target_screen_id}:{}),...(s.bindings?{bindings:{...s.bindings}}:{}),...(s.zones?{zones:s.zones.map(z=>({id:z.id,name:z.name,bindings:{...z.bindings}}))}:{})}))};}
  if(runtimeView) parent.postMessage(JSON.stringify({type:'gis-stations-loaded',config:exportConfig()}),location.origin);
  return {setReadings(value){readings=value||{};refreshReadings();},
    get tourStops(){return stations.map(s=>({id:s.id,name:s.name,longitude:s.longitude,latitude:s.latitude}));},
    showTour(index){const s=stations[index];if(!s)return false;touring=true;lastKey='';update();open(s);return true;},
    releaseTour({hide=false}={}){touring=false;if(hide)close();},
    get state(){return {count:stations.length,visible:stations.filter(s=>!s.button.hidden&&!layer.hidden).length,active:active?.id||null,placement:config.placement,touring};},
    dispose(){cancelDrag();window.removeEventListener('blur',cancelDrag);document.removeEventListener('visibilitychange',onVisibility);disposed=true;clearTimeout(closeTimer);clearTimeout(hideTimer);cancelAnimationFrame(revealFrame);clearTimeout(entranceTimer);removeRender();root.removeEventListener('stationsready',onReady);resize.disconnect();root.removeEventListener('keydown',escape);layer.remove();card.remove();hint.remove();}};
};
