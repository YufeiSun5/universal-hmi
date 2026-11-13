import React,{useState} from 'react';
import {ReportFilePicker} from './ReportFilePicker.jsx';

const root='/api/v1/total-reports';
function encode(bytes){let text='';for(let i=0;i<bytes.length;i+=32768)text+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(text);}

export function PageManager({disabled,getDocument,prepare,reopen,removed,api}){
 const [modal,setModal]=useState(null),[busy,setBusy]=useState(false),[error,setError]=useState('');
 const run=fn=>async()=>{setBusy(true);setError('');try{await fn();}catch(e){setError(e.message||String(e));}finally{setBusy(false);}};
 const edit=patch=>setModal(m=>({...m,...patch,preview:null,confirmed:false}));
 async function open(){
  if(!await prepare())return;
  const d=getDocument(),archived=await api('GET',root+'/archived-pages');
  const current=d?.kind?.startsWith('page_')?await api('GET',root+'/pages/'+d.kind):null;
  setModal({type:'manage',current,year:d?.year,revision:d?.revision,archived:archived.items,sheets:[],sheet:'',workbook:null,preview:null,confirmed:false});
 }
 async function choose(file){
  if(!file)return;if(!/\.xlsx$/i.test(file.name)||file.size>9*1024*1024)throw Error('请选择不超过9MiB的.xlsx文件');
  const bytes=new Uint8Array(await file.arrayBuffer()),XLSX=await import('xlsx'),book=XLSX.read(bytes,{type:'array',bookSheets:true});
  edit({file:file.name,workbook:{data:encode(bytes),sheet:book.SheetNames[0]},sheets:book.SheetNames,sheet:book.SheetNames[0]});
 }
 async function preview(){
  if(!await prepare())return;const d=getDocument();if(d?.kind!==modal.current.kind||d.year!==modal.year)throw Error('当前页面已变化，请重新打开页面管理');
  const p=await api('POST',`${root}/${d.kind}/${d.year}/replace-preview`,{workbook:modal.workbook,expected:d.revision});
  setModal(m=>({...m,revision:d.revision,preview:p,confirmed:false}));
 }
 async function replace(){
  if(!await prepare())return;
  await api('POST',`${root}/${modal.current.kind}/${modal.year}/replace`,{workbook:modal.workbook,expected:modal.revision,token:modal.preview.token,confirm:true});
  setModal(null);await reopen(modal.current.kind);
 }
 async function chooseAction(info,type){
  if(!await prepare())return;
  const current=await api('GET',root+'/pages/'+info.kind);setModal(m=>({...m,type,target:current,confirmed:false,preview:null}));
 }
 async function applyAction(){
  if(!await prepare())return;
  const target=modal.target,type=modal.type;
  await api('POST',`${root}/pages/${target.kind}/${type}`,{token:target.token,confirm:true});
  setModal(null);if(type==='delete')await removed(target.kind);else await reopen(target.kind);
 }
 return <>
  <fieldset className="report-tools" disabled={disabled||busy}><button onClick={run(open)}>页面管理</button></fieldset>
  {error&&!modal&&<span role="alert">{error}</span>}
  {modal&&<div className="shade"><section className="dialog report-designer" role="dialog" aria-label="页面管理">
   <header className="report-header"><strong>页面管理</strong><button disabled={busy} onClick={()=>{setModal(null);setError('');}}>关闭</button></header>
   {error&&<p className="error" role="alert">{error}</p>}
   <fieldset className="designer-fields" disabled={busy}>
   {modal.type==='manage'?<>
    {modal.current?<>
     <h3>{modal.current.name} · {modal.year} 年</h3>
     <p>替换当前年份的整张页面，保留名称和入口。其他年份及新建年度模板不变。</p>
     <p>上传文件中的数值、公式和格式将覆盖当前年份全部内容，旧绑定会移除。替换前自动备份，可在“配置历史”恢复。</p>
     <div className="page-form"><ReportFilePicker label="替换Excel" title="新版 Excel" accept=".xlsx" disabled={busy} fileName={modal.file} onFile={file=>void run(()=>choose(file))()}/>
     {modal.sheets.length>0&&<label>工作表<select aria-label="替换工作表" value={modal.sheet} onChange={e=>edit({sheet:e.target.value,workbook:{...modal.workbook,sheet:e.target.value}})}>{modal.sheets.map(x=><option key={x}>{x}</option>)}</select></label>}
     <button disabled={!modal.workbook} onClick={run(preview)}>预览整页替换</button>
     {modal.preview&&<><p>原 {modal.preview.old_rows} 行 × {modal.preview.old_columns} 列 → 新 {modal.preview.rows} 行 × {modal.preview.columns} 列；覆盖整表，含 {modal.preview.edited_cells} 个手填修改格，移除 {modal.preview.bindings} 组历史绑定。</p><label className="confirmation"><input type="checkbox" checked={modal.confirmed} onChange={e=>setModal({...modal,confirmed:e.target.checked})}/>确认以文件内容替换 {modal.year} 年整页（含已填数据）</label><button className="primary" disabled={!modal.confirmed} onClick={run(replace)}>确认替换当前年份</button></>}
     </div><hr/><button onClick={run(()=>chooseAction(modal.current,'delete'))}>删除此页面…</button>
    </>:<p>此处管理自行添加的报表页面。热、电、水为内置报表。</p>}
    <h3>已删除页面</h3><p>删除后从目录移除，全部年份、已填内容及历史仍保留。恢复需要报表恢复权限。</p>
    {modal.archived.length===0?<p>暂无已删除页面。</p>:modal.archived.map(x=><div className="record" key={x.kind}><span>{x.name}</span><button onClick={run(()=>chooseAction(x,'restore'))}>恢复页面…</button></div>)}
   </>:<>
    <h3>{modal.type==='delete'?'删除':'恢复'}「{modal.target.name}」</h3>
    <p>涉及全部已创建年份：{modal.target.years.map(y=>y.year).join('、')||'尚未创建年度'}。</p>
    <p>{modal.type==='delete'?'页面将从所有终端目录中移除，已有页面也将停止读写。全部数据保留，可在“已删除页面”恢复。':'恢复后页面重新出现在目录中，保留原来的名称、各年份内容和历史。'}</p>
    <label className="confirmation"><input type="checkbox" checked={modal.confirmed} onChange={e=>setModal({...modal,confirmed:e.target.checked})}/>已核对页面名称和年份，确认{modal.type==='delete'?'删除':'恢复'}</label>
    <div className="designer-actions"><button onClick={run(open)}>返回</button><button className="primary" disabled={!modal.confirmed} onClick={run(applyAction)}>确认{modal.type==='delete'?'删除页面':'恢复页面'}</button></div>
   </>}
   </fieldset>{busy&&<p role="status">正在处理…</p>}
  </section></div>}
 </>;
}
