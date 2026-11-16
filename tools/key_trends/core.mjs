export const channel = 'hmi-key-trends-v1';
export function today(now = new Date()) { return new Date(now.getTime()+8*3600000).toISOString().slice(0,10); }
export function hours(from,to) {
  const a=Date.parse(from+'T00:00:00+08:00'), b=Date.parse(to+'T00:00:00+08:00');
  if (!Number.isFinite(a+b) || b<a || b-a>30*86400000) throw Error('请选择有效日期区间，最多31天');
  return Array.from({length:(b-a)/3600000+24},(_,i)=>new Date(a+i*3600000).toISOString());
}
export function number(value) { return value===null || value===undefined || value==='' ? null : Number.isFinite(Number(value)) ? Number(value) : null; }
const decimals=new Intl.NumberFormat('zh-CN',{minimumFractionDigits:2,maximumFractionDigits:2,useGrouping:false});
export function displayNumber(value) {if(number(value)===null)return '—';const text=decimals.format(value);return text==='-0.00'?'0.00':text;}
export function stamp(value,short=false) {
  const d=new Date(Date.parse(value)+8*3600000);
  return Number.isFinite(d.getTime()) ? d.toISOString().slice(short?5:0,16).replace('T',' ') : '—';
}
export function escape(value) { return String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
export function models(result) {
  const times=hours(result.from,result.to);
  const stations=[...new Set(result.series.map(s=>s.station))];
  const namedStations=new Map();
  for(const s of result.series){if(!namedStations.has(s.name))namedStations.set(s.name,new Set());namedStations.get(s.name).add(s.station);}
  return {times,series:result.series.map(s=>{
    const samples=new Map(s.samples.map(p=>[new Date(p.time).toISOString(),p]));
    const hues={ER_TotalHeat:205,ER_SecondaryTotalHeat:33,ER_SupplyTemp:8,ER_ReturnTemp:150,ER_SupplyPressure:275,ER_ReturnPressure:185};
    const stationIndex=stations.indexOf(s.station);
    const stationName=namedStations.get(s.name).size>1?`${s.name}（${s.station}）`:s.name;
    return {...s,id:s.station+'/'+s.point,name:`${stationName} · ${s.label}`,color:`hsl(${(hues[s.point]+stationIndex*17)%360},55%,${40+(stationIndex%3)*7}%)`,
      samples:times.map(t=>samples.get(t)??{time:t,value:null,low:null,high:null,status:'无数据'})};
  })};
}

export function chartOption(result, height=620, width=1000) {
  const model=models(result), heat=model.series.filter(s=>s.group==='heat'), ranges=model.series.filter(s=>s.group!=='heat');
  const font='"Noto Sans CJK SC","Microsoft YaHei",sans-serif';
  const mid=Math.round(height*.46), lower=mid+98, bottom=height-94;
  const unit=g=>model.series.find(s=>s.group===g)?.unit??'';
  const series=[];
  const byID=new Map(model.series.map(s=>[s.id,s]));
  for (const s of heat) series.push({id:s.id,name:s.name,type:'line',xAxisIndex:0,yAxisIndex:0,
    data:s.samples.map((p,i)=>[model.times[i],number(p.value)]),encode:{x:0,y:1},connectNulls:false,
    symbol:s.point==='ER_TotalHeat'?'circle':'diamond',symbolSize:5,showSymbol:model.times.length<=48,
    lineStyle:{width:2,type:s.point==='ER_TotalHeat'?'solid':'dashed'},itemStyle:{color:s.color},emphasis:{focus:'series'},
  });
  for (const s of ranges) series.push({id:s.id,name:s.name,type:'custom',xAxisIndex:1,yAxisIndex:s.group==='temperature'?1:2,
    encode:{x:0,y:[1,2],tooltip:[1,2]},clip:true,itemStyle:{color:s.color},emphasis:{focus:'series'},
    data:s.samples.map((p,i)=>[model.times[i],number(p.low),number(p.high)]),
    renderItem(params,api) {
      const low=api.value(1), high=api.value(2);
      if (low===null || high===null || !Number.isFinite(low) || !Number.isFinite(high)) return;
      const a=api.coord([api.value(0),low]),b=api.coord([api.value(0),high]);
      const visible=api.currentSeriesIndices().filter(i=>i>=heat.length);
      const rank=visible.indexOf(params.seriesIndex);
      if(rank<0)return;
      const band=api.barLayout({count:visible.length,barMaxWidth:32,barGap:'20%',barCategoryGap:'16%'})[rank];
      const color=api.visual('color'), returning=s.point.includes('Return');
      const height=Math.abs(a[1]-b[1]);
      return {type:'rect',shape:{x:a[0]+band.offset,y:Math.min(a[1],b[1])-(height===0?.75:0),width:band.width,height:height||1.5},
        style:{fill:color,fillOpacity:returning?.5:.85,stroke:color,lineWidth:Math.min(1,band.width*.2),lineDash:returning?[3,2]:null}};
    },
  });
  const axis={type:'category',data:model.times,boundaryGap:true,axisLine:{lineStyle:{color:'#bdc9d3'}},axisTick:{show:false},
    axisLabel:{color:'#647581',formatter:v=>stamp(v,true)},axisPointer:{label:{formatter:p=>stamp(p.value)}}};
  const y={type:'value',scale:true,nameGap:18,axisLabel:{color:'#647581',formatter:displayNumber},splitLine:{lineStyle:{color:'#e9eef2'}},nameTextStyle:{color:'#465f71',fontWeight:600}};
  return {animation:false,textStyle:{fontFamily:font,color:'#293d4b'},backgroundColor:'#fff',
    title:[{text:'热量用量',subtext:'小时用量',top:8,left:14,textStyle:{fontSize:17}},{text:'温度与压力',subtext:'每小时最低值 ～ 最高值',top:mid,left:14,textStyle:{fontSize:17}}],
    legend:[{type:'scroll',top:52,left:14,right:18,data:heat.map(s=>s.name),textStyle:{fontSize:12}},
      {type:'scroll',top:mid+44,left:14,right:18,data:ranges.map(s=>s.name),textStyle:{fontSize:12}}],
    grid:[{left:width<600?52:70,right:width<600?52:70,top:100,height:Math.max(70,mid-145)},
      {left:width<600?52:70,right:width<600?52:70,top:lower,height:Math.max(70,bottom-lower)}],
    xAxis:[{...axis,gridIndex:0},{...axis,gridIndex:1}],
    yAxis:[{...y,gridIndex:0,name:unit('heat')},{...y,gridIndex:1,name:unit('temperature'),position:'left'},
      {...y,gridIndex:1,name:unit('pressure'),position:'right',splitLine:{show:false}}],
    axisPointer:{lineStyle:{color:'#7892a6',type:'dashed'}},
    tooltip:{trigger:'axis',confine:true,enterable:true,extraCssText:'max-height:280px;overflow-y:auto;max-width:520px;',
      formatter(params) {
        if (!params.length) return '';
        const index=params[0].dataIndex, time=model.times[index];
        const lines=params.map(p=>{
          const s=byID.get(p.seriesId), sample=s?.samples[index]; if (!sample)return '';
          const value=s.group==='heat'?displayNumber(sample.value):`${displayNumber(sample.low)} ～ ${displayNumber(sample.high)}`;
          return `<div>${p.marker??''}${escape(s.name)} <b>${escape(value)} ${escape(s.unit)}</b><span style="color:#647581"> ${escape(sample.status)}</span></div>`;
        });
        return `<b>${escape(stamp(time))}（北京时间）</b>`+lines.join('');
      }},
    dataZoom:[{id:'range',type:'slider',xAxisIndex:[0,1],bottom:8,height:28,start:0,end:100,filterMode:'none',
      borderColor:'#c4cdd4',fillerColor:'rgba(70,95,113,.16)',labelFormatter:v=>stamp(model.times[Math.round(v)]??'',true)},
      {id:'inside',type:'inside',xAxisIndex:[0,1],filterMode:'none',zoomOnMouseWheel:true,moveOnMouseMove:true,preventDefaultMouseMove:true}],
    series,
  };
}
