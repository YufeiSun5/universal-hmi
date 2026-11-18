import test from 'node:test';import assert from 'node:assert/strict';
import {today,hours,models,chartOption,number,escape,displayNumber} from './core.mjs';
test('links join only visible non-overlapping supply and return ranges at the same station and hour',()=>{
  const sample={time:'2026-11-16T00:00:00+08:00',low:30,high:32};
  const series=[
    {station:'A',name:'A',point:'ER_SupplyTemp',label:'供温',group:'temperature',samples:[sample]},
    {station:'A',name:'A',point:'ER_ReturnTemp',label:'回温',group:'temperature',samples:[{...sample,low:20,high:22}]},
    {station:'B',name:'B',point:'ER_ReturnTemp',label:'回温',group:'temperature',samples:[sample]}
  ];
  const option=chartOption({from:'2026-11-16',to:'2026-11-16',series});
  function render(visible,low,high,index=0){
    return option.series[0].renderItem({dataIndex:index},{
      value:i=>[index,low,high][i],coord:([x,y])=>[100,200-y],
      currentSeriesIndices:()=>visible,barLayout:()=>[{offset:-8,width:16}],visual:()=>'#000'
    });
  }
  const link=render([0,1,2],30,32).children[1];
  assert.deepEqual(link.shape,{x1:100,x2:100,y1:171,y2:177});
  assert.ok(link.silent && link.style.lineDash.length);
  assert.equal(render([0,2],30,32).type,'rect');
  assert.equal(render([0,1],20,25).type,'rect');
  assert.equal(render([0,1],30,32,1).type,'rect');
  assert.deepEqual(render([0,1],10,12).children[1].shape,{x1:100,x2:100,y1:181,y2:187});
});
const result={from:'2026-11-16',to:'2026-11-17',missing:[],series:[
 {station:'A',name:'A站',point:'ER_TotalHeat',label:'一次网热量用量',group:'heat',unit:'GJ',samples:[{time:'2026-11-16T00:00:00+08:00',value:'0',status:'有效'},{time:'2026-11-17T00:00:00+08:00',value:'12.345678901234567890',status:'有效'}]},
 {station:'A',name:'A站',point:'ER_SupplyTemp',label:'供温',group:'temperature',unit:'℃',samples:[{time:'2026-11-16T00:00:00+08:00',low:'0',high:'50',status:'有效'}]},
 {station:'B',name:'B站',point:'ER_ReturnPressure',label:'回压',group:'pressure',unit:'MPa',samples:[{time:'2026-11-16T00:00:00+08:00',low:'0.2',high:'0.3',status:'有效'}]},
]};
test('Beijing today and inclusive hourly date window ignore host time zone',()=>{assert.equal(today(new Date('2026-11-15T18:00:00Z')),'2026-11-16');assert.equal(hours(result.from,result.to).length,48);assert.equal(hours(result.from,result.to)[0],'2026-11-15T16:00:00.000Z');assert.throws(()=>hours('2026-11-17','2026-11-16'));});
test('display rounds to two decimals while raw samples, zero and gaps remain intact',()=>{const m=models(result);assert.equal(number('0'),0);assert.equal(number(null),null);assert.equal(m.series[0].samples[1].value,null);assert.equal(m.series[0].samples[24].value,'12.345678901234567890');const option=chartOption(result);assert.equal(option.series[0].connectNulls,false);const text=option.tooltip.formatter([{dataIndex:24,seriesId:'A/ER_TotalHeat'}]);assert.match(text,/12.35 GJ/);for(const [input,output] of [['0','0.00'],[null,'—'],['0.435','0.44'],['-0.001','0.00'],['12345678901234567890.125','12345678901234567890.13']])assert.equal(displayNumber(input),output);});
test('two grids share time zoom with distinct heat temperature pressure axes',()=>{const o=chartOption(result);assert.equal(o.grid.length,2);assert.deepEqual(o.yAxis.map(a=>a.name),['GJ','℃','MPa']);assert.equal(o.yAxis[2].position,'right');assert.deepEqual(o.dataZoom[0].xAxisIndex,[0,1]);assert.deepEqual(o.series.map(s=>s.yAxisIndex),[0,1,2]);assert.deepEqual(o.series[1].encode.y,[1,2]);});
test('range bodies preserve bounds and zero-height samples without fake OHLC',()=>{const o=chartOption(result);const api={value:i=>[0,0,0][i],coord:([x,y])=>[x,y],currentSeriesIndices:()=>[0,1,2],barLayout:()=>[{offset:-8,width:6},{offset:2,width:6}],visual:()=> '#333'};const g=o.series[1].renderItem({seriesIndex:1},api);assert.equal(g.type,'rect');assert.equal(g.shape.width,6);assert.equal(g.shape.height,1.5);assert.equal(g.shape.y,-.75);const span=o.series[1].renderItem({seriesIndex:1},{...api,value:i=>[0,10,30][i]});assert.equal(span.shape.y,10);assert.equal(span.shape.height,20);assert.equal(o.series[1].renderItem({seriesIndex:1}, {...api,value:i=>[0,NaN,1][i]}),undefined);});
test('hover axes are independent but both charts still share zoom',()=>{const o=chartOption(result);assert.equal(o.axisPointer.link,undefined);for(const z of o.dataZoom)assert.deepEqual(z.xAxisIndex,[0,1]);assert.equal(o.yAxis[2].axisLabel.formatter(.3),'0.30');});
test('range width delegates to visible-series ECharts bar layout',()=>{const o=chartOption(result);let count;const api={value:i=>[0,1,3][i],coord:([x,y])=>[x,y],currentSeriesIndices:()=>[0,2],barLayout:opts=>{count=opts.count;return [{offset:-12,width:24}];},visual:()=> '#333'};const g=o.series[2].renderItem({seriesIndex:2},api);assert.equal(count,1);assert.equal(g.shape.width,24);assert.equal(g.shape.x,-12);});
test('all temperatures share a slot and all pressures share a separate slot',()=>{const r=structuredClone(result);r.series.push({...r.series[1],station:'C',point:'ER_ReturnTemp'});r.series.push({...r.series[2],station:'C',point:'ER_SupplyPressure'});const o=chartOption(r);const counts=[];const api={value:i=>[0,1,3][i],coord:([x,y])=>[x,y],currentSeriesIndices:()=>[0,1,2,3,4],barLayout:opts=>{counts.push(opts.count);return [{offset:-20,width:16},{offset:4,width:16}];},visual:()=> '#333'};const positions=o.series.slice(1).map((s,i)=>s.renderItem({seriesIndex:i+1},api).shape.x);assert.deepEqual(positions,[-20,4,-20,4]);assert.deepEqual(counts,[2,2,2,2]);});
test('only the chosen point/hour gets real extrema labels; offscreen labels stay hidden',()=>{const o=chartOption(result,620,1000,{id:'A/ER_SupplyTemp',index:0});const api={value:i=>[0,0,50][i],coord:([x,y])=>[100,100-y],currentSeriesIndices:()=>[0,1,2],barLayout:()=>[{offset:-20,width:16},{offset:4,width:16}],visual:()=> '#333'};const p={seriesIndex:1,dataIndex:0,coordSys:{x:0,y:0,width:300,height:160}};const g=o.series[1].renderItem(p,api);assert.equal(g.type,'group');assert.deepEqual(g.children.slice(1).map(v=>v.style.text),['最高 50.00 ℃','最低 0.00 ℃']);assert.equal(o.series[1].renderItem({...p,dataIndex:1},api).type,'rect');assert.equal(o.series[1].renderItem(p,{...api,coord:()=>[-100,50]}).type,'rect');});
test('tooltip escapes external labels and station identities stay independent',()=>{assert.equal(escape('<img>'), '&lt;img&gt;');const r=structuredClone(result);r.series[1].name='<img>';const o=chartOption(r);const text=o.tooltip.formatter([{dataIndex:0,seriesId:'A/ER_SupplyTemp'}]);assert.ok(text.includes('&lt;img&gt;'));assert.equal(new Set(o.series.map(s=>s.id)).size,3);});
test('stations with the same display name retain independent legend controls',()=>{const r=structuredClone(result);r.series=[r.series[0],{...r.series[0],station:'B'}];const o=chartOption(r);assert.notEqual(o.series[0].name,o.series[1].name);assert.match(o.series[0].name,/（A）/);assert.match(o.series[1].name,/（B）/);});
