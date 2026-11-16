async page => {
 const f=page.frames().find(f=>f.url().includes('/key-trends/'));
 const state=await f.evaluate(()=>{const o=echarts.getInstanceByDom(document.querySelector('#chart')).getOption(); return o.series.map(s=>({name:s.name,data:s.data}));});
 const secondary=state.filter(s=>s.name.includes('二次网热量'));
 if(secondary.length!==1 || !secondary[0].name.includes('合计')) throw Error(JSON.stringify(state));
 if(secondary[0].data.length!==24 || secondary[0].data.some(x=>x[1]!==11)) throw Error('wrong combined data');
 if(state.length!==6) throw Error('shared temperature and pressure duplicated');
 console.log('PASS one combined secondary heat series, all 24 hours=11, six total series');
 await page.screenshot({path:'output/playwright/v99-key-trends.png'});
}
