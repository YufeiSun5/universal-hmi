const {chromium}=require('C:/Users/SunYufei/AppData/Local/npm-cache/_npx/2334a3ea0ef73d73/node_modules/playwright');
const fs=require('fs'),assert=require('assert');
(async()=>{
 const work=__dirname, config=JSON.parse(fs.readFileSync(work+'/browser-private.json','utf8'));
 const browser=await chromium.launch({channel:'chrome',headless:true});
 try {
  const context=await browser.newContext({viewport:{width:1600,height:1000}});
  const login=await context.request.post(config.url+'/api/v1/auth/login',{data:config.account,headers:{Origin:config.url}});if(!login.ok())throw Error('login '+login.status());
  const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const fields=['站点','中节能阀反馈','本区阀反馈','温度','压力','备注'];
  await page.route('**/api/v1/external/screens/'+config.report.id+'/query',r=>r.fulfill({json:{report_columns:fields,report_rows:[{'站点':'隔离测试区','中节能阀反馈':'61.9','本区阀反馈':'78.2','温度':'0','压力':null,'备注':'模拟数据'}],points:[],rows:[]}}));
  await page.goto(config.url+'/?view=developer');
  await page.waitForTimeout(5000);await page.locator('flt-semantics-placeholder').evaluate(e=>e.click()).catch(()=>{});await page.waitForTimeout(1000);

  await page.getByRole('button',{name:'外数据',exact:true}).click();await page.waitForTimeout(500);
  await page.getByRole('button',{name:/^列排序浏览器验收/}).click();await page.getByRole('button',{name:'查询',exact:true}).click();
  await page.getByRole('button',{name:'报表样式',exact:true}).click();await page.getByText('当前结果共 6 列 · 显示 6 列',{exact:true}).waitFor();
  const down=page.getByRole('button',{name:'下移选中列',exact:true}),up=page.getByRole('button',{name:'上移选中列',exact:true});
  const start=await down.boundingBox();const x=start.x+start.width/2,y=start.y+start.height/2;
  for(let i=0;i<3;i++){await page.mouse.click(x,y);await page.waitForTimeout(150);assert.deepEqual(await down.boundingBox(),start)}
  await up.click();await page.waitForTimeout(200);
  await page.getByText('站点 · 第 3 / 6 列',{exact:true}).waitFor();let labels=[];
  await page.screenshot({path:'output/playwright/v66/columns-fixed-wide.png'});
  await page.setViewportSize({width:900,height:680});await page.waitForTimeout(400);
  const narrow=await down.boundingBox();await page.mouse.click(narrow.x+narrow.width/2,narrow.y+narrow.height/2);await page.waitForTimeout(150);assert.deepEqual(await down.boundingBox(),narrow);
  await page.screenshot({path:'output/playwright/v66/columns-fixed-narrow.png'});
  const saving=page.waitForResponse(r=>r.url().endsWith('/api/v1/external/screens')&&r.request().method()==='POST');
  await page.getByRole('button',{name:'保存样式',exact:true}).click();const savedResponse=await saving;assert(savedResponse.ok());const saved=await savedResponse.json();labels=Object.values(saved.report_layouts)[0].columns.map(c=>c.label);assert.equal(labels[3],'站点');await page.waitForTimeout(500);
  await page.getByRole('button',{name:'报表样式',exact:true}).click();await page.waitForTimeout(400);
  await page.setViewportSize({width:1600,height:1000});await page.waitForTimeout(300);
  assert.equal((await page.getByRole('button',{name:'选择此列调整顺序',exact:true}).count()),6);
  fs.writeFileSync(work+'/columns-browser-result.json',JSON.stringify({status:'passed',simulatedQuery:true,realStyleSave:true,continuousDownClicks:3,upClick:1,narrowDownClick:1,fixedWide:start,fixedNarrow:narrow,savedOrder:labels,consoleErrors:errors},null,2));
  console.log('PASS fixed position repeated clicks, wide/narrow and save/reopen');
  fs.mkdirSync('output/playwright/v66',{recursive:true});
  await page.screenshot({path:'output/playwright/v66/columns-initial.png'});
  fs.writeFileSync(work+'/columns-dom.txt',await page.locator('body').innerText());
  console.log((await page.getByRole('button').allTextContents()).join('\n'));console.log('errors',errors);
 } finally {await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
