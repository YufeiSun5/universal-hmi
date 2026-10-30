import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {pathToFileURL} from 'node:url';
const read=p=>JSON.parse(fs.readFileSync(p,'utf8').replace(/^\uFEFF/,''));
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
export function resolvePoint(r,points,mapping){
 if(!['explicit_legacy_io','documented_latest_mapping'].includes(r.kioCertainty))return {point_id:'',reason:'unconfirmed_evidence'};
 if(!r.kioServerAccessPath)return {point_id:'',reason:'no_exact_source_path'};
 if(!mapping?.source_id||!mapping?.topic||mapping.source_path!==r.kioServerAccessPath)return {point_id:'',reason:'explicit_source_topic_mapping_required'};
 const m=points.filter(p=>p.source_id===mapping.source_id&&p.topic===mapping.topic&&p.source_path===mapping.source_path);
 if(m.length!==1)return {point_id:'',reason:m.length?'ambiguous_path':'path_not_found'};
 if(!m[0].id)throw Error('Missing stable ID');
 return {point_id:m[0].id,reason:'exact_source_path',owner_station:m[0].station,source:m[0].source};
}
const txt=(id,text,x,y,width=1480)=>({id,kind:'text',x,y,width,height:28,text,label:'',color:'#C9DAE7',fill:'none',font_size:15,stroke_width:1,point_id:'',points:[],rotation:0,decimals:1,show_unit:true,arrow:false});
export function build(h,c,dir){const audit=[],screens=[];
 for(const s of h.screens.filter(s=>s.screenType==='process_flow')){
  const t=s.observedStructure.circulationReadoutGroups===2?'heating-single-two':s.recommendedBaseTemplateId,d=read(path.join(dir,t+'.json'));
  d.id='ks-process-'+hash(s.screenId).slice(0,20);d.revision=0;d.name=s.station+' · 工艺';d.station=s.station;delete d.template_id;delete d.template_revision;delete d.bindings;
  const used=new Set(),extras=[];
  for(const n of d.nodes){n.point_id='';if(n.kind==='pipe'){n.arrow=false;delete n.arrow_visible_rule;delete n.arrow_motion_rule;}if(n.kind==='value')n.label=(n.label||n.id)+' · 待绑定';}
  for(const r of h.points.filter(p=>p.screenId===s.screenId)){
   // This handoff is deliberately all-unbound, even if a supplied catalog contains matches.
   const z={point_id:'',reason:'field_binding_deferred'},a={screen_id:d.id,context:s.screenId,record_id:r.id,original_binding:r.actualKS||r.original,meaning:r.semantic?.boundVariableName||'',layout_role:r.semantic?.displayPositionRole||'',issues:r.issues||[],certainty:r.kioCertainty,source_path:r.kioServerAccessPath,...z,node_id:null};
   if(r.kind==='脚本'||r.kioCertainty==='ui_only'){a.reason='ui_or_script_excluded';a.point_id='';audit.push(a);continue;}
   const candidate=r.templateValueNodeCandidate;
   const n=candidate&&candidate!=='primary-downstream-pressure'&&!used.has(candidate)&&!a.issues.length?d.nodes.find(n=>n.id===candidate&&n.kind==='value'):null;
   if(n){used.add(candidate);n.point_id=z.point_id;n.label=a.meaning+(z.point_id?'':' · 待绑定');a.node_id=n.id;}
   else if(r.format?.includes('#'))extras.push({r,a,z});
   else{a.reason=z.point_id?'graphic_state_not_imported':a.reason;a.point_id='';}
   audit.push(a);
  }
  d.background={type:'solid',color:'#162F45',opacity:1};d.nodes=d.nodes.filter(n=>n.id!=='monitor-backdrop');
  d.nodes.push(txt('handoff-topology-warning','模板示意，拓扑待核。全部未绑定；泵组读数不代表已核实设备数量。',24,60));
  // Fixed-height side panel avoids making the primary diagram unreadably small.
  if(extras.length){const x=d.width+20,w=580;d.nodes.push(txt('supplement-title','补充测点（保留原量义，现场待绑定）',x,24,w));
   const rowH=Math.min(80,(d.height-100)/extras.length);
   extras.forEach(({r,a,z},i)=>{const yy=72+i*rowH,id='original-'+r.id.toLowerCase();
    const raw=a.meaning.replace(/^引用(?:模型)?\d+\./,'');
    const name=raw.startsWith(s.station)?raw.slice(s.station.length):raw;
    const label=(a.layout_role&&!a.layout_role.includes('按变量名')&&!a.layout_role.includes('图形或脚本')?a.layout_role+'：':'')+name;
    d.nodes.push({...txt(id+'-label',label,x,yy,w),font_size:14,height:Math.max(25,rowH-30)});
    d.nodes.push({...txt(id,'',x,yy+Math.max(25,rowH-30),w),kind:'value',height:25,label:a.meaning+' · 待绑定',point_id:'',font_size:17,color:'#EDE94B',unit_override:''});a.node_id=id;});
   d.width=x+w+20;
  }
  screens.push({document:d,source_context:s.screenId,template:t,station_exists:(c.stations||[]).some(x=>(typeof x==='string'?x:x.name)===s.station),source_sha256:s.sourceSHA256});
 }return {screens,audit};}
export function writeExclusive(file,data){const body=JSON.stringify(data,null,2)+'\n';if(fs.existsSync(file)){if(fs.readFileSync(file,'utf8')!==body)throw Error('Refusing changed output: '+file);return;}fs.writeFileSync(file,body,{flag:'wx'});}
export function main(args){const [input,out,catalog]=args;if(!input||!out)throw Error('Usage: HANDOFF OUTPUT [CATALOG]');const h=read(input),c=catalog?read(catalog):{points:[],stations:[]},r=build(h,c,'app/assets/process/templates');fs.mkdirSync(path.join(out,'screens'),{recursive:true});for(const s of r.screens)writeExclusive(path.join(out,'screens',s.document.id+'.json'),s.document);writeExclusive(path.join(out,'binding-audit.json'),r.audit);writeExclusive(path.join(out,'dry-run.json'),{input_sha256:hash(fs.readFileSync(input)),catalog_sha256:catalog?hash(fs.readFileSync(catalog)):null,screen_count:r.screens.length,excluded:h.screens.filter(s=>s.screenType!=='process_flow').map(s=>s.screenId),bound:r.audit.filter(a=>a.point_id&&a.node_id).length,unbound:r.audit.filter(a=>a.node_id&&!a.point_id).length,plan:r.screens.map(({document,...s})=>({...s,id:document.id,station:document.station,request:{method:'PUT',path:'/api/v1/screens/'+document.id,revision:0},preflight:'GET:404=create; identical existing=skip; any difference=abort. No overwrite.'}))});console.log(JSON.stringify({screens:r.screens.length,bound:r.audit.filter(a=>a.point_id&&a.node_id).length,out}));}
if(process.argv[1]&&import.meta.url===pathToFileURL(path.resolve(process.argv[1])).href)main(process.argv.slice(2));

