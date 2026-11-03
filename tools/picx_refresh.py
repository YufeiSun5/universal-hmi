"""Build independent HMI review/import screens from a PICX menu and text bindings.

Reads native CString boundaries. It does not execute scripts or infer shared
references. Most layouts use editable schematic templates; the opt-in center
layouts use reviewed source topology and native text coordinates.
"""
from pathlib import Path
from zipfile import ZipFile
import argparse
import csv
import hashlib
import json
import re
import math
import struct

LOCAL = '\\\\local\\'
OBJECT = re.compile(r'(?:Ellipse|Group|Rect|Text|RoundRect|Line|Image|Polygon|Pipe|Polyline|PictureWrap|Button|GeneralLights|ClosedSpline|ClosedBezier|OcxControl|Edit|ComboBox|CheckBox)\d+')
REFERENCE = re.compile(r'引用(?:模型)?\d+\.|共享_')
ROLES = dict(zip(
    ['Text511','Text108','Text528','Text529','Text530','Text532','Text533','Text534','Text535','Text536','Text537','Text538','Text539','Text540','Text541','Text542','Text543','Text548','Text549','Text550','Text551','Text552','Text553','Text554','Text555'],
    ['energy-total','return-pressure','return-temperature','primary-pressure','primary-temperature','valve-opening','primary-heat','primary-flow','primary-heat-total','primary-flow-total','tank-level','makeup-total','makeup-flow','makeup-current','makeup-frequency','circulation-current','circulation-frequency','secondary-heat','secondary-flow','secondary-heat-total','secondary-flow-total','secondary-pressure','secondary-temperature','secondary-return-pressure','secondary-return-temperature']))


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def digest(data):
    return hashlib.sha256(data).hexdigest()


def strings_from(data):
    result = []
    for match in re.finditer(b'\xff\xfe\xff', data):
        cursor = match.end()
        if cursor >= len(data):
            continue
        size = data[cursor]
        cursor += 1
        if size == 255:
            if cursor + 2 > len(data):
                continue
            size = int.from_bytes(data[cursor:cursor+2], 'little')
            cursor += 2
        if size == 65535:
            if cursor + 4 > len(data):
                continue
            size = int.from_bytes(data[cursor:cursor+4], 'little')
            cursor += 4
        if not 0 < size <= 1000000 or cursor + size * 2 > len(data):
            continue
        try:
            value = data[cursor:cursor+size*2].decode('utf-16le')
        except UnicodeError:
            continue
        if all(c.isprintable() or c in '\r\n\t' for c in value):
            result.append({'offset': match.start(), 'end': cursor+size*2, 'text': value})
    return result


def active(text):
    return re.sub(r'"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\r\n]*',
                  lambda m: m[0] if m[0].startswith('"') else '', text)


def menu_pairs(strings):
    candidates = []
    for item in strings:
        code = active(item['text'])
        arrays = []
        for name in ('nodeNames', 'pictureNames'):
            match = re.search(r'string\[(\d+)\]\s+'+name+r'\s*=\s*\{(.*?)\}', code, re.S)
            if not match:
                break
            values = re.findall(r'"([^"\r\n]+)"', match[2])
            if len(values) != int(match[1]):
                raise ValueError('Menu array size mismatch')
            arrays.append(values)
        if len(arrays) == 2:
            if len(arrays[0]) != len(arrays[1]):
                raise ValueError('Menu pair count mismatch')
            candidates.append(list(zip(*arrays)))
    if len(candidates) != 1:
        raise ValueError('Need one unambiguous independent menu mapping')
    pairs = candidates[0]
    if len(set(s for s, _ in pairs)) != len(pairs) or len(set(p for _, p in pairs)) != len(pairs):
        raise ValueError('Menu is not one independent picture per station')
    return pairs


