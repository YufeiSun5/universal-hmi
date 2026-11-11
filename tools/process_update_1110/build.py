"""Rebuild all process content from the supplied 1110 native drawings and IO.

Old deliveries supply identity and rollback only. No live project/network writes.
Pillow is needed by the established native primitive renderer.
"""
from pathlib import Path
import collections, copy, csv, hashlib, importlib.util, json, re, struct, sys, zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SRC = Path('D:/Users/SunYufei/Downloads')
OUT = ROOT / 'outputs/庄河1110更新包'
CHECK = ROOT / '.local/process-update-v66'
CROSS = Path('D:/DEV_D/KS_HELP/output/庄河实时与存储_1110更新')
HTML = Path('D:/DEV_D/ZhuangHe16/庄河HTML')
DUAL = Path('D:/DEV_D/KS_HELP/output/庄河31站区双阀变量_1110')
sys.path[:0] = [str(ROOT/'tools/picx_restore_1103'),str(ROOT/'tools')]
from layout import make, p
from arrows import apply as native_arrows

def load(path): return json.loads(Path(path).read_text('utf-8-sig'))
def save(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(data,ensure_ascii=False,separators=(',',':'))+'\n',encoding='utf8')
def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def csvload(path):
    return {r['TagName']:r for r in csv.DictReader(Path(path).open(encoding='gb18030',newline=''))}
def report(name,header,rows):
    with (OUT/'核对资料'/name).open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.writer(f);w.writerow(header);w.writerows(rows)

