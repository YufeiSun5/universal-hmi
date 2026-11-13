const {chromium}=require('C:/Users/SunYufei/AppData/Local/npm-cache/_npx/2334a3ea0ef73d73/node_modules/playwright');
const fs=require('fs'),path=require('path'),assert=require('assert');
(async()=>{
 const work=__dirname,cfg=JSON.parse(fs.readFileSync(work+'/browser-private.json','utf8'));
 const docs=Object.values(JSON.parse(fs.readFileSync(work+'/imported-screens.json','utf8'))).filter(d=>d.id!=='unrelated_fixture');
 const out=path.resolve('output/playwright/v66');fs.mkdirSync(out,{recursive:true});
 const browser=await chromium.launch({channel:'chrome',headless:true});const evidence={screens:[],consoleErrors:[],viewport:[1600,1000],normalLogin:true,simulatedReadings:true};
 try {
  const context=await browser.newContext({viewport:{width:1600,height:1000},acceptDownloads:true});
  const login=await context.request.post(cfg.url+'/api/v1/auth/login',{data:cfg.account,headers:{Origin:cfg.url}});assert(login.ok());const session=await login.json();
  const page=await context.newPage();const loadedScreens=new Map();page.on('response',async r=>{if(r.url().includes('/api/v1/screens/')&&r.request().method()==='GET'&&r.ok()){try{const d=await r.json();if(d.id)loadedScreens.set(d.id,d)}catch{}}});page.on('pageerror',e=>evidence.consoleErrors.push(e.message));page.on('console',m=>{if(m.type()==='error')evidence.consoleErrors.push(m.text())});
  const enable=async()=>{await page.waitForTimeout(1800);await page.locator('flt-semantics-placeholder').evaluate(e=>e.click()).catch(()=>{});await page.waitForTimeout(400)};
  await page.goto(cfg.url+'/?view=process');await enable();await page.getByRole('textbox').first().waitFor();
  if(process.env.V66_SKIP_SCREENS)evidence.screens=JSON.parse(fs.readFileSync(work+'/browser-partial.json','utf8')).screens;
  for(const [i,doc] of (process.env.V66_SKIP_SCREENS?[]:docs).entries()){
   if(i>0){await page.goto(cfg.url+'/?view=process');await enable();await page.getByRole('textbox').first().waitFor();}
   const search=page.getByRole('textbox').first();await search.click();await search.press('ControlOrMeta+A');await search.press('Backspace');await page.keyboard.insertText(doc.name);await page.waitForTimeout(350);
   await page.getByRole('button',{name:doc.name,exact:true}).click();
   for(let retry=0;retry<40&&!loadedScreens.has(doc.id);retry++)await page.waitForTimeout(100);
   const data=loadedScreens.get(doc.id);assert(data, 'actual page did not load '+doc.id);assert.equal(data.id,doc.id);assert.equal(data.background.opacity,0);
   await page.waitForTimeout(600);const file=`process-${String(i+1).padStart(2,'0')}.png`;await page.screenshot({path:path.join(out,file)});
   evidence.screens.push({id:doc.id,name:doc.name,file,nodes:data.nodes.length,background:data.background});console.log(`Rendered ${i+1}/31 ${doc.name}`);
  }
  await page.getByRole('textbox').first().fill('');
  const nav=JSON.parse(fs.readFileSync(work+'/navigation-shape.json','utf8'));
  const oldNav=await (await context.request.get(cfg.url+'/api/v1/navigation')).json();
  const saveNav=await context.request.put(cfg.url+'/api/v1/navigation',{headers:{Origin:cfg.url,'X-CSRF-Token':session.csrf_token},data:{revision:oldNav.revision,enabled:nav.enabled,nodes:nav.nodes}});assert(saveNav.ok());evidence.menuExactTargets=true;
  await page.getByRole('button',{name:/^数据总览/}).last().click();await page.waitForTimeout(2500);
  fs.writeFileSync(work+'/overview-dom.txt',await page.locator('body').innerText());
  await page.screenshot({path:path.join(out,'overview-wide.png')});
  const current=await (await context.request.get(cfg.url+'/api/v1/live-overview')).json();assert.equal(current.columns.length,32);assert.deepEqual(current.columns.slice(9,11).map(c=>c.name),['中节能阀反馈','本区阀反馈']);assert.equal(current.rows.filter(r=>r.bindings['zh-m10']).length,20);assert.equal(new Set(current.rows.map(r=>r.bindings['zh-local-valve'])).size,31);evidence.dualValveColumns=true;
  const activeBefore=await page.getByLabel(/已接管/, {exact:false}).count();
  fs.writeFileSync(work+'/control-offline','fixture outage');await page.waitForTimeout(6500);
  await page.screenshot({path:path.join(out,'overview-offline.png')});
  const apiOffline=await (await context.request.get(cfg.url+'/api/v1/live-overview/control-status')).json();assert(Object.values(apiOffline.rows).every(s=>!s.active));
  fs.unlinkSync(work+'/control-offline');await page.waitForTimeout(4500);
  const apiRecovery=await (await context.request.get(cfg.url+'/api/v1/live-overview/control-status')).json();assert(Object.values(apiRecovery.rows).some(s=>s.active));
  evidence.controlReadFailureClears=true;evidence.controlRecovery=true;evidence.semanticActiveBefore=activeBefore;
  await page.setViewportSize({width:900,height:680});await page.waitForTimeout(600);await page.screenshot({path:path.join(out,'overview-narrow.png')});
  evidence.narrowViewport=[900,680];assert.equal(evidence.consoleErrors.length,0);
  fs.writeFileSync(work+'/browser-result.json',JSON.stringify(evidence,null,2));console.log('PASS 31 actual process renders, navigation identity, overview outage/recovery and narrow viewport');
 } catch(e){fs.writeFileSync(work+'/browser-partial.json',JSON.stringify(evidence,null,2));throw e}
 finally {if(fs.existsSync(work+'/control-offline'))fs.unlinkSync(work+'/control-offline');await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