def objects_from(strings):
    objects = []
    current = None
    for s in strings:
        if OBJECT.fullmatch(s['text']):
            current = {'object': s['text'], 'offset': s['offset'], 'strings': []}
            objects.append(current)
        if current is not None:
            current['strings'].append(s)
    for obj in objects:
        obj['bindings'] = []
        for s in obj['strings']:
            # Whole property expression only; do not turn scripts or metadata
            # into runtime bindings, and do not treat bare titles as variables.
            t = s['text'].strip()
            if t.startswith(LOCAL) and re.fullmatch(r'[^\s;"\'(){}=<>!+*/,&|\[\]]+', t):
                if not any(b['path'] == t for b in obj['bindings']):
                    obj['bindings'].append({'path': t, 'offset': s['offset']})
        obj['numeric'] = obj['object'].startswith('Text') and any(re.fullmatch(r'#+(?:\.#+)?[^#\s]*', s['text']) for s in obj['strings'])
    return objects


def text_node(id, text, x, y, width, height=26, size=16):
    return dict(id=id, kind='text', x=x, y=y, width=width, height=height,
                text=text, color='#293D4B', fill='none', font_size=size,
                stroke_width=1, point_id='', points=[], rotation=0,
                decimals=1, show_unit=False, arrow=False)


def display_text(text):
    return text.replace('中洁能', '中节能')


def native_text_rows(data, objects):
    """Read the repeated native text rectangle; do not guess from nearby floats."""
    def rect(offset):
        if offset + 16 > len(data):
            return None
        values = struct.unpack_from('<4f', data, offset)
        if (all(math.isfinite(v) and -3000 < v < 10000 and (v == 0 or abs(v) > .01) for v in values)
                and .1 < values[2] < 6000 and .1 < values[3] < 6000):
            return values
    rows = []
    for obj in objects:
        if not obj['object'].startswith('Text'):
            continue
        for i, s in enumerate(obj['strings']):
            box = rect(s['end'])
            if not box:
                continue
            if any(a['text'] == s['text'] and (b := rect(a['end']))
                   and all(abs(v-w) < .1 for v,w in zip(box[:2], b[:2]))
                   for a in obj['strings'][:i]):
                rows.append((obj, s['text'], [round(v, 2) for v in box]))
                break
    return rows


def build_screen(station, picture, objects, templates, native_data=None):
    if native_data is not None and picture in ('中心站流程1', '中心站流程2'):
        from picx_center_layout import build_center
        return build_center(station, picture, native_text_rows(native_data, objects), templates)
    readings = [o for o in objects if o['numeric'] and o['bindings']]
    paths = [b['path'] for o in readings for b in o['bindings']]
    pump_groups = {p for p in paths if '频率' in p and ('循环' in p or '辅助循' in p)}
    tid = 'heating-branch-three' if picture == '中心站流程1' else 'heating-single-'+('three' if len(pump_groups) >= 3 else 'two' if len(pump_groups) == 2 else 'one')
    doc = read(templates/(tid+'.json'))
    key = 'pic1103-'+digest(picture.encode())[:20]
    doc.update(id=key, revision=0, name=station+' · 工艺', station=station)
    for field in ('template_id','template_revision','bindings'):
        doc.pop(field, None)
    doc['background'] = dict(type='linear', color='#F0F3F5', end_color='#D5DEE5', angle=45, opacity=1)
    nodes = [n for n in doc['nodes'] if n['id'] != 'monitor-backdrop']
    for n in nodes:
        n['point_id'] = ''
        if n['kind'] == 'pipe':
            n['arrow'] = False
            n.pop('arrow_visible_rule', None)
            n.pop('arrow_motion_rule', None)
        if n['kind'] in ('text','value'):
            n['color'] = '#293D4B'
        elif n['kind'] == 'rect' and n.get('fill','').lower() == '#162f45':
            n.update(fill='#F1F3F5', color='#A9B8C2')
        if n['kind'] == 'value':
            n.update(unit_override='', show_unit=False)
    used = set()
    audit = []
    for obj in readings:
        target = ROLES.get(obj['object'])
        node = next((n for n in nodes if n['id'] == target and n['kind'] == 'value'), None)
        if node is None or node['id'] in used:
            continue
        used.add(node['id'])
        node['label'] = display_text(' / '.join(b['path'].removeprefix(LOCAL) for b in obj['bindings']))
        audit.append((obj,node))
    # Remove unused template readings rather than inventing source measurement slots.
    unused = {n['id'] for n in nodes if n['kind'] == 'value' and n['id'] not in used}
    unused_decoration = set()
    for u in unused:
        unused_decoration.update((u+'-box', u+'-label'))
        if re.search(r'-[23b]$', u):
            base, suffix = u.rsplit('-', 1)
            unused_decoration.update((base+'-box-'+suffix, base+'-label-'+suffix))
    nodes = [n for n in nodes if n['id'] not in unused | unused_decoration]
    has_brand = any('中洁能' in s['text'] and not s['text'].startswith(LOCAL)
                    for o in objects for s in o['strings'])
    title = station + (' · 中节能' if has_brand else '')
    nodes.append(text_node('screen-title', display_text(title), 24, 18, doc['width']-48, 32, 24))
    doc['nodes'] = nodes
    for node in nodes:
        for field in ('text', 'label'):
            if field in node:
                node[field] = display_text(node[field])
    return key, doc, audit, tid


