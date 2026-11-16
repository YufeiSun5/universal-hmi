async page => {
 await page.getByRole('textbox',{name:'日期',exact:true}).fill('2026-11-14');
 const response=page.waitForResponse(r=>r.url().endsWith('/query')&&r.request().method()==='POST');
 await page.getByRole('button',{name:'查询',exact:true}).click();
 await response;
 await page.getByRole('button',{name:/2026-11-14.*00:00:00/}).waitFor();
 const body=await page.locator('body').innerText();
 for(const s of ['二次网供水流量（合计）','二次网瞬时热量（合计）','二次网累计热量（合计）','二次网累计流量（合计）']) if(!body.includes(s)) throw Error(s);
 if(body.includes('二次网2')) throw Error('individual meter leaked');
 await page.screenshot({path:'output/playwright/v99-hourly.png'});
 const download=page.waitForEvent('download');
 await page.getByRole('button',{name:'导出当前结果',exact:true}).click();
 await (await download).saveAs('.local/secondary-meter-v99/hourly-ui.csv');
 await page.getByRole('textbox',{name:'日期',exact:true}).fill('2026-11-15');
 const missing=page.waitForResponse(r=>r.url().endsWith('/query')&&r.request().method()==='POST');
 await page.getByRole('button',{name:'查询',exact:true}).click();
 await missing;
 await page.getByText('东南区二次网部分时段不完整',{exact:false}).first().waitFor({timeout:10000});
 await page.screenshot({path:'output/playwright/v99-hourly-missing.png'});
 console.log('PASS hourly four totals, actual CSV download and missing warning');
}

