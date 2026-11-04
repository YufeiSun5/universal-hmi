"""Build an offline, identity-preserving 1103n -> 1104 configuration update.

Reads supplied PICX/XML/CSV files only. No network, live project or PLC writes.
Uses the established PICX decoder and public process-transfer file contract.
"""
from pathlib import Path
import collections, copy, csv, hashlib, json, re, sys, zipfile
from inspect_inputs import ROOT, SRC, OLD, csvread, xmlread

sys.path.insert(0, str(ROOT/'tools/picx_restore_1103'))
from layout import make, p
from spacing import place
from arrows import apply

OUT = ROOT/'outputs/庄河1104更新包'
AUDIT = OUT/'核对资料'
CHECK = ROOT/'.local/update-1104'
BASE = ROOT/'outputs/现场导入-1103n'

def load(path): return json.loads(Path(path).read_text('utf-8-sig'))
def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
def digest(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def report(name, header, rows):
    with (AUDIT/name).open('w', encoding='utf-8-sig', newline='') as f:
        writer=csv.writer(f); writer.writerow(header); writer.writerows(rows)

def parse_report(data):
    scripts=[s for s in p.strings_from(data) if 'appendEnergyReportStationRow' in s['text'] and 'sampleJson[' in s['text']]
    assert len(scripts)==1, len(scripts)
    text=p.active(scripts[0]['text'])
    samples={int(i):None for i in re.findall(r'sampleJson\[(\d+)\] = "null";',text)}
    divided={}
    matches=re.findall(r'if \(\((.*?)\.Quality & 192\) == 192\)\s*\{\s*sampleJson\[(\d+)\] = StrFromReal\((.*?), 2, "f"\);\s*\}',text)
    for quality,index,value in matches:
        i=int(index); assert i in samples
        if quality != value:
            div=re.fullmatch(re.escape(quality)+r'\s*/\s*([\d.]+)',value)
            assert div, (quality,value)
            divided[i]=float(div[1])
        samples[i]=quality
    assert len(re.findall(r'= StrFromReal\(',text))==len(matches)
    rows={}
    for station,body,target in re.findall(r'rowJson = "\'([^\']+)\'";([\s\S]*?)appendEnergyReportStationRow\(\'([^\']+)\'',text):
        assert station==target and station not in rows
        values=[station]
        for line in body.splitlines():
            if not line.startswith('rowJson = rowJson + '): continue
            if line=='rowJson = rowJson + ",null";': values.append(None)
            else:
                m=re.fullmatch(r'rowJson = rowJson \+ "," \+ sampleJson\[(\d+)\];',line)
                assert m,line
                idx=int(m[1]); assert idx not in divided
                values.append(samples[idx])
        assert len(values)==37,(station,len(values))
        rows[station]=values
    assert len(rows)==31
    outdoor=int(re.search(r'setEnergyReportOutdoorTemperature\(" \+ sampleJson\[(\d+)\]',text)[1])
    return dict(rows=rows,outdoor=samples[outdoor],outdoor_divisor=divided.get(outdoor,1),script_offset=scripts[0]['offset'])

def main():
    for directory in (OUT,AUDIT,CHECK): directory.mkdir(parents=True,exist_ok=True)
    kio=csvread(SRC/'kio变量1104.csv'); oldkio=csvread(OLD/'kio变量1103n.csv')
    ks=xmlread(SRC/'1104ks变量.xml'); oldks=xmlread(OLD/'ks变量1103n.xml')
    assert ks==oldks, 'This update expects no KS definition changes'
    assert kio.keys()==oldkio.keys(), 'Unexpected KIO additions/deletions'
    changed_kio=[n for n in kio if kio[n]!=oldkio[n]]
    assert all({key for key in kio[n] if kio[n][key]!=oldkio[n][key]}=={'ItemName'} for n in changed_kio)
    report('KIO寄存器地址变更-53点.csv', ['KIO变量','原寄存器','新寄存器','设备','原生类型','读写方式'],
           [[n,oldkio[n]['ItemName'],kio[n]['ItemName'],kio[n]['DeviceName'],kio[n]['TagDataType'],kio[n]['ItemAccessMode']] for n in changed_kio])
    # Original KIO export columns and GB18030 encoding, for engineer review.
    refdir=OUT/'上游KIO核对'; refdir.mkdir(exist_ok=True)
    with (refdir/'53点原格式记录-核对用.csv').open('w',encoding='gb18030',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(next(iter(kio.values()))));writer.writeheader();writer.writerows(kio[n] for n in changed_kio)
    address_groups=collections.defaultdict(list)
    for n,t in kio.items(): address_groups[(t['DeviceName'],t['ItemName'])].append(n)
    collisions=[]
    for n in changed_kio:
        t=kio[n]; peers=address_groups[t['DeviceName'],t['ItemName']]
        oldpeers=[name for name,v in oldkio.items() if (v['DeviceName'],v['ItemName'])==(oldkio[n]['DeviceName'],oldkio[n]['ItemName'])]
        if len(peers)>1 and set(peers)!=set(oldpeers): collisions.append([n,t['ItemName'],'；'.join(peers)])
    report('KIO新共用地址-待工程师核对.csv',['变量','新寄存器','同设备同地址变量'],collisions)
    baseline=load(BASE/'完整资料/02-全部工艺图与绑定.json')['retry_request']
    oldbundle=baseline['bundle']
    oldscreens={s['key']:s for s in oldbundle['screens']}
    allvariables=load(BASE/'完整资料/01-全量变量匹配与补齐.json')['retry_request']['bundle']['variables']
    vbyname={v['definition']['source_path']:v for v in allvariables}
    assert set(vbyname)==set(kio)
    oldvars={v['key']:v['definition']['source_path'] for v in oldbundle['variables']}
    oldbindings={(b['screen_key'],b['node_id']):oldvars[b['variable_key']] for b in oldbundle['bindings'] if b['operation']=='set'}
    oldreadings={(r['站区'],r['对象']):r for r in csv.DictReader((BASE/'核对资料/工艺读数逐项核对.csv').open(encoding='utf-8-sig'))}

    def resolve(path):
        if not path or not path.startswith(p.LOCAL): return '', '无唯一固定KS路径'
        tag=ks.get(path.removeprefix(p.LOCAL))
        if not tag: return '', 'XML无此变量'
        access=re.fullmatch(r'server01\.(.+)\.Value',tag.get('IOAccess',''))
        if not access or tag.get('IOEnable')!='1': return '', '无启用固定IOAccess'
        name=access[1]
        if name not in kio or kio[name]['Enable']!='是': return '', 'KIO无启用目标'
        return name,'XML启用IOAccess与KIO完整路径唯一匹配'

    screens=[]; bindings=[]; reading_rows=[]; summary=[]; changes=[]; node_changes=[]
    with zipfile.ZipFile(OLD/'1103n.zip',metadata_encoding='gbk') as archive:
        pairs=p.menu_pairs(p.strings_from((SRC/'1104画面/工艺图菜单.picx').read_bytes()))
        assert pairs==p.menu_pairs(p.strings_from(archive.read('1103n/工艺图菜单.picx')))
        for station,picture in pairs:
            path=SRC/'1104画面'/f'{picture}.picx'; data=path.read_bytes(); before=archive.read('1103n/'+picture+'.picx')
            key,doc,objects,values=make(station,picture,data)
            apply(doc); place(doc)
            # Keep reviewed labels when the source object still means the same measurement.
            previous=oldscreens[key]['document']; prevnodes={n['id']:n for n in previous['nodes']}
            visible=[o['offset'] for o,t,(x,y,w,h) in p.native_text_rows(data,p.objects_from(p.strings_from(data)))
                     if o['numeric'] and x<1750 and y<800 and x+w>0 and y+h>0]
            assert sorted(visible)==sorted(o['offset'] for o,n in values)
            assert len({n['id'] for n in doc['nodes']})==len(doc['nodes'])
            targets={}; start=len(reading_rows)
            for obj,node in values:
                paths=[b['path'] for b in obj['bindings']]; path=paths[0] if len(paths)==1 else ''
                name,status=resolve(path)
                oldrow=oldreadings.get((station,obj['object']),{})
                if oldrow.get('KS路径')==path and node['id'] in prevnodes:
                    node['label']=prevnodes[node['id']].get('label',node.get('label',''))
                else: node['label']=path.removeprefix(p.LOCAL) or obj['object']
                if name: targets[node['id']]=name
                b=dict(screen_key=key,node_id=node['id'],property='point_id')
                if name: bindings.append(dict(**b,operation='set',variable_key=vbyname[name]['key']))
                else: bindings.append(dict(**b,operation='clear'))
                reading_rows.append([station,picture,obj['object'],node['id'],path,ks.get(path.removeprefix(p.LOCAL),{}).get('IOAccess',''),name,status,oldrow.get('新KIO目标',''),kio[name]['ItemName'] if name else ''])
            if data==before: doc=copy.deepcopy(previous)
            oldtargets={nid:name for (sk,nid),name in oldbindings.items() if sk==key}
            content_changed=doc!=previous; binding_changes=sum(oldtargets.get(n)!=targets.get(n) for n in oldtargets.keys()|targets.keys())
            newnodes={n['id']:n for n in doc['nodes']}
            for nid in sorted(prevnodes.keys()|newnodes.keys()):
                a,b=prevnodes.get(nid,{}),newnodes.get(nid,{})
                if a!=b:
                    fields=sorted(k for k in a.keys()|b.keys() if a.get(k)!=b.get(k))
                    node_changes.append([station,nid,'新增' if not a else '删除' if not b else '修改','、'.join(fields),a.get('text',''),b.get('text','')])
            changed=content_changed or binding_changes>0
            if changed: changes.append(key)
            screens.append(dict(key=key,document=doc))
            summary.append([station,picture,hashlib.sha256(data).hexdigest(),data!=before,content_changed,binding_changes,len(reading_rows)-start,len(targets),len(reading_rows)-start-len(targets),changed])
    def request(selected):
        keys={s['key'] for s in selected}
        bs=[b for b in bindings if b['screen_key'] in keys]
        used={b['variable_key'] for b in bs if b['operation']=='set'}
        variables=[v for v in allvariables if v['key'] in used]
        return {'retry_request':dict(import_identity=baseline['import_identity'],bundle=dict(format=oldbundle['format'],version=1,screens=selected,bindings=bs,variables=variables),
                                    screen_targets={s['key']:{'mode':'update_imported'} for s in selected},variable_targets={v['key']:{'mode':'match_existing'} for v in variables},
                                    station_map=baseline['station_map'],source_map=baseline['source_map'],create_stations=[])}
    delta=request([s for s in screens if s['key'] in changes]); full=request(screens)
    save(OUT/'01-工艺画面增量更新.json',delta)
    save(OUT/'补充资料-未更新1103n时使用/全部31张工艺图-更新原身份.json',full)
    save(OUT/'补充资料-未更新1103n时使用/先补齐1103n的73个候选变量.json',load(BASE/'01-补齐现场变量.json'))
    save(CHECK/'full-request.json',full)
    save(CHECK/'screens.json',delta['retry_request']['bundle'])
    rollback=copy.deepcopy(baseline)
    rollback['bundle']['screens']=[s for s in oldbundle['screens'] if s['key'] in changes]
    rollback['bundle']['bindings']=[b for b in oldbundle['bindings'] if b['screen_key'] in changes]
    rollback['screen_targets']={key:{'mode':'update_imported'} for key in changes}
    for s in rollback['bundle']['screens']:
        for n in s['document']['nodes']:
            if n['kind']=='value' and (s['key'],n['id']) not in oldbindings:
                rollback['bundle']['bindings'].append(dict(screen_key=s['key'],node_id=n['id'],property='point_id',operation='clear'))
    rollback_used={b['variable_key'] for b in rollback['bundle']['bindings'] if b['operation']=='set'}
    rollback['bundle']['variables']=[v for v in oldbundle['variables'] if v['key'] in rollback_used]
    rollback['variable_targets']={key:{'mode':'match_existing'} for key in rollback_used}
    save(OUT/'回退到1103n/01-工艺图回退.json',{'retry_request':rollback})
    report('31张工艺图差异.csv',['站区','原图','新原图SHA256','原图字节变化','画面内容变化','绑定差异数','读数数','已绑定','留空','纳入增量'],summary)
    report('工艺读数逐项核对.csv',['站区','原图','对象','节点','KS路径','XML采集路径','新KIO目标','结果','旧节点KIO','设备寄存器'],reading_rows)
    report('画面节点差异.csv',['站区','节点','变化','变化字段','旧文字','新文字'],node_changes)
    report('工艺绑定变化.csv',['站区','原图','对象','节点','KS路径','XML采集路径','新KIO目标','结果','旧节点KIO','设备寄存器'],[r for r in reading_rows if r[6]!=r[8]])

    # The previous delivered overview has the reviewed pump order and outdoor source.
    overview=load(BASE/'03-数据总览配置-循环泵左排-气象站室外温度.json')
    oldoverview=copy.deepcopy(overview)
    save(OUT/'回退到1103n/02-数据总览回退.json',oldoverview)
    actual=parse_report((SRC/'1104画面/实时数据报表.picx').read_bytes())
    save(AUDIT/'新版实时数据报表实际映射.json',actual)
    oldcol_positions={}
    for r in load(ROOT/'outputs/overview-1103/总览逐格核对.json'):
        oldcol_positions.setdefault(r['station'],[]).append(r)
    initial=load(ROOT/'outputs/overview-1103/庄河总览配置.json')
    position_by_id={col['id']:r['position'] for col,r in zip(initial['columns'],oldcol_positions[initial['rows'][0]['station']])}
    overview_changes=[]; overview_checks=[]; upstream_stale=[]
    byobject={(r[0],r[2]):r for r in reading_rows}
    # Existing display contract: center = main pump, auxiliary 1, auxiliary 2;
    # ordinary sites start with pump 1 at the left, without an empty leading slot.
    pump_slots={25:(34,28),26:(35,29),27:(28,30),28:(29,31),29:(30,34),30:(31,35)}
    metric_objects={'zh-m1':'Text533','zh-m2':'Text535','zh-m3':'Text534','zh-m4':'Text536',
                    'zh-m5':'Text530','zh-m6':'Text528','zh-m7':'Text529','zh-m8':'Text108','zh-m10':'Text532',
                    'zh-m16':'Text549','zh-m17':'Text548','zh-m18':'Text550','zh-m19':'Text551'}
    for row in overview['rows']:
        station=row['station']; vals=actual['rows'][station]
        for col in overview['columns']:
            position=position_by_id[col['id']]
            colnum=int(col['id'].removeprefix('zh-m'))
            if colnum in pump_slots:
                position=pump_slots[colnum][0 if station in ('中心站东南区','中心站西北区') else 1]
            path=vals[position-1]
            processrow=byobject.get((station,metric_objects.get(col['id'],'')))
            # Only propagate source-object reference changes in this batch. Do not
            # override unchanged report-specific semantics at any other station.
            if processrow and processrow[6]!=processrow[8]:
                if path!=processrow[4]:
                    upstream_stale.append([station,col['id'],col['name'],path,processrow[4],processrow[2]])
                path=processrow[4]
            name,status=resolve(path)
            assert not path or name,(station,col,path,status)
            prior=row['bindings'].get(col['id'],{}).get('source_path','')
            if name: row['bindings'][col['id']]={'source_id':baseline['source_map']['kingio-confirmed'],'source_path':name}
            else: row['bindings'].pop(col['id'],None)
            overview_checks.append([station,col['id'],col['name'],path or '',name,prior])
            if prior!=name: overview_changes.append(overview_checks[-1])
    # Preserve the last explicitly delivered outdoor choice, not the unrelated /10 header expression.
    assert overview['outdoor']==oldoverview['outdoor']
    assert overview['columns']==oldoverview['columns']
    save(OUT/'02-数据总览配置.json',overview)
    report('总览逐格核对.csv',['站区','列ID','列名','新KS路径','新KIO目标','旧KIO目标'],overview_checks)
    report('总览绑定变更.csv',['站区','列ID','列名','新KS路径','新KIO目标','旧KIO目标'],overview_changes)
    report('原KS报表尚未同步的引用.csv',['站区','列ID','列名','新包报表仍引用','本包按新工艺图引用','原图对象'],upstream_stale)
    gis=load(ROOT/'outputs/gis-1103/庄河地图_16站31分区_一次共享二次分区_示意坐标.json')
    gisfields={f['id'] for station in gis['stations'] for row in [station]+station['zones'] for f in row['fields']}
    gis_changes=[r for r in overview_changes if r[1] in gisfields]
    report('GIS显示指标影响.csv',['站区','列ID','列名','新KS路径','新KIO目标','旧KIO目标'],gis_changes)
    assert {(r[0],r[1]) for r in gis_changes}=={('红光美苑首站','zh-m5'),('红光美苑首站','zh-m6')}
    field=load(OLD/'process-variables.json')['variables']
    source=baseline['source_map']['kingio-confirmed']
    references={}
    for change in gis_changes:
        hits=[v for v in field if v['definition'].get('source_id')==source and v['definition'].get('source_path')==change[4]]
        assert len(hits)==1, change
        references[change[1]]=hits[0]['key'].removeprefix('var_')
    site=next(s for s in gis['stations'] if s['name']=='红光美苑首站')
    save(OUT/'03-GIS红光美苑首站-仅公共温度.json',dict(format='universal-hmi-gis-station',version=1,parts={'common':dict(fields=site['fields'],bindings=references)}))
    save(OUT/'回退到1103n/03-GIS红光美苑首站公共温度回退.json',dict(format='universal-hmi-gis-station',version=1,parts={'common':dict(fields=site['fields'],bindings=site['bindings'])}))
    stats=dict(baseline='1103n',ks_tags=len(ks),ks_definition_changes=0,kio_tags=len(kio),kio_additions=0,kio_removals=0,kio_address_changes=len(changed_kio),
               screens=len(screens),updated_screens=len(changes),screen_names=[r[0] for r in summary if r[-1]],
               process_readings=len(reading_rows),bound=sum(bool(r[6]) for r in reading_rows),blank=sum(not r[6] for r in reading_rows),
               binding_changes=sum(r[6]!=r[8] for r in reading_rows),overview_changes=len(overview_changes),overview_changed_stations=sorted(set(r[0] for r in overview_changes)),
               overview_bound=sum(len(r['bindings']) for r in overview['rows'])+1,gis_affected_fields=len(gis_changes),upstream_stale_overview_references=len(upstream_stale),kio_new_shared_address_rows=len(collisions),
               input_sha256={str(path):digest(path) for path in [SRC/'1104ks变量.xml',SRC/'kio变量1104.csv',OLD/'1103n.zip',OLD/'ks变量1103n.xml',OLD/'kio变量1103n.csv',BASE/'完整资料/02-全部工艺图与绑定.json',BASE/'03-数据总览配置-循环泵左排-气象站室外温度.json']},
               picx_sha256={path.name:digest(path) for path in sorted((SRC/'1104画面').glob('*.picx'))})
    save(AUDIT/'统计与来源.json',stats)
    print(json.dumps({k:v for k,v in stats.items() if not k.endswith('sha256')},ensure_ascii=False,indent=2))

if __name__=='__main__': main()