def write_json(path, data):
    path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf8')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--archive',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--templates',type=Path,default=Path('app/assets/process/templates'))
    ap.add_argument('--old-handoff',type=Path)
    ap.add_argument('--mapping-evidence',type=Path)
    ap.add_argument('--previous-scan-package',type=Path)
    ap.add_argument('--confirmed-underscore-same-name',action='store_true',help='Explicit user-confirmed KS/KingIO full-name identity for underscore paths')
    ap.add_argument('--update-imported',action='store_true',help='Update exact existing import identities; missing screens remain conflicts, never create copies')
    ap.add_argument('--center-native-layout', action='store_true', help='Use reviewed center-station topology and native text coordinates')
    args = ap.parse_args()
    if args.output.exists():
        raise SystemExit('Refusing to overwrite an existing delivery directory')
    pages = {}
    with ZipFile(args.archive,metadata_encoding='gbk') as z:
        for item in z.infolist():
            if item.is_dir():
                continue
            name = Path(item.filename).name
            if not name.endswith('.picx') or name in pages:
                raise ValueError('Unsupported or duplicate archive member: '+name)
            data = z.read(item)
            ss = strings_from(data)
            pages[name] = dict(member=item.filename,sha256=digest(data),size=len(data),strings=ss,objects=objects_from(ss),data=data)
    pairs = menu_pairs(pages['工艺图菜单.picx']['strings'])
    bundle = dict(format='universal-hmi-process-bundle',version=1,screens=[],variables=[],bindings=[])
    residuals, evidence, catalog, manifests, text_changes, omitted = [], [], {}, [], [], []
    old = read(args.old_handoff) if args.old_handoff else {}
    mapping = {r['KS路径']:r for r in read(args.mapping_evidence)['不同固定路径']} if args.mapping_evidence else {}
    # Older evidence is usable only for the identical direct expression, never
    # for expansion of a model reference through the new menu's station name.
    for row in old.get('points', []):
        path = row.get('actualKS') or row.get('original', '')
        kio = row.get('kioFullTagName')
        if (path == row.get('original') and not REFERENCE.search(path)
                and row.get('kioCertainty') == 'explicit_legacy_io' and kio
                and row.get('evidence') == 'server01.'+kio+'.Value'
                and path not in mapping):
            mapping[path] = {'状态':'XML明确绑定', 'KIO变量':kio,
                             'KIO配置':{'data_type':row.get('data_type')},
                             '证据':'旧XML完整直接路径，现场仍须匹配已有变量'}
    previous_types = {}
    if args.previous_scan_package:
        previous = read(args.previous_scan_package)['retry_request']['bundle']
        previous_types = {r['definition']['source_path']:r['definition']['data_type'] for r in previous['variables']}
    mapped_variables, mapped_bindings = {}, []
    old_by_station = {}
    for p in old.get('points',[]):
        old_by_station.setdefault(p.get('station',''),set()).add(p.get('actualKS') or p.get('original',''))
    changes = []
    for station,picture in pairs:
        page = pages[picture+'.picx']
        key,doc,readings,tid = build_screen(station,picture,page['objects'],args.templates,page['data'] if args.center_native_layout else None)
        included_objects = {obj['object'] for obj, _ in readings}
        omitted.extend(dict(station=station,picture=picture,object=obj['object'],
                            paths=[b['path'] for b in obj['bindings']],
                            reason='主图外补充测点不展示；不删除采集变量')
                       for obj in page['objects'] if obj['numeric'] and obj['bindings']
                       and obj['object'] not in included_objects)
        for obj in page['objects']:
            for value in dict.fromkeys(s['text'] for s in obj['strings']):
                if '中洁能' in value and not value.startswith(LOCAL) and len(value)<100:
                    text_changes.append(dict(station=station, picture=picture, object=obj['object'], original=value, display=display_text(value)))
        bundle['screens'].append(dict(key=key,document=doc))
        new_paths = set()
        for obj in page['objects']:
            for b in obj['bindings']:
                if REFERENCE.search(b['path']):
                    residuals.append(dict(station=station,picture=picture,object=obj['object'],path=b['path'],offset=b['offset'],action='留空，不推断'))
        for obj,node in readings:
            paths = [b['path'] for b in obj['bindings']]
            new_paths.update(paths)
            unresolved = len(paths)!=1 or REFERENCE.search(paths[0]) is not None
            variable_key = ''
            mapped_key = ''
            proof = None
            if not unresolved:
                source = paths[0].removeprefix(LOCAL)
                variable_key = 'ks-'+digest(source.encode())[:20]
                if variable_key not in catalog:
                    # PICX gives KS expressions, not a KingIO source/topic/type contract.
                    # Keep proposed full path as evidence, never auto-create variables.
                    catalog[variable_key] = dict(key=variable_key,definition=dict(name=source,station='',data_type='',source_type='',source_id='',source_path='',topic='',unit='',rw_mode='R',writable=False))
                proof = mapping.get(paths[0])
                if args.confirmed_underscore_same_name and '_' in source and (not proof or not proof.get('KIO变量')):
                    proof = {'状态':'用户确认下划线变量同名','KIO变量':source,'KIO配置':{},'类型说明':'FLOAT仅为匹配提示，现场类型不符时预览阻止绑定'}
                if proof and proof.get('状态') in ('XML明确绑定','工程师明确映射','用户确认下划线变量同名') and proof.get('KIO变量'):
                    kio = proof['KIO变量']
                    config = proof.get('KIO配置') or {}
                    dtype = previous_types.get(kio) or {'IOFloat':'FLOAT','IOLong':'INT','IOShort':'INT','IODisc':'BOOL'}.get(config.get('data_type'))
                    if not dtype and proof['状态'] == '用户确认下划线变量同名':
                        dtype = 'FLOAT'
                    if dtype:
                        mapped_key = 'kio-'+digest(kio.encode())[:20]
                        mapped_variables[mapped_key] = dict(key=mapped_key,definition=dict(name=kio,station='',data_type=dtype,source_type='mqtt',source_id='kingio-confirmed',source_path=kio,topic='',unit='',rw_mode='R',writable=False))
            # A source candidate is review data. Import stays unbound until an
            # engineer maps it to an existing stable ID or confirms its source.
            bundle['bindings'].append(dict(screen_key=key,node_id=node['id'],property='point_id',variable_key='',operation='clear'))
            mapped_bindings.append(dict(screen_key=key,node_id=node['id'],property='point_id',variable_key=mapped_key,operation='set' if mapped_key else 'clear'))
            evidence.append(dict(station=station,picture=picture,screen_key=key,object=obj['object'],node_id=node['id'],paths=paths,offsets=[b['offset'] for b in obj['bindings']],candidate_key=variable_key,mapped_key=mapped_key,kio=proof.get('KIO变量') if proof else None,type_note=proof.get('类型说明','') if proof else '',status='残留引用留空' if unresolved else proof['状态'] if mapped_key else '直接KS路径，待映射现有变量'))
        previous = old_by_station.get(station,set())
        changes.append(dict(station=station,picture=picture,old_reading_paths=sorted(previous),new_reading_paths=sorted(new_paths),added_paths=sorted(new_paths-previous),removed_paths=sorted(previous-new_paths),comparison='原始KS路径集合；旧共享展开与新独立路径不等于物理测点增删'))
        manifests.append(dict(station=station,picture=picture,key=key,sha256=page['sha256'],readings=len(readings),template=tid))
    # Candidates stay separate from the immediately importable empty-binding screens.
    out=args.output
    (out/'screens').mkdir(parents=True)
    write_json(out/'screens.json',bundle)
    # A layout refresh must retain any existing manually resolved main readings.
    # Missing mapping evidence is not an instruction to erase a saved binding.
    if args.update_imported:
        mapped_bindings = [b for b in mapped_bindings if b['operation'] == 'set']
    mapped_bundle = dict(bundle,variables=list(mapped_variables.values()),bindings=mapped_bindings)
    write_json(out/'confirmed-bindings.json',mapped_bundle)
    request = dict(bundle=mapped_bundle,import_identity='picx-independent-20261103',screen_targets={s['key']:dict(mode='update_imported' if args.update_imported else 'create') for s in bundle['screens']},variable_targets={k:dict(mode='match_existing') for k in mapped_variables},station_map={s:s for s,_ in pairs},create_stations=[],source_map={})
    write_json(out/'导入请求-匹配已有变量.json',dict(retry_request=request))
    for screen in bundle['screens']:
        write_json(out/'screens'/(screen['document']['station']+'.json'),screen['document'])
    write_json(out/'binding-evidence.json',evidence)
    write_json(out/'variable-candidates.json',list(catalog.values()))
    write_json(out/'residual-references.json',residuals)
    write_json(out/'display-text-changes.json',text_changes)
    write_json(out/'unconfirmed-bindings.json',[r for r in evidence if not r['mapped_key']])
    write_json(out/'omitted-supplementary-readings.json',omitted)
    write_json(out/'changes.json',changes)
    write_json(out/'source-manifest.json',dict(archive=str(args.archive.resolve()),sha256=digest(args.archive.read_bytes()),underscore_same_name_confirmed=args.confirmed_underscore_same_name,supporting_sources=[dict(path=str(p.resolve()),sha256=digest(p.read_bytes())) for p in (args.old_handoff,args.mapping_evidence,args.previous_scan_package) if p],pages=[{k:v for k,v in p.items() if k in ('member','sha256','size')} for p in pages.values()],selected=manifests,excluded=[n for n in pages if Path(n).stem not in {p for _,p in pairs}]))
    for name,rows,headers in [
        ('残留引用留空清单.csv',residuals,['station','picture','object','path','offset','action']),
        ('新画面点位清单.csv',evidence,['station','picture','object','node_id','paths','candidate_key','status'])]:
        with (out/name).open('w',encoding='utf-8-sig',newline='') as f:
            writer=csv.DictWriter(f,fieldnames=headers,extrasaction='ignore');writer.writeheader()
            writer.writerows([{k:' | '.join(map(str,v)) if isinstance(v,list) else v for k,v in r.items()} for r in rows])
    summary=dict(pages=len(pages),screens=len(bundle['screens']),numeric_readings=len(evidence),omitted_supplementary_readings=len(omitted),direct_unique_candidates=len(catalog),residual_references=len(residuals),residual_numeric_readings=sum(not r['candidate_key'] for r in evidence),confirmed_unique_kio=len(mapped_variables),confirmed_binding_positions=sum(bool(r['mapped_key']) for r in evidence),unconfirmed_positions=sum(not r['mapped_key'] and bool(r['candidate_key']) for r in evidence),background='system-light-steel',runtime_bound=0)
    write_json(out/'summary.json',summary)
    print(json.dumps(summary,ensure_ascii=False))


if __name__ == '__main__':
    main()
