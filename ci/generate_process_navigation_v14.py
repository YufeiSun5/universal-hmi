from pathlib import Path
import json,copy,hashlib,collections
root=Path(__file__).resolve().parents[1];src=root/'outputs/process-scanned-numeric-20261029/扫描变量后导入工艺-数值类型适配.json';dst=root/'outputs/process-navigation-v14-20261030';dst.mkdir(exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(n,o):(dst/n).write_text(json.dumps(o,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
original=json.loads(src.read_text(encoding='utf-8'));result=copy.deepcopy(original);r=result['retry_request'];b=r['bundle'];old=original['retry_request']['bundle'];removed=[];locations=set();main_proof=[]
for screen in b['screens']:
 d=screen['document'];old_d=next(x['document'] for x in old['screens'] if x['key']==screen['key']);title=next(n for n in d['nodes'] if n['id']=='supplement-title');new_width=title['x']-20;assert d['width']-new_width==620
 keep=[]
 for n in d['nodes']:
  if n['id'].startswith('original-') or n['id'] in ('supplement-title','handoff-topology-warning'):
   locations.add((screen['key'],n['id']));removed.append({'screen_key':screen['key'],'station':d['station'],'node':copy.deepcopy(n),'reason':'user_requested_right_supplement_column_removal' if n['id']!='handoff-topology-warning' else 'misleading_all_unbound_static_warning'})
  else:
   if n['id']=='monitor-backdrop':n['width']=new_width
   keep.append(n)
 d['nodes']=keep;d['width']=new_width
 for n in keep:
  old_n=next(x for x in old_d['nodes'] if x['id']==n['id']);expected=copy.deepcopy(old_n)
  if n['id']=='monitor-backdrop':expected['width']=new_width
  assert n==expected
 main_proof.append({'screen_key':screen['key'],'old_width':old_d['width'],'new_width':new_width,'main_nodes_preserved':len(keep),'main_geometry_and_ids_unchanged':True,'only_backdrop_width_trimmed':True})
removed_bindings=[x for x in b['bindings'] if (x['screen_key'],x['node_id']) in locations];b['bindings']=[x for x in b['bindings'] if (x['screen_key'],x['node_id']) not in locations]
assert b['bindings']==[x for x in old['bindings'] if (x['screen_key'],x['node_id']) not in locations]
required={x['variable_key'] for x in b['bindings'] if x.get('variable_key')};orphan=[v for v in b['variables'] if v['key'] not in required];b['variables']=[v for v in b['variables'] if v['key'] in required];r['variable_targets']={k:v for k,v in r['variable_targets'].items() if k in required}
assert len(required)==len(b['variables'])==313 and len(b['bindings'])==782
assert len({v['definition']['source_path'] for v in b['variables']})==313 and all(v['mode']=='match_existing' for v in r['variable_targets'].values())
# Explicit station grouping from original menu tree and handoff context; no KIO-owner inference.
groups=[('中心站',['中心站东南区','中心站西北区']),('北站3#炉',['原北3#光明区','原北3#东方区','原北3#伟业区']),('新北站',['新北站北线','新北站南线']),('新南站',['新南站南线区','新南站文汇线区','新南站东线区','新南站新华线区']),('国奥一期',['国奥一期']),('国奥二期',['国奥二期高区','国奥二期低区']),('国奥首站',['国奥首站']),('张屯站',['张屯站']),('红光美苑',['红光美苑首站','红光美苑低区','红光美苑高区']),('金岳福里',['金岳福里高区']),('阳光壹佰',['阳光壹佰高区','阳光壹佰低区']),('香港广场',['香港广场长兴区','香港广场党校区']),('华府怡景',['华府怡景低区','华府怡景原阳光壹佰']),('新西站',['新西站南线区','新西站北线区'])]
by_station={s['document']['station']:s for s in b['screens']};nav=[];mapping=[]
for label,stations in groups:
 parent_id='menu-'+hashlib.sha256(label.encode()).hexdigest()[:20];children=[]
 for station in stations:
  screen=by_station[station];leaf={'id':'screen-'+screen['key'][11:],'label':station,'screen_key':screen['key']};children.append(leaf);mapping.append({'parent':label,'station':station,'screen_key':screen['key']})
 nav.append({'id':parent_id,'label':label,'children':children})
assert len(mapping)==28 and {x['screen_key'] for x in mapping}=={s['key'] for s in b['screens']}
b['navigation']={'enabled':True,'nodes':nav};r['navigation_target']={'mode':'skip'}
r['import_identity']='zhuanghe-scan-existing-process-20261029-v10'
# Only screen business stations; variable ownership remains unchanged by import.
r['station_map']={s['document']['station']:s['document']['station'] for s in b['screens']};r['create_stations']=list(r['station_map'])
audit={'source_sha256':sha(src),'removed_nodes':removed,'removed_bindings':removed_bindings,'removed_orphan_requirements':orphan,'main_screen_proof':main_proof,'original_counts':{'screens':28,'variables':385,'bindings':912},'new_counts':{'screens':28,'variables':313,'bindings':782,'set':386,'keep':396},'removed_counts':{'nodes':len(removed),'bindings':len(removed_bindings),'set':85,'keep':45,'orphan_variable_requirements':len(orphan)},'main_bindings_exactly_preserved':True,'source_path_unique':True,'no_variable_creation_or_ownership_migration':True}
assert collections.Counter(x['operation'] for x in b['bindings'])=={'set':386,'keep':396}
write('创建画面与绑定-主图父子导航-v14.json',result);write('右栏移除与主图绑定审计.json',audit);write('客户端父子导航映射.json',{'navigation':b['navigation'],'mapping':mapping,'import_default':'skip_existing_navigation_requires_user_choice','development_stations_remain_flat':True})
write('verification.json',{'source_sha256':sha(src),'delivery_sha256':sha(dst/'创建画面与绑定-主图父子导航-v14.json'),'screens':28,'variable_requirements':313,'bindings':782,'confirmed_set':386,'unconfirmed_keep':396,'removed_bound_sidebar_references':85,'orphan_requirements_removed':72,'navigation_parents':14,'navigation_leaves':28,'navigation_default':'skip','main_binding_proof':main_proof,'production_modified':False})
print(json.dumps(audit['new_counts'],ensure_ascii=False));print(dst)

(dst/'README.txt').write_text('v14 主图画面、绑定与客户端父子菜单资料\n\n推荐文件：创建画面与绑定-主图父子导航-v14.json\n本资料不用于导入预制变量，不自动迁移变量归属，不自动连接MQTT或应用配置。\n\n操作顺序\n1. 保留现有真实MQTT数据源和已扫描变量，先检查变量可正常取数。不必重新扫描、复制或导入313项定义；包内定义只是按唯一source_path匹配的依据。\n2. 在工艺导入界面选择目标数据源。全部变量目标必须保持“匹配已有”，不得改为创建变量；匹配不唯一或未找到时先核对数据源与路径，不能按名称猜测。\n3. 已有同一批已导入画面时，明确选择“精确更新已导入画面”（update_imported），按原import_identity、screen_key及目标站定位，不按名称猜测；手工更新须明确当前版本。新建工程才选择创建。包内需要的业务站只用于画面归类，导入画面不会把已有IO-01变量迁到业务站。\n4. 客户端父子菜单可随工艺导入。为保护现有导航，本文件默认跳过导航；用户确认后，在界面选择“创建”或“替换现有菜单”。创建仅允许空菜单；替换必须明确确认并使用当前导航版本。开发端站点仍为平铺列表。\n5. 需要实际整理变量归属时，另用“按工艺画面分站”：预览单站建议，核对后保存并保留回退JSON。共享及未引用变量不自动改站。保存定义不等于应用配置；核对后显式应用，再验证取数和画面。旧站存在运行引用时不能删除。\n\n画面与绑定范围\n- 28张主图稳定节点ID、坐标、真实绑定逐项保持；右侧补充栏整体删除，画布宽度相应收回620像素，主图不横向压缩。\n- 删除右栏的85条确定绑定和45条待核引用，详见“右栏移除与主图绑定审计.json”；审计记录保留原节点和绑定证据，不会再要求这些被删除节点参与导入。\n- 主图保留386条确定绑定和396条待核引用。未确认引用维持keep/空，不按同名或位置猜测绑定。\n- 只要求主图实际引用的313个唯一source_path，已去除72个孤儿匹配要求。不会删除或复制工程中的其他变量。\n- 移除误导性的“全部未绑定”静态提示。原PICX精确管线拓扑和现场设备数量仍需用户核实；本资料不是现场控制或设备数量验收证明。\n\n普通安装升级保留现有变量、采集配置、账号权限、工艺、绑定和历史，不触发一次性工程清理。本轮不提供ZIP资料。\n\n导航映射说明：红光美苑首站原PIC文件位于“张屯站”目录，本客户端按实际画面显示名称归入“红光美苑”父菜单；这不代表现场物理归属已确认，也不迁移任何变量。\n',encoding='utf-8')
raw=root.parent/'KS_HELP/outputs/01a18568_pic_analysis/模板与点位交接.json'
menu=root.parent/'KS_HELP/output/庄河菜单_双引用与独立画面/服务端_菜单树_点击时_新南站四区_景泰金岳独立画面.txt'
from pathlib import PureWindowsPath
handoff=json.loads(raw.read_text(encoding='utf-8-sig'));contexts={x['station']:x for x in handoff['screens'] if x['screenType']=='process_flow'}
assert set(contexts)==set(by_station)
navfile=dst/'客户端父子导航映射.json';nv=json.loads(navfile.read_text(encoding='utf-8'))
for entry in nv['mapping']:
 context=contexts[entry['station']];entry['evidence']={'handoff_screen_id':context['screenId'],'page_id':context['pageId'],'page_name':context['pageName'],'source_filename':PureWindowsPath(context['sourceFile']).name,'source_directory':PureWindowsPath(context['sourceFile']).parent.name,'source_sha256':context['sourceSHA256'],'shared_reference_expansion':context['sharedExpansion']['isShared']}
nv['evidence']={'handoff_sha256':sha(raw),'menu_sha256':sha(menu),'source_direct_and_shared_contexts_checked':True,'review_note':'红光美苑首站源PIC目录为张屯站；客户端按画面名称归红光美苑父组，主代理已确认；不等同物理归属核实。'}
write(navfile.name,nv)
verification=json.loads((dst/'verification.json').read_text(encoding='utf-8'));verification['generator_sha256']=sha(Path(__file__));verification['files_sha256']={p.name:sha(p) for p in dst.iterdir() if p.is_file() and p.name!='verification.json'};write('verification.json',verification)
