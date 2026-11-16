async page => {
 if(!(await page.locator('body').innerText()).includes('22.00（已结算部分）')) throw Error('missing settled subtotal');
 await page.screenshot({path:'output/playwright/v99-daily-partial.png'});
 const download=page.waitForEvent('download');
 await page.getByRole('button',{name:'导出当前结果',exact:true}).click();
 await (await download).saveAs('.local/secondary-meter-v99/daily-partial-ui.csv');
 await page.setViewportSize({width:800,height:900});
 await page.screenshot({path:'output/playwright/v99-daily-narrow.png'});
 await page.setViewportSize({width:1440,height:1000});
 await page.getByRole('textbox',{name:'开始日期（含）',exact:true}).fill('2026-11-14');
 await page.getByRole('textbox',{name:'结束日期（含）',exact:true}).fill('2026-11-14');
 const response=page.waitForResponse(r=>r.url().endsWith('/query')&&r.request().method()==='POST');
 await page.getByRole('button',{name:'查询',exact:true}).click();
 await response;
 await page.getByRole('button',{name:/2026-11-14.*264.00/}).waitFor();
 await page.screenshot({path:'output/playwright/v99-daily-complete.png'});
 console.log('PASS daily subtotal explicitly partial; complete day 264; narrow layout; CSV downloaded');
}
