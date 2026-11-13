import {randomID} from './identity.mjs';
import {listenToHost} from './host-messages.mjs';
import {LeaseQueue,observedCells,changedCells} from './editor-session.mjs';
import React, {useEffect, useMemo, useRef, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {flushSync} from 'react-dom';
import {Workbook} from '@fortune-sheet/react';
import {update as formatDisplay} from '@fortune-sheet/core';
import '@fortune-sheet/react/dist/index.css';
import {CellSync, address, coordinates, numeric, sameFormat, cellFormat, selectionAddress} from './sync.mjs';
import {remoteOperations} from './sheet-update.mjs';
import {ReportTools} from './ReportTools.jsx';
import {historyDisplayOperations,pendingHistoryCells,historyNotice} from './history-display.mjs';
import './style.css';

const channel='hmi-total-reports-v1';
// The report is always served from the host's origin, including the desktop proxy.
const parentOrigin=location.origin;
const development=new URLSearchParams(location.search).get('development')==='true';
const calls=new Map(); let sequence=0;
const client=randomID().replaceAll('-','');
function emit(message){const payload={channel,...message};if(window.chrome?.webview)window.chrome.webview.postMessage(payload);else parent.postMessage(JSON.stringify(payload),parentOrigin);}
function api(method,path,body){return new Promise((resolve,reject)=>{const id=String(++sequence);const timer=setTimeout(()=>{calls.delete(id);reject(new Error('连接超时，待保存内容仍保留，请重试'));},40000);calls.set(id,{resolve,reject,timer});emit({type:'api',id,method,path,body});});}
const names={heat:'热报表',electricity:'电报表',water:'水报表'};
const root='/api/v1/total-reports';
const toolbarItems=['undo','redo','|','font','font-size','|','bold','italic','underline','strike-through','|','font-color','background','|','currency-format','percentage-format','number-decrease','number-increase','format','|','horizontal-align','vertical-align','text-wrap','|','quick-formula','freeze','search'];
class SheetErrorBoundary extends React.Component {
 constructor(props){super(props);this.state={failed:false};}
 static getDerivedStateFromError(){return {failed:true};}
 componentDidCatch(error){this.props.onError(error);}
 render(){return this.state.failed?<div className="empty" role="alert">表格显示异常。已保存的数据不受影响，请通过上方“重新加载报表”恢复；未确认的修改需先核对。</div>:this.props.children;}
}
function App(){
 const ref=useRef(null),state=useRef({kind:'heat',year:new Date().getFullYear(),sync:null,doc:null,sheet:null,owned:new Map(),locks:[],selection:[],busy:false,suppress:false,loading:false,ready:false,selectionSequence:0,leaseQueue:new LeaseQueue(),leaseActive:true});
 const [view,setView]=useState(0),[book,setBook]=useState(null),[generation,setGeneration]=useState(0),[status,setStatus]=useState('正在读取报表目录…'),[error,setError]=useState(''),[catalog,setCatalog]=useState([]),[configure,setConfigure]=useState(false),[modal,setModal]=useState(null);
 const s=state.current;
 const reportName=kind=>names[kind]||catalog.find(x=>x.kind===kind)?.name||'报表';
 const redraw=()=>{setView(v=>v+1);emit({type:'dirty',dirty:!!s.sync?.dirty});};
 const path=(suffix='')=>`${root}/${s.kind}/${s.year}${suffix}`;
 const report=e=>{setError(e.message||String(e));redraw();};
 function paintHistory(){
  if(!ref.current||!s.ready)return;
  const ops=historyDisplayOperations(ref.current.getAllSheets(),s.history||[],s.historyPending);
  if(!ops.length)return;
  s.suppress=true;try{flushSync(()=>ref.current.applyOp(ops));}finally{s.suppress=false;}
 }
 function baseFormat(a){const [r,c]=coordinates(a),t=s.doc.template,style=t.styles?.[r<t.header_rows?`h${r}_${c}`:r===t.header_rows?`b${c}`:`d${c}`];return cellFormat(t.formats?.[a]|| (style?{bg:style.bg,fc:style.fg,bl:style.bold?1:0,fs:style.size||11}:s.sheet.celldata.find(v=>v.r===r&&v.c===c)?.v));}
 function applyCells(cells){
  if(!cells.length||!ref.current||!s.ready)return;
  s.suppress=true;
  try{const updates=cells.filter(cell=>!s.sync.pending.has(cell.address)).map(cell=>({...cell,format:Object.keys(cell.format||{}).length?cell.format:baseFormat(cell.address)}));if(!updates.length)return;const ops=remoteOperations(ref.current.getAllSheets(),updates);if(ops.length)flushSync(()=>ref.current.applyOp(ops));for(const cell of updates)s.formats.set(cell.address,cell.format);}
  finally{if(ref.current&&s.sheet)s.observed=observedCells(ref.current.getAllSheets()[0],s.sheet.celldata);s.suppress=false;paintHistory();}
 }
 async function readCatalog(){const result=await api('GET',root);const order={heat:0,electricity:1,water:2};result.items.sort((a,b)=>(order[a.kind]??3)-(order[b.kind]??3));setCatalog(result.items);setConfigure(result.can_configure);return result.items;}
 async function open(kind,year){
  if(s.loading||s.opening)return;
  s.opening=true;redraw();
  let permitted=false;
  try{permitted=await leave();}finally{s.opening=false;}
  if(!permitted){redraw();return;}
  s.loading=true;s.displayFailed=false;s.ready=false;s.interacted=false;s.selectionSequence++;s.selection=[];s.owned.clear();s.sync=null;s.doc=null;s.observed=null;s.history=[];s.historyPending=new Set();s.heatBusy=false;s.kind=kind;s.year=year;setBook(null);setError('');setStatus('正在打开…');redraw();
  try{const result=await api('GET',path());s.doc=result.document;s.sheet=result.sheet;for(const cell of result.sheet.celldata){if(cell.v.v!=null&&!cell.v.f)cell.v.m=String(formatDisplay(cell.v.ct?.fa||'General',cell.v.v));}s.formats=new Map(result.sheet.celldata.map(v=>[address(v.r,v.c),cellFormat(v.v)]));if(!s.doc.template.rows)result.sheet.frozen={type:innerHeight>=650?"rangeBoth":"rangeColumn",range:{row_focus:s.doc.template.header_rows,column_focus:2}};s.sync=new CellSync(s.doc.cells,s.doc.revision);setBook([result.sheet]);setGeneration(n=>n+1);setStatus(s.doc.can_edit?'已保存':'只读');}
  catch(e){report(e);setStatus('无法打开报表');}
  finally{s.loading=false;redraw();}
 }
 async function refresh(){
  if(!s.sync||s.busy||s.loading||!s.ready)return;
  const current=s.sync;
  try{
   const [delta,leases]=await Promise.all([api('GET',path(`/changes?after=${s.sync.revision}`)),api('GET',path('/locks'))]);
   if(s.sync!==current)return;
   if(delta.cells.some(c=>c.actor==='configuration')){if(s.sync.dirty){setError('报表配置已更新，请先保存当前修改再重新打开报表。');return;}await open(s.kind,s.year);return;}
   const updates=delta.cells.filter(cell=>{const old=s.sync.cells.get(cell.address);return !old||old.revision!==cell.revision||old.value!==cell.value||!sameFormat(old.format,cell.format);});s.sync.merge(delta);s.locks=leases.items;applyCells(updates);redraw();
  }catch(e){report(e);}
 }
 async function save(){
  if(!s.sync||s.busy||s.loading)return !s.sync?.dirty;
  if(!s.sync.flight&&s.sync.pending.size&&[...s.sync.pending.keys()].some(a=>!owns(a))){if(!await acquire([...s.sync.pending.keys()]))return false;}
  if(s.sync.conflicts.size){setError('编辑期间连接或锁发生变化，请先核对待保存内容。');return false;}
  s.busy=true;redraw();
  try{
   while(s.sync.dirty){
    const batch=s.sync.batch(randomID());if(!batch)break;
    setStatus('正在保存…');
    const result=await api('POST',path('/changes'),{...batch,client});s.sync.acknowledge(result);for(const c of result.cells)s.formats.set(c.address,Object.keys(c.format||{}).length?c.format:baseFormat(c.address));
   }
   setStatus('已保存');setError('');return !s.sync.dirty;
  }catch(e){
   if(e.status===409){s.sync.rejectConflict();const delta=await api('GET',path(`/changes?after=${s.sync.revision}`));s.sync.merge(delta);applyCells(delta.cells);s.owned.clear();}
   report(e);return false;
  }finally{s.busy=false;redraw();}
 }
 async function release(){
  s.leaseActive=false;s.selectionSequence++;s.selection=[];
  if(!s.doc?.can_edit)return;
  const current=s.sync,target=path('/locks');
  await s.leaseQueue.run(async()=>{await api('POST',target,{client,addresses:[]});if(current===s.sync){s.owned.clear();s.locks=s.locks.filter(v=>v.client!==client);redraw();}});
 }
 async function leave(){
  if(s.displayFailed)return false;
  // Clicking the outer shell can leave the grid editor active; dispatch Enter
  // to the real editor before collecting changes, then await its React commit.
  const editor=document.activeElement;
  if(editor?.isContentEditable||editor?.tagName==='INPUT')editor.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true}));
  await new Promise(resolve=>setTimeout(resolve,30));
  if(s.deferred)await s.deferred;
  if(s.sync?.dirty&&!await save())return false;
  if(s.busy)return false;
  try{await release();return true;}catch(e){report(e);return false;}
 }
 async function acquire(addresses){
  if(!s.doc?.can_edit)return false;
  if(s.sync.flight&&!await save())return false;
  s.leaseActive=true;
  const current=s.sync,target=path('/locks');
  return s.leaseQueue.run(async()=>{
   if(current!==s.sync||!s.leaseActive)return false;
   const wanted=[...new Set([...addresses,...s.sync.pending.keys()])];
   try{
    const result=await api('POST',target,{client,addresses:wanted});
    if(current!==s.sync)return false;
    s.owned=new Map(result.items.map(v=>[v.address,v]));
    s.sync.merge({revision:s.sync.revision,cells:result.cells});applyCells(result.cells);
    setError('');redraw();return true;
   }catch(e){if(current===s.sync)report(e);return false;}
  });
 }
 function selectionChanged(_id,range){
  const seq=++s.selectionSequence;
  setTimeout(async()=>{
   if(seq!==s.selectionSequence||s.suppress||!s.ready||!s.interacted||!range)return;
   const selected=[];
   for(let r=range.row[0];r<=range.row[1];r++)for(let c=range.column[0];c<=range.column[1];c++){
    if(s.sheet.celldata.find(v=>v.r===r&&v.c===c)?.v?.lo===0)selected.push(address(r,c));
    if(selected.length>1000){setError('一次最多选择1000个可编辑单元格');return;}
   }
   if(selected.join(',')===s.selection.join(',')&&selected.every(owns))return;
   s.selection=selected;
   if(s.doc.can_edit)await acquire(selected);else redraw();
  },90);
 }
 function owns(a){return (s.owned.get(a)?.expires||0)*1000>Date.now();}
 function refreshFormulaInput(){
  // FortuneSheet only refreshes this field when the selection changes; undo
  // and remote updates can change the selected value without moving it.
  const input=document.querySelector('[aria-label="当前单元格输入"]');
  if(!input||document.activeElement?.isContentEditable)return;
  const range=ref.current?.getSelection()?.[0];if(!range)return;
  const r=range.row_focus??range.row[0],c=range.column_focus??range.column[0];
  const cell=ref.current.getAllSheets()[0]?.data?.[r]?.[c];
  input.textContent=cell?.f||String(cell?.v??'');
 }
 function changed(sheets){
  if(!sheets[0]?.data)return;
  const observed=observedCells(sheets[0],s.sheet.celldata),previous=s.observed;s.observed=observed;
  if(!s.ready){s.ready=true;setTimeout(()=>{if(ref.current){s.suppress=true;try{const ops=remoteOperations(ref.current.getAllSheets(),[]);if(ops.length)flushSync(()=>ref.current.applyOp(ops));}finally{s.observed=observedCells(ref.current.getAllSheets()[0],s.sheet.celldata);s.suppress=false;}if(s.kind==='heat'||s.doc?.template.history?.length)void syncHeat(true).catch(report);}},0);return;}
  setTimeout(refreshFormulaInput,0);
  if(s.suppress||!s.sync||!s.interacted)return;
  const revert=[];let edited=false;
  // Compare actual grid edits with the last observed grid, not all server
  // cells: calculated caches/default format normalization are not user edits.
  for(const change of changedCells(previous,observed)){
   const [r,c]=coordinates(change.address),spec=s.sheet.celldata.find(v=>v.r===r&&v.c===c);
   if(spec?.v.lo!==0||!s.doc.can_edit){revert.push({address:change.address,value:s.sync.value(change.address),format:s.formats.get(change.address)});continue;}
   s.sync.edit(change.address,change.value,change.format);edited=true;
  }
  if(revert.length)setTimeout(()=>applyCells(revert),0);
  if(edited){setStatus(`待保存 ${s.sync.pending.size} 格`);redraw();clearTimeout(s.saveTimer);s.saveTimer=setTimeout(()=>void save(),700);}
 }
 async function paste(range,content){
  if(!range?.length)return;
  const values=content.replace(/\r\n/g,'\n').replace(/\n$/,'').split('\n').map(row=>row.split('\t'));
  const [r0,c0]=[range[0].row[0],range[0].column[0]],cells=[];
  for(let r=0;r<values.length;r++)for(let c=0;c<values[r].length;c++){
   const spec=s.sheet.celldata.find(v=>v.r===r+r0&&v.c===c+c0);
   if(!spec||spec.v.lo!==0){setError('粘贴范围包含自动表底或合并格，请调整范围。');return;}
   cells.push({address:address(r+r0,c+c0),value:values[r][c]});
  }
  if(cells.length>1000){setError('一次最多粘贴1000格');return;}
  if(!await acquire(cells.map(c=>c.address)))return;
  s.selection=cells.map(c=>c.address);s.suppress=true;
  try{flushSync(()=>ref.current.batchCallApis([...cells.map(c=>{const [r,col]=coordinates(c.address);return {name:'setCellValue',args:[r,col,c.value===''?null:numeric(c.value)?Number(c.value):c.value,null]};}),{name:'calculateFormula',args:[]} ]));}finally{s.suppress=false;}
  for(const c of cells)s.sync.edit(c.address,c.value);
  redraw();await save();
 }
 async function checkpoints(){
  if(!await leave())return;await refresh();
  const result=await api('GET',path('/checkpoints'));setModal({type:'checkpoints',items:result.items});
 }
 async function rollback(cp){
  setModal({type:'confirm',cp});
 }
 async function performRollback(cp){
  try{await api('POST',path('/rollback'),{id:randomID(),checkpoint:cp.id,expected:s.sync.revision});setModal(null);await open(s.kind,s.year);setStatus('已回滚，回滚前内容保留在检查点中');}catch(e){report(e);}
 }
 async function makeCheckpoint(){if(!await leave())return;await refresh();await api('POST',path('/checkpoints'),{expected:s.sync.revision});setStatus('检查点已保存');}
 async function exportFile(){if(!await leave())return;const result=await api('GET',path('/export'));emit({type:'export',data:result.data,name:`${reportName(s.kind)}-${s.year}.xlsx`});}
 async function chooseExcel(file){
  if(!file)return;if(file.size>8*1024*1024)throw new Error('Excel文件不能超过8MiB');
  if(!/\.xlsx$/i.test(file.name))throw new Error('为完整保留原格式，请先在Excel中将旧版文件另存为.xlsx，再上传。');
  const XLSX=await import('xlsx'),bytes=new Uint8Array(await file.arrayBuffer());
  const workbook=XLSX.read(bytes,{type:'array',cellStyles:true,cellNF:true,bookVBA:false});
  const sheets=workbook.SheetNames.filter(name=>workbook.Sheets[name]?.['!ref']);
  if(!sheets.length)throw new Error('文件中没有可导入的工作表');
  s.upload={bytes};
  setModal(m=>({...m,file:file.name,sheets,sheet:sheets[0],name:m.name||file.name.replace(/\.xlsx?$/i,'')}));
 }
 async function createPage(){
  if((modal.type!=='original'&&!modal.name?.trim())||!s.upload)throw new Error('请填写页面名称并选择Excel文件');
  if(!await leave())return;
  setModal(m=>({...m,busy:true}));
  try{
   const bytes=s.upload.bytes;
   if(bytes.length>8*1024*1024)throw new Error('转换后的Excel超过8MiB');
   let binary='';for(let i=0;i<bytes.length;i+=32768)binary+=String.fromCharCode(...bytes.subarray(i,i+32768));
   let kind=s.kind;
   if(modal.type==='original')await api('POST',`${root}/templates/${kind}/original`,{sheet:modal.sheet,data:btoa(binary),repeat_row:s.doc.template.rows?0:s.doc.template.header_rows+2});
   else{const result=await api('POST',`${root}/pages`,{id:modal.id,name:modal.name.trim(),sheet:modal.sheet,data:btoa(binary)});kind=result.kind;}
   await readCatalog();setModal(null);s.upload=null;await open(kind,s.year);
  }finally{setModal(m=>m?{...m,busy:false}:m);}
 }
 async function syncHeat(auto=false,currentOnly=false){
	if(s.doc?.template.generic&&!s.doc?.template.history?.length)return;
	if(s.doc?.template.history?.length){
	 if(s.heatBusy||s.loading)return;if(!auto&&!await leave())return;
	 const current=s.sync,target=path();s.heatBusy=true;redraw();
	 try{
	  const before=await api('GET',target+'/history-state');if(s.sync!==current)return;
	  s.history=before.items;s.historyPending=pendingHistoryCells(before.items.filter(v=>!currentOnly||v.provisional));paintHistory();redraw();
	  await api('POST',target+'/history-refresh',{current_only:currentOnly});if(s.sync!==current)return;
	  await refresh();if(s.sync!==current)return;
	  const after=await api('GET',target+'/history-state');if(s.sync!==current)return;
	  s.history=after.items;setError(previous=>previous===s.historyError?'':previous);s.historyError=null;
	 }catch(e){if(s.sync!==current)return;s.historyError=e.message||String(e);throw e;}
	 finally{if(s.sync===current){s.heatBusy=false;s.historyPending=new Set();paintHistory();redraw();}}return;
	}
  if(s.kind!=='heat'||!s.doc||s.heatBusy||s.loading)return;
  if(!auto&&!await leave())return;
  const from=`${s.year}-11-05`,end=`${s.year+1}-04-06`,today=new Date(Date.now()+8*3600000).toISOString().slice(0,10),to=today<end?today:end;
  if(to<from){if(!auto)setError('本采暖季尚未开始');return;}
  const current=s.sync;s.heatBusy=true;
  try{await api('POST',path('/heat-sync'),{from,to,auto});if(s.sync!==current)return;await refresh();if(!s.sync.dirty)setStatus(s.doc.can_edit?'已保存':'只读');}
  finally{s.heatBusy=false;}
 }
 async function heatDetails(){const v=await api('GET',path('/heat-readings'));setModal({type:'readings',items:v.items});}
 async function sourceSettings(){const v=await api('GET',`${root}/heat-bindings`);setModal({type:'source',...v});}
 async function importTemplate(file){
  if(!file)return;if(file.size>12*1024*1024)throw new Error('模板超过12MiB');
  const template=JSON.parse(await file.text());
  await api('POST',`${root}/templates`,template);await readCatalog();setStatus('模板已导入，新建年度将使用此模板');
  if(!s.doc)await open(template.kind,s.year);
 }
 const workbookHooks=useMemo(()=>({
  beforeCellMouseDown:()=>{s.interacted=true;return true;},
  afterSelectionChange:selectionChanged,
  beforeUpdateCell:()=>true,
  beforePaste:(range,content)=>{void paste(range,content).catch(report);return false;},
  beforeAddSheet:()=>false,beforeDeleteSheet:()=>false,
  afterRenderCell:(cell,info,ctx)=>{const l=s.locks.find(v=>v.client!==client&&v.address===address(info.row,info.column));if(l){ctx.save();ctx.strokeStyle='#a46633';ctx.lineWidth=2;ctx.strokeRect(info.startX+1,info.startY+1,info.endX-info.startX-2,info.endY-info.startY-2);ctx.restore();}}
 }),[]);
 useEffect(()=>{
  const receive=m=>{
   if(m.type==='apiResult'){const call=calls.get(m.id);if(!call)return;calls.delete(m.id);clearTimeout(call.timer);if(m.error){const e=new Error(m.error);e.status=m.status;call.reject(e);}else call.resolve(m.result);}
   if(m.type==='ping')emit({type:'response',id:m.id,result:true});
   if(m.type==='leave')void leave().then(result=>emit({type:'response',id:m.id,result})).catch(e=>{report(e);emit({type:'response',id:m.id,error:'报表提交失败，请返回核对未保存内容'});});
  };
  const unload=e=>{if(s.sync?.dirty){e.preventDefault();e.returnValue='';}};
  const stopReceiving=listenToHost(window,channel,receive);window.addEventListener('beforeunload',unload);
  emit({type:'ready'});
  void readCatalog().then(items=>{if(items.length)return open(items.find(x=>x.kind==='heat')?.kind||items[0].kind,s.year);setStatus('尚未导入报表模板，请由工程师导入随交付提供的三份模板。');}).catch(report);
  const poll=setInterval(()=>void refresh(),2000);
  const heatPoll=setInterval(()=>{if(s.doc?.template.history?.length||s.kind==='heat')void syncHeat(true).catch(report);},300000);
  const livePoll=setInterval(()=>{if(s.history?.some(v=>v.provisional))void syncHeat(true,true).catch(report);},60000);
  const renew=setInterval(()=>{
   if(!s.leaseActive||!s.owned.size||!s.doc?.can_edit)return;
   const current=s.sync,target=path('/locks');
   void s.leaseQueue.run(async()=>{
    if(current!==s.sync||!s.leaseActive)return;
    const addresses=[...new Set([...s.selection,...s.sync.pending.keys()])];
    const v=await api('POST',target,{client,addresses});
    if(current===s.sync){s.owned=new Map(v.items.map(x=>[x.address,x]));redraw();}
   }).catch(report);
  },10000);
  return()=>{clearInterval(poll);clearInterval(heatPoll);clearInterval(livePoll);clearInterval(renew);clearTimeout(s.saveTimer);stopReceiving();window.removeEventListener('beforeunload',unload);};
 },[]);
 const act=fn=>()=>Promise.resolve(fn()).catch(report);
 const others=s.locks.filter(l=>l.client!==client&&l.expires*1000>Date.now());
 return <main className="report-shell" data-revision={s.sync?.revision??0} data-view={view}>
  <aside className="report-sidebar"><h1>总统计报表</h1><label>年份<select aria-label="年份" value={s.year} disabled={s.loading||s.opening} onChange={e=>void open(s.kind,Number(e.target.value))}>{Array.from({length:101},(_,i)=>2000+i).map(y=><option key={y}>{y}</option>)}</select></label>{names[s.kind]&&<p className="hint">{s.year}.11.05 — {s.year+1}.04.05</p>}<nav>{catalog.map(({kind,name})=><button key={kind} className={s.kind===kind?'selected':''} onClick={()=>void open(kind,s.year)} disabled={s.loading||s.opening}>{names[kind]||name}<small>{kind==='heat'?'后台表底':'手工填报'}</small></button>)}</nav>
   {development&&<div className="setup">{configure&&<><button onClick={()=>{s.upload=null;setModal({type:'new-page',id:randomID(),name:'',sheets:[]});}}>添加页面</button><label className="file-button">导入报表模板<input type="file" accept=".json" onChange={e=>void importTemplate(e.target.files[0]).catch(report)}/></label>{s.doc&&!s.doc.template.original&&<button onClick={()=>{s.upload=null;setModal({type:'original',name:reportName(s.kind),sheets:[]});}}>补充导出原稿</button>}</>}{configure&&<button onClick={act(sourceSettings)}>热量数据源</button>}</div>}
  </aside>
  <section className="workspace"><header className="report-header"><strong>{reportName(s.kind)} · {s.year}</strong><div className="actions"><span className="save-state" role="status">{status}</span>{s.doc?.can_export&&<button disabled={s.loading||s.busy} onClick={act(exportFile)}>导出 Excel</button>}<button className="history-button" disabled={!s.doc} onClick={act(checkpoints)}>历史记录</button></div></header>
  <ReportTools configure={development&&configure} getDocument={()=>s.doc?{...s.doc,revision:s.sync?.revision??s.doc.revision}:null} getSelection={()=>selectionAddress(ref.current?.getSelection()?.[0])} prepare={async()=>{if(!await leave())return false;await refresh();return true;}} reopen={async kind=>{await readCatalog();await open(kind||s.kind,s.year);}} refreshHistory={()=>syncHeat()} historyBusy={!!s.heatBusy} api={api} path={path} emit={emit} onError={report}/>
  {(s.heatBusy||historyNotice(s.history||[])||s.kind==='heat')&&<div className="history-state" role="status">{s.heatBusy?'正在获取历史数据… ':''}{historyNotice(s.history||[])}{s.kind==='heat'&&<span> 时间列00:00为日界；用量行采用次日00:00期末表底。</span>}</div>}
  {others.length>0&&<div className="presence">{others.slice(0,6).map(l=>`${l.name}（另一窗口）正在编辑 ${l.address}`).join(' · ')}{others.length>6?` 等 ${others.length} 格`:''}</div>}
  {error&&<div className="error" role="alert">{error}{s.sync?.dirty&&<button onClick={act(save)}>重试保存</button>}<button onClick={()=>setError('')}>收起</button></div>}
  {s.sync?.conflicts.size>0&&<div className="conflicts">{[...s.sync.conflicts].map(([a,c])=><div key={a}>{a}：我的内容「{c.mine}」；已保存「{c.theirs}」<button onClick={act(async()=>{s.sync.resolve(a,false);applyCells([{address:a,value:c.theirs}]);redraw();})}>采用已保存内容</button><button onClick={act(async()=>{s.sync.resolve(a,true);if(await acquire([...s.sync.pending.keys()]))await save();})}>重新锁定并保存我的内容</button></div>)}</div>}
  <div className="sheet" onPointerDown={()=>s.interacted=true} onKeyDownCapture={e=>{s.interacted=true;if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='a'&&e.target.isContentEditable)e.stopPropagation();}}>{book?<SheetErrorBoundary key={generation} onError={e=>{s.displayFailed=true;report(e);emit({type:'viewError'});}}><Workbook ref={ref} data={book} lang="zh" allowEdit={!!s.doc?.can_edit} showToolbar={true} toolbarItems={toolbarItems} showSheetTabs={false} showFormulaBar={true} cellContextMenu={['copy','paste']} headerContextMenu={[]} sheetTabContextMenu={[]} onChange={changed} hooks={workbookHooks} addRows={0}/></SheetErrorBoundary>:<div className="empty">{status}<button onClick={act(async()=>{await readCatalog();await open(s.kind,s.year);})}>重新加载</button></div>}</div>
  </section>
  {modal&&<div className="shade"><section className="dialog" role="dialog"><header className="report-header"><strong>{({'new-page':'添加报表页面',original:'补充导出原稿',checkpoints:'历史记录',confirm:'恢复历史内容',source:'热量数据源',readings:'热量取数明细'})[modal.type]}</strong><button disabled={modal.busy} onClick={()=>setModal(null)}>关闭</button></header>
   {['new-page','original'].includes(modal.type)&&<div className="page-form">{modal.type==='new-page'&&<label>页面名称<input aria-label="页面名称" maxLength={40} value={modal.name} disabled={modal.busy} onChange={e=>setModal({...modal,name:e.target.value})}/></label>}<label>Excel文件<input type="file" accept=".xlsx" disabled={modal.busy} onChange={e=>void chooseExcel(e.target.files[0]).catch(report)}/></label>{modal.sheets.length>0&&<label>工作表<select aria-label="工作表" value={modal.sheet} disabled={modal.busy} onChange={e=>setModal({...modal,sheet:e.target.value})}>{modal.sheets.map(name=><option key={name}>{name}</option>)}</select></label>}<p className="hint">{modal.type==='original'?'请选择此页面最初使用的Excel工作表。只补充完整导出格式，不更改已填写内容；原稿保存后不再替换。':'每个页面导入一张工作表，各年份独立保存。导出保留原边框、行高、条件格式、打印设置、冻结位置与工作表名称。跨工作表公式会提示调整。'} 旧版.xls请先在Excel中另存为.xlsx，再上传。</p>{error&&<p role="alert" className="error">{error}</p>}<button disabled={modal.busy||!modal.sheet||!modal.name.trim()} onClick={act(createPage)}>{modal.busy?'正在保存…':modal.type==='original'?'保存原稿':'创建页面'}</button></div>}
   {modal.type==='checkpoints'&&<><p>编辑会自动保存。恢复历史内容前，也会保留一份当前内容。</p>{s.doc.can_edit&&<button onClick={act(async()=>{await makeCheckpoint();await checkpoints();})}>保留当前版本</button>}<div className="rows">{modal.items.map(cp=><div className="record" key={cp.id}><span>{new Date(cp.created*1000).toLocaleString()}<small>{cp.reason.replace('定时检查点','自动保存').replace('手动检查点','手动保留').replace('检查点','历史版本').replace(/回滚至 .*/,'恢复后的内容').replace('回滚前','恢复前的内容')}</small></span>{s.doc.can_rollback&&<button onClick={()=>void rollback(cp)}>恢复此版本</button>}</div>)}{!modal.items.length&&<p>暂无历史记录。</p>}</div></>}
   {modal.type==='confirm'&&<><p>将本年度可编辑内容回滚到 {new Date(modal.cp.created*1000).toLocaleString()}。自动表底保持当前数据。</p><button onClick={()=>void performRollback(modal.cp)}>确认回滚</button></>}
   {modal.type==='source'&&<><label>历史数据连接<select defaultValue={modal.settings.screen} onChange={e=>setModal({...modal,settings:{...modal.settings,screen:e.target.value}})}><option value="">请选择</option>{modal.sources.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select><button onClick={act(async()=>{await api('POST',`${root}/heat-bindings`,modal.settings);setModal(null);await syncHeat();})}>保存</button></label><p>按北京时间当日00:00至次日00:00统计；时间列显示00:00，用量行的正式表底为次日零点。取零点前后30分钟内最近采样，未到次日零点时可显示本日最新采样，作为未结算暂计值。</p><button onClick={act(syncHeat)}>重新读取</button><button onClick={act(heatDetails)}>查看取数明细</button></>}
   {modal.type==='readings'&&<div className="rows">{modal.items.map(x=><div className="record" key={x.address}><span>{x.address} · {x.date}<small>{x.station} / {x.point}</small></span><span>{x.value??'缺测'} GJ<small>采样：{x.sample_time||'—'} · 质量 {x.quality??'—'}</small></span></div>)}</div>}
  </section></div>}
 </main>;
}
createRoot(document.getElementById('root')).render(<App/>);


