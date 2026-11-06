/* Small station view while the optional map engine downloads. No API access. */
(() => {
  'use strict';
  const root=document.getElementById('loading');
  if(!root)return;
  root.classList.add('station-startup');
  const heading=document.createElement('strong'),status=document.createElement('span');
  heading.textContent='站区信息';status.textContent='正在准备地图，站区信息优先显示…';
  const list=document.createElement('div');list.className='startup-stations';
  const detail=document.createElement('section');detail.className='startup-detail';
  root.replaceChildren(heading,status,list,detail);
  let config,readings={},selected='',editable=false,disposed=false,generation=0;
  async function loadConfig(data){
    const current=++generation;editable=data.editable===true;
    try{const value=data.config||await fetch('stations.json').then(r=>r.ok?r.json():Promise.reject());
      if(disposed||generation!==current)return;config=value;draw();
    }catch(_){if(!disposed&&generation===current)status.textContent='站区信息暂不可用';}
  }
  const labels={primary_supply:'一次侧供水温度',primary_return:'一次侧回水温度',secondary_supply:'二次侧供水温度',secondary_return:'二次侧回水温度',supply_pressure:'供水压力'};
  function element(tag,text){const el=document.createElement(tag);el.textContent=text;return el;}
  function showDetail(){
    detail.replaceChildren();
    const station=config?.stations?.find(s=>s.id===selected);if(!station)return;
    detail.append(element('h2',station.name));
    if(station.target_screen_id&&!editable){const open=element('button','打开工艺画面');open.type='button';open.onclick=()=>parent.postMessage(JSON.stringify({type:'gis-open-station',id:station.id}),location.origin);detail.append(open);}
    for(const section of [station,...(station.zones||[])]){
      if(section!==station)detail.append(element('h3',section.name));
      const fields=section.fields||Object.keys(labels).map(id=>({id,name:labels[id]}));
      for(const field of fields){
        const id=section.bindings?.[field.id],reading=id&&readings[id];
        const valid=reading?.quality==='good';
        const row=element('div','');row.className='startup-reading';
        row.append(element('span',field.name),element('b',valid?`${reading.text} ${reading.unit||''}`:'—'));
        row.title=reading?.tooltip||(id?'等待数据':'未绑定');detail.append(row);
      }
    }
  }
  function draw(){
    list.replaceChildren();
    if(!Array.isArray(config?.stations))return;
    if(!config.stations.some(s=>s.id===selected))selected=config.stations[0]?.id||'';
    for(const station of config.stations){
      const button=element('button',station.name);button.type='button';button.setAttribute('aria-pressed',String(station.id===selected));
      button.onclick=()=>{selected=station.id;draw();};list.append(button);
    }
    status.textContent=config.stations.length?'站区信息已就绪 · 地图正在后台加载':'暂无已配置站区 · 地图正在加载';showDetail();
  }
  function message(event){
    if(disposed||event.origin!==location.origin||event.source!==parent)return;
    try{const data=JSON.parse(event.data);
      if(data.type==='gis-config')void loadConfig(data);
      if(data.type==='gis-readings'&&data.readings){readings=data.readings;showDetail();}
    }catch(_){}
  }
  window.addEventListener('message',message);
  window.addEventListener('gis-map-visible',()=>{disposed=true;window.removeEventListener('message',message);root.hidden=true;root.replaceChildren();},{once:true});
  window.addEventListener('error',event=>{if(event.target?.tagName==='SCRIPT')status.textContent='地图暂不可用，仍可查看站区信息或打开工艺画面。';},true);
  if(new URLSearchParams(location.search).get('shell')==='1')parent.postMessage(JSON.stringify({type:'gis-ready'}),location.origin);
  else void loadConfig({});
})();
