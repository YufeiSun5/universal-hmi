import {channel,today,chartOption,number,stamp} from './core.mjs';
const $=id=>document.getElementById(id), native=window.chrome?.webview;
const pending=new Map();let sequence=0,stations=[],selected=new Set(),draft=new Set(),current=null,busy=false,rangeSelection=null;
const chart=echarts.init($('chart'),null,{renderer:'canvas'});
function renderChart(reset=false){if(!current)return;const previous=reset?null:chart.getOption();const option=chartOption(current,$('chart').clientHeight,$('chart').clientWidth,rangeSelection);const zoom=previous?.dataZoom?.[0];if(zoom)option.dataZoom[0]={...option.dataZoom[0],start:zoom.start,end:zoom.end};option.legend.forEach((l,i)=>l.selected=previous?.legend?.[i]?.selected??{});chart.setOption(option,true);}
function clearRange(){rangeSelection=null;$('selectedRange').textContent='';$('clearRange').hidden=true;renderChart();}
chart.on('click',e=>{if(e.seriesType!=='custom'||!current)return;rangeSelection={id:e.seriesId,index:e.dataIndex};const s=current.series.find(s=>s.station+'/'+s.point===e.seriesId);$('selectedRange').textContent=`已选 ${stamp(e.data[0])}（北京时间） · ${s.name} · ${s.label}`;$('clearRange').hidden=false;renderChart();});
chart.getZr().on('click',e=>{if(!e.target)clearRange();});
chart.on('legendselectchanged',e=>{const s=chart.getOption()?.series?.find(s=>s.id===rangeSelection?.id);if(s&&e.selected[s.name]===false)clearRange();});
$('clearRange').onclick=clearRange;
function post(data){const message=JSON.stringify({channel,...data});if(native)native.postMessage(message);else parent.postMessage(message,location.origin);}
function receive(raw){let message;try{message=typeof raw==='string'?JSON.parse(raw):raw;}catch{return;}if(message?.channel!==channel||message.type!=='result')return;const p=pending.get(message.id);if(!p)return;clearTimeout(p.timer);pending.delete(message.id);message.error?p.reject(Error(message.error)):p.resolve(message.data);}
if(native)native.addEventListener('message',event=>receive(event.data));
else window.addEventListener('message',event=>{if(event.source===parent&&event.origin===location.origin)receive(event.data);});
function request(type,data={}){return new Promise((resolve,reject)=>{const id='curve-'+(++sequence);const timer=setTimeout(()=>{pending.delete(id);reject(Error('查询超时，请缩小区间后重试'));},40000);pending.set(id,{resolve,reject,timer});post({type,id,...data});});}
function setBusy(value){busy=value;$('loading').hidden=!value;for(const id of ['query','choose','today','from','to'])$(id).disabled=value;}
function selection(){const names=stations.filter(s=>selected.has(s.code)).map(s=>s.name);$('count').textContent=selected.size;$('selection').textContent=names.length?names.join('、'):'尚未选择站区';$('selection').title=names.join('、');}
function renderStations(){const search=$('search').value.trim().toLowerCase();$('stationList').replaceChildren();for(const s of stations.filter(s=>(s.name+' '+s.code).toLowerCase().includes(search))){const label=document.createElement('label'),input=document.createElement('input'),text=document.createElement('span'),small=document.createElement('small');input.type='checkbox';input.checked=draft.has(s.code);input.setAttribute('aria-label',s.name+' '+s.code);input.addEventListener('change',()=>{input.checked?draft.add(s.code):draft.delete(s.code);$('draftCount').textContent=`已选 ${draft.size} / ${stations.length}`;});text.textContent=s.name;small.textContent=s.code;text.append(small);label.append(input,text);$('stationList').append(label);}$('draftCount').textContent=`已选 ${draft.size} / ${stations.length}`;}
async function query(){if(busy)return;$('error').hidden=true;$('missing').hidden=true;$('empty').hidden=true;chart.clear();current=null;rangeSelection=null;$('selectedRange').textContent='';$('clearRange').hidden=true;
  if(!selected.size){$('error').textContent='请先选择至少一个站区';$('error').hidden=false;$('status').textContent='未查询';return;}
  setBusy(true);$('status').textContent='查询中…';
  try{const data=await request('query',{from:$('from').value,to:$('to').value,stations:[...selected]});current=data.key_trends;if(!current)throw Error('曲线数据格式无效');
    renderChart(true);
    const hasValues=current.series.some(s=>s.samples.some(p=>s.group==='heat'?number(p.value)!==null:number(p.low)!==null&&number(p.high)!==null));
    $('empty').hidden=hasValues;$('empty').textContent='所选区间暂无有效小时报数据';
    $('status').textContent=`${current.from} 至 ${current.to} · ${selected.size} 个站区`;
    if(current.missing.length){$('missing').hidden=false;$('missing').querySelector('summary').textContent=`${current.missing.length} 个重点测点未配置小时统计`;$('missing').querySelector('div').textContent=current.missing.join('\n');}
  }catch(e){current=null;chart.clear();$('error').textContent=e.message;$('error').hidden=false;$('status').textContent='查询失败，可重试';}finally{setBusy(false);}
}
$('queryForm').addEventListener('submit',e=>{e.preventDefault();query();});
$('today').onclick=()=>{$('from').value=$('to').value=today();query();};
$('choose').onclick=()=>{draft=new Set(selected);$('search').value='';renderStations();$('stations').showModal();};
$('search').oninput=renderStations;$('all').onclick=()=>{draft=new Set(stations.map(s=>s.code));renderStations();};$('clear').onclick=()=>{draft.clear();renderStations();};
$('stations').addEventListener('close',()=>{if($('stations').returnValue==='apply'){selected=new Set(draft);selection();query();}});
$('reset').onclick=()=>chart.dispatchAction({type:'dataZoom',start:0,end:100});
let resizeTimer;new ResizeObserver(()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(()=>{chart.resize();renderChart();},80);}).observe($('chart'));
for(const id of ['from','to']){$(id).value=today();$(id).min='2026-11-04';$(id).max=today();}
post({type:'ready'});setBusy(true);
try{const data=await request('stations');stations=data.items??[];if(stations.length)selected.add(stations[0].code);selection();setBusy(false);if(stations.length)query();else{$('empty').hidden=false;$('empty').textContent='没有可查询的站区';}}
catch(e){setBusy(false);$('error').textContent=e.message;$('error').hidden=false;$('selection').textContent='站区加载失败';$('choose').textContent='重新加载站区';$('choose').onclick=()=>location.reload();}