def main():
    for d in [OUT/'核对资料',OUT/'回退',CHECK]:d.mkdir(parents=True,exist_ok=True)
    old=load(ROOT/'outputs/工艺状态液位更新-20261105/01-31张工艺图状态液位更新.json')['retry_request']
    actual=load(SRC/'process-bundle.json')
    oldoverview=load(ROOT/'outputs/庄河1104更新包/02-数据总览配置.json')
    ks={t.attrib['TagName']:t.attrib for t in ET.parse(SRC/'ks变量1110.xml').iter('Tag')}
    kio=csvload(SRC/'kio变量1110.csv');prior=csvload(SRC/'Downloads/kio变量1104.csv')
    assert (len(ks),len(kio),len(kio.keys()-prior.keys()))==(5156,5150,31)
    source=next(iter(old['source_map']));assert source=='source-1793013239860'
    existing=collections.defaultdict(list)
    for v in actual['variables']:
        d=v['definition']
        if d.get('source_id')==source:existing[d.get('source_path')].append(v)
    types={'IODisc':'BOOL','IOFloat':'FLOAT','IOLong':'INT','IOShort':'INT','IOULong':'INT','IOUShort':'INT','IODouble':'FLOAT'}
    variables={};new_variables=[];catalog=[]
    for name in sorted(kio.keys()-prior.keys()):
        t=kio[name];assert t['Enable']=='是' and t['ConvertType'] in ('','无') and not existing[name]
        key='kio1110-'+p.digest(name.encode())[:20]
        d=dict(station='IO-01',name=name,data_type=types[t['TagDataType']],source_type='mqtt',source_id=source,
               source_path=name,unit=t['Unit'],scale_factor=1,offset=0,topic='datachange_S_KIO_Project',
               writable=False,rw_mode='R',stale_ms=5000)
        v=dict(key=key,definition=d);variables[name]=v;new_variables.append(v)
        catalog.append([name,t['TagDataType'],d['data_type'],t['ItemName'],t['ItemAccessMode'],'R',key])
    def variable(name):
        if name in variables:return variables[name]
        assert len(existing[name])==1,('existing source not unique',name,len(existing[name]))
        v=copy.deepcopy(existing[name][0]);d=v['definition'];t=kio[name]
        # Earlier delivered catalogs represented some integer accumulators as
        # FLOAT. Referencing them must not mutate their stable definitions.
        assert d['data_type']==types[t['TagDataType']] or (d['data_type']=='FLOAT' and types[t['TagDataType']]=='INT'),('type changed',name,d['data_type'],t['TagDataType'])
        assert d['scale_factor']==1 and d['offset']==0,('engineering conversion requires review',name)
        variables[name]=v;return v
    def resolve(path):
        if not path or not path.startswith(p.LOCAL):return ''
        t=ks.get(path.removeprefix(p.LOCAL),{})
        m=re.fullmatch(r'server01\.(.+)\.Value',t.get('IOAccess',''))
        if not m or t.get('IOEnable')!='1' or m[1] not in kio or kio[m[1]]['Enable']!='是':return ''
        assert float(t.get('MaxRaw',0))==float(t.get('MaxValue',0)) and float(t.get('MinRaw',0))==float(t.get('MinValue',0))
        return m[1]
    screens=[];bindings=[];readings=[];stateaudit=[];summaries=[];native={}
    oldscreens={s['key']:s for s in old['bundle']['screens']}
    with zipfile.ZipFile(SRC/'pic1110.zip',metadata_encoding='gbk') as z:
        menu=p.menu_pairs(p.strings_from(z.read('pic1110/工艺图菜单.picx')))
        assert len(menu)==31
        for station,picture in menu:
            raw=z.read('pic1110/'+picture+'.picx')
            key,doc,_,values=make(station,picture,raw)
            assert key in oldscreens
            # Geometry, labels and bindings always come from this native image.
            native_arrows(doc)
            doc['background']=dict(type='solid',color='#FFFFFF',opacity=0)
            objects=p.objects_from(p.strings_from(raw));byobj={o['object']:o for o in objects}
            nodes={n['id']:n for n in doc['nodes']}
            bynode={o['object']:nodes.get('ks-'+o['object']+'-'+str(i)) for i,o in enumerate(objects)}
            native[station]=(picture,byobj)
            reading_names={}
            def bind(node,name):
                node['point_id']=''
                b=dict(screen_key=key,node_id=node['id'],property='point_id')
                bindings.append(dict(**b,operation='set',variable_key=variable(name)['key']) if name else dict(**b,operation='clear'))
            for obj,node in values:
                paths=[b['path'] for b in obj['bindings']];assert len(paths)==1
                path=paths[0];name=resolve(path);bind(node,name);reading_names[obj['object']]=name
                node['label']=path.removeprefix(p.LOCAL)
                readings.append([station,picture,obj['object'],node['id'],path,name,variable(name)['definition']['data_type'] if name else '',kio[name]['ItemName'] if name else '', '绑定' if name else 'XML无定义，保留显示对象且不猜绑'])
            visible=[o['offset'] for o,t,(x,y,w,h) in p.native_text_rows(raw,objects) if o['numeric'] and x<1750 and y<800 and x+w>0 and y+h>0]
            assert sorted(visible)==sorted(o['offset'] for o,n in values)
            added=[];removed=set();lampcount=0
            for obj in objects:
                label=bynode[obj['object']]
                if label and label['kind']=='ellipse' and 'B_LightState' in [s['text'] for s in obj['strings']]:
                    removed.add(label['id'])
                if not label or label['kind']!='text' or not obj['bindings'] or '泵' not in label['text']:continue
                assert len(obj['bindings'])==1
                frequency=obj['bindings'][0]['path'].removeprefix(p.LOCAL)
                if station in ('中心站东南区','中心站西北区') and obj['object']=='Text578':
                    frequency=reading_names['Text563'];assert frequency.endswith('补水2频率') and label['text']=='2#补水泵'
                if frequency.endswith('频率反馈'):
                    run={'新南站新华线循环泵频率反馈':'新南站新华线循环泵运行','新南站新华线补水泵频率反馈':'新南站新华线补水泵运行反馈'}[frequency]
                else:
                    assert frequency.endswith('频率'),(station,obj['object'],frequency,label['text'])
                    run=frequency.removesuffix('频率')+'变频运行'
                assert resolve(p.LOCAL+frequency)
                name=resolve(p.LOCAL+run);assert name and variable(name)['definition']['data_type']=='BOOL',(station,run)
                lamp=p.text_node('state-'+label['id'],'',max(0,label['x']-20),label['y']+(label['height']-16)/2,16,16)
                lamp.update(kind='ellipse',label=label['text']+' · 运行反馈',color='#64748b',fill='#94a3b8',state_display=dict(active_value=1,inactive_value=0,active_text='运行',inactive_text='停止',active_color='#16a34a',inactive_color='#dc2626'))
                bind(lamp,name);added.append(lamp);lampcount+=1;stateaudit.append([station,obj['object'],run,name,'BOOL运行反馈'])
            level=byobj['Rect63'];bar=bynode['Rect63'];idx=objects.index(level)
            segment=raw[level['offset']:objects[idx+1]['offset']]
            fields=[struct.unpack('<f',m[1])[0] for m in re.finditer(rb'\x01\x00(.{4})\xff\xff\x00\x00\x00\x00\xff\xfe\xff\x00\x01\x00',segment,re.S) if m.start()>90]
            assert fields[:4]==[0,100,0,3],(station,fields)
            water=reading_names['Text537'];assert water
            levelnode=copy.deepcopy(bar);removed.add(bar['id'])
            levelnode.update(id='level-'+bar['id'],kind='level',width=8,label='水箱液位',color='#2F93BD',fill='#EDF2F4',level_display=dict(minimum=fields[2],maximum=fields[3],orientation='vertical'))
            bind(levelnode,water);added.append(levelnode);stateaudit.append([station,'Rect63','Text537',water,'原生0～3量程、8px液位条'])
            doc['nodes']=[n for n in doc['nodes'] if n['id'] not in removed]+added
            assert len({n['id'] for n in doc['nodes']})==len(doc['nodes'])
            screens.append(dict(key=key,document=doc))
            summaries.append(dict(station=station,picture=picture,sha256=hashlib.sha256(raw).hexdigest(),readings=len(values),lamps=lampcount,levels=1,nodes=len(doc['nodes'])))
            print('native',station,len(values),lampcount,flush=True)
        # The native report contains the source temperature/divisor even though
        # some embedded row references lag behind its latest process drawings.
        spec=importlib.util.spec_from_file_location('report1104',ROOT/'tools/picx_update_1104/build.py')
        sys.path.insert(0,str(ROOT/'tools/picx_update_1104'))
        reportmod=importlib.util.module_from_spec(spec);spec.loader.exec_module(reportmod)
        embedded=reportmod.parse_report(z.read('pic1110/实时数据报表.picx'))
    assert len(readings)==904 and sum(bool(r[5]) for r in readings)==902
    unresolved=[r for r in readings if not r[5]]
    assert {(r[0],r[2]) for r in unresolved}=={('红光美苑高区','Text556'),('新北站北线','Text556')}
    # Cross-check every chosen overview object against the raw native objects.
    audit=list(csv.DictReader((CROSS/'全部1147槽位核对.csv').open(encoding='utf-8-sig')))
    cross=load(CROSS/'实际推送映射.json');crossrows={r['station']:r['values'] for r in cross['rows']}
    refs={}
    for r in audit:
        station=r['站区'];pos=int(r['实时列序']);picture,objects=native[station]
        if pos in (1,2,9,27,32):continue
        if r['对象']:
            if r['画面']!=picture+'.picx':
                with zipfile.ZipFile(SRC/'pic1110.zip',metadata_encoding='gbk') as z:objects={o['object']:o for o in p.objects_from(p.strings_from(z.read('pic1110/'+r['画面'])))}
            obj=objects[r['对象']];paths={b['path'].removesuffix('.LoLimit').removesuffix('.HiLimit') for b in obj['bindings']}
            assert len(paths)==1,(station,pos,paths)
            path=next(iter(paths));assert path==r['1110实际绑定']==crossrows[station][pos-1],(station,pos,path,r)
            refs[station,pos]=path
        else:assert not r['1110实际绑定'] and not crossrows[station][pos-1]
    initial=load(ROOT/'outputs/overview-1103/庄河总览配置.json')
    first=[r for r in load(ROOT/'outputs/overview-1103/总览逐格核对.json') if r['station']==initial['rows'][0]['station']]
    positions={c['id']:int(r['position']) for c,r in zip(initial['columns'],first)}
    overview=copy.deepcopy(oldoverview);overview['control']={'enabled':False,'base_url':'http://172.16.1.7:8004'}
    configtext=(HTML/'config/app-config.js').read_text('utf8')
    controls={name:dict(station=station,zone=zone) for name,station,zone in re.findall(r"'([^']+)': \{ station: '([^']+)', zone: '([^']+)' \}",configtext)}
    assert len(controls)==31 and overview['control']['base_url'] in configtext
    checks=[];changes=[]
    for row in overview['rows']:
        station=row['station'];row['control']=controls[station]
        for col in overview['columns']:
            pos=positions[col['id']];idx=int(col['id'].removeprefix('zh-m'))-1
            if 24<=idx<30:pos=([34,35,28,29,30,31] if station in ('中心站东南区','中心站西北区') else [28,29,30,31,0,0])[idx-24]
            path=refs.get((station,pos));name=resolve(path)
            assert not path or name,(station,pos,path)
            priorname=row['bindings'].get(col['id'],{}).get('source_path','')
            if name:row['bindings'][col['id']]={'source_id':source,'source_path':name};variable(name)
            else:row['bindings'].pop(col['id'],None)
            item=[station,col['id'],col['name'],pos,path or '',name,priorname];checks.append(item)
            if name!=priorname:changes.append(item)
    pre_dual_changes=len(changes)
    # The final user-supplied valve inventory supersedes the old single-valve
    # report slot. Match native label/geometry evidence, never object order.
    dual={r['station']:r for r in load(DUAL/'31站区双阀变量.json')}
    evidence=load(DUAL/'PIC位置与编译绑定依据.json')
    assert len(dual)==31 and len(evidence)==51
    native_hash={s['station']:s['sha256'] for s in summaries}
    for e in evidence:
        picture,objects=native[e['station']]
        assert picture+'.picx'==e['picture'] and native_hash[e['station']]==e['sourceSHA256']
        assert {b['path'] for b in objects[e['valueObject']]['bindings']}=={e['variable']}
        assert e['compiledVariable']==e['variable']==dual[e['station']][e['role']]
        assert e['label'] in [s['text'] for s in objects[e['labelObject']]['strings']]
        assert e['horizontalCenterGap']<20
    valve=next(c for c in overview['columns'] if c['id']=='zh-m10')
    valve.update(name='中节能阀反馈',header='中节能\n阀反馈')
    localvalve={**valve,'id':'zh-local-valve','name':'本区阀反馈','header':'本区\n阀反馈'}
    overview['columns'].insert(overview['columns'].index(valve)+1,localvalve)
    checks=[c for c in checks if c[1]!='zh-m10']
    dualaudit=[]
    for row in overview['rows']:
        station=row['station'];oldrow=next(r for r in oldoverview['rows'] if r['id']==row['id'])
        for col,role in [(valve,'中节能阀反馈'),(localvalve,'本站阀反馈')]:
            path=dual[station][role];name=resolve(path)
            assert not path or name,(station,role,path)
            if name:row['bindings'][col['id']]={'source_id':source,'source_path':name};variable(name)
            else:row['bindings'].pop(col['id'],None)
            priorname=oldrow['bindings'].get(col['id'],{}).get('source_path','')
            checks.append([station,col['id'],col['name'],'PIC标签/位置',path or '',name,priorname])
            dualaudit.append([station,col['name'],path or '',name,'已绑定' if name else '原图无此反馈，留空'])
    assert sum('zh-m10' in r['bindings'] for r in overview['rows'])==20
    assert len({r['bindings']['zh-local-valve']['source_path'] for r in overview['rows']})==31
    changes=[c for c in checks if c[5]!=c[6]]
    assert embedded['outdoor']==cross['outdoor'] and embedded['outdoor_divisor']==cross['outdoorDivisor']==10
    outdoor=variable(resolve(embedded['outdoor']));outdoorID=outdoor['key'].removeprefix('var_')
    candidates=[v for v in actual['variables'] if v['definition']['source_type']=='virtual' and v['definition'].get('inputs')==[outdoorID] and re.sub(r'\s','',v['definition'].get('expression','')) in ('v[0]/10','v[0]/10.0','v[0]*0.1') and v['definition'].get('scale_factor')==1 and v['definition'].get('offset')==0 and v['definition'].get('unit')=='℃']
    assert len(candidates)<=1
    if candidates:derived=candidates[0];derivedID=derived['key'].removeprefix('var_')
    else:
        derivedID='pt_imp_'+p.digest(('1110-outdoor-div10/'+outdoorID).encode())[:24]
        derived=dict(key='outdoor-div10',definition=dict(station=outdoor['definition']['station'],name='总览室外温度（原值÷10）',source_type='virtual',data_type='FLOAT',unit='℃',expression='v[0]/10',inputs=[outdoor['key']],scale_factor=1,offset=0,rw_mode='R',writable=False,stale_ms=5000))
    overview['outdoor']={'point_id':derivedID}
    request=copy.deepcopy(old);request['bundle'].update(screens=screens,bindings=bindings)
    used={b['variable_key'] for b in bindings if b['operation']=='set'}
    request['bundle']['variables']=[v for v in variables.values() if v['key'] in used]
    request['variable_targets']={v['key']:{'mode':'match_existing'} for v in request['bundle']['variables']}
    # New stations are already present in the delivered31 baseline. Preserve
    # the actual IDs even for the three formerly missing imported screens.
    request['screen_targets']={k:{**v,'mode':'update_imported'} for k,v in request['screen_targets'].items()}
    request['create_stations']=[]
    point_request=copy.deepcopy(request);point_request['bundle']=dict(format=request['bundle']['format'],version=1,screens=[],bindings=[],variables=[*new_variables,outdoor,derived])
    point_request['screen_targets']={};point_request['variable_targets']={v['key']:{'mode':'create'} for v in new_variables}
    point_request['variable_targets'][outdoor['key']]={'mode':'match_existing'}
    point_request['variable_targets'][derived['key']]={'mode':'reference','id':derivedID} if candidates else {'mode':'create','id':derivedID}
    point_request['station_map']['IO-01']='IO-01'
    save(OUT/'01-新增31变量与室外温度派生.json',{'retry_request':point_request})
    save(OUT/'02-全部31张透明工艺图.json',{'retry_request':request})
    save(OUT/'03-数据总览配置.json',overview)
    save(OUT/'04-31画面菜单-已有无需重导.json',load(ROOT/'outputs/工艺图完整导入-20261105/02-完整31画面菜单.json'))
    save(OUT/'回退/01-恢复1110前31张工艺图.json',{'retry_request':old})
    save(OUT/'回退/02-恢复1110前总览.json',oldoverview)
    save(CHECK/'screens.json',request['bundle'])
    report('904处工艺读数核对.csv',['站区','画面','原对象','节点','最新KS引用','最新KIO路径','类型','上游寄存器','结果'],readings)
    report('未解析读数.csv',['站区','画面','原对象','节点','最新KS引用','最新KIO路径','类型','上游寄存器','结果'],unresolved)
    report('状态液位核对.csv',['站区','原对象','核对引用','KIO路径','规则'],stateaudit)
    report('新增31点.csv',['KIO路径','原类型','HMI类型','寄存器','上游权限','新增HMI权限','导入身份'],catalog)
    report('总览逐格核对.csv',['站区','列ID','指标','原始槽位','原始KS引用','最新KIO路径','更新前KIO路径'],checks)
    legacy_diff=OUT/'核对资料/总览37处差异.csv'
    if legacy_diff.exists():legacy_diff.unlink()
    report('总览最终差异.csv',['站区','列ID','指标','原始槽位','原始KS引用','最新KIO路径','更新前KIO路径'],changes)
    report('31站区双阀核对.csv',['站区','列','KS引用','KIO路径','结果'],dualaudit)
    save(OUT/'核对资料/双阀PIC位置与编译绑定依据.json',evidence)
    changed=[n for n in kio.keys()&prior.keys() if kio[n]!=prior[n]]
    report('上游KIO变更-仅核对.csv',['变量','旧寄存器','新寄存器','说明'],[[n,prior[n]['ItemName'],kio[n]['ItemName'],'不改现场KIO，本软件MQTT路径不变'] for n in changed])
    stats=dict(screens=31,readings=904,bound=902,unresolved=2,new_mqtt=31,new_virtual=not bool(candidates),overview_changes=len(changes),overview_stations=21,lamps=sum(s['lamps'] for s in summaries),levels=31,per_screen=summaries,outdoor_raw=outdoorID,outdoor_point=derivedID,source_sha256={f:sha(SRC/f) for f in ['pic1110.zip','ks变量1110.xml','kio变量1110.csv']},html_config_sha256=sha(HTML/'config/app-config.js'),onsite_applied=False)
    stats.update(overview_stations=len({r[0] for r in changes}),overview_columns=len(overview['columns']),dual_valves=dict(provider=20,local=31,provider_missing=11),dual_mapping_sha256=sha(DUAL/'31站区双阀变量.json'))
    save(OUT/'核对资料/统计与来源.json',stats)
    print(json.dumps({k:v for k,v in stats.items() if k not in ('per_screen','source_sha256')},ensure_ascii=False,indent=2))

if __name__=='__main__':main()
