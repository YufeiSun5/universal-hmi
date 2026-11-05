"""Restore confirmed pump indications and tank levels without touching live data.

Keep the reviewed 31-screen transfer baseline and resolve existing point identities
through the supplied KS IOAccess and KIO export. Never bind model placeholders.
"""
from pathlib import Path
import collections
import copy
import csv
import hashlib
import json
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/picx_update_1104'))
from inspect_inputs import SRC, xmlread, csvread, p

BASE = ROOT / 'outputs/工艺图完整导入-20261105'
OUT = ROOT / 'outputs/工艺状态液位更新-20261105'


def read(path):
    return json.loads(Path(path).read_text('utf-8-sig'))


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n', 'utf8')


def main():
    original = read(BASE / '01-完整31张工艺图与绑定.json')['retry_request']
    request = copy.deepcopy(original)
    ks, kio = xmlread(SRC / '1104ks变量.xml'), csvread(SRC / 'kio变量1104.csv')
    exported = read('D:/Users/SunYufei/Downloads/process-bundle.json')
    candidates = collections.defaultdict(list)
    for variable in exported['variables']:
        candidates[variable['definition']['source_path']].append(variable)
    variables = {v['key']: v for v in request['bundle']['variables']}
    bindings = {(b['screen_key'], b['node_id']): b for b in request['bundle']['bindings']}
    audit, unresolved, summary = [], [], []
    pairs = dict(p.menu_pairs(p.strings_from((SRC / '1104画面/工艺图菜单.picx').read_bytes())))
    source_hashes = {}

    def resolve(name, boolean=False):
        tag = ks.get(name, {})
        access = re.fullmatch(r'server01\.(.+)\.Value', tag.get('IOAccess', ''))
        assert access and tag.get('IOEnable') == '1', ('KS reference', name)
        source = access[1]
        assert kio[source]['Enable'] == '是', ('KIO disabled', source)
        matches = candidates[source]
        assert len(matches) == 1, ('non-unique exported variable', source)
        variable = matches[0]
        assert variable['definition']['source_id'] in request['source_map']
        if boolean:
            assert kio[source]['TagDataType'] == 'IODisc'
            assert variable['definition']['data_type'] == 'BOOL'
            assert variable['definition']['scale_factor'] == 1 and variable['definition']['offset'] == 0
        return variable

    def bind(screen, node, variable):
        variables[variable['key']] = variable
        request['variable_targets'][variable['key']] = {'mode': 'match_existing'}
        node['point_id'] = ''
        request['bundle']['bindings'].append(dict(screen_key=screen['key'], node_id=node['id'], property='point_id', operation='set', variable_key=variable['key']))

    for screen in request['bundle']['screens']:
        doc = screen['document']
        station = doc['name'].removesuffix(' · 工艺')
        picture = pairs[station]
        raw = (SRC / '1104画面' / (picture + '.picx')).read_bytes()
        source_hashes[picture] = hashlib.sha256(raw).hexdigest()
        objects = p.objects_from(p.strings_from(raw))
        nodes = {n['id']: n for n in doc['nodes']}
        by_object = {}
        for index, obj in enumerate(objects):
            key = 'ks-' + obj['object'] + '-' + str(index)
            if key in nodes:
                by_object[obj['object']] = (obj, nodes[key])
        added = []
        for name, (obj, label) in by_object.items():
            if label['kind'] != 'text' or not obj['bindings'] or '泵' not in label['text']:
                continue
            assert len(obj['bindings']) == 1
            frequency = obj['bindings'][0]['path'].removeprefix(p.LOCAL)
            reason = '原泵名称的频率引用→同设备变频运行；XML/KIO/现有BOOL身份逐项核对'
            # The original second makeup label accidentally repeats pump 1.
            # Use the already reviewed second makeup frequency reading as evidence.
            if station in ('中心站东南区', '中心站西北区') and name == 'Text578':
                reading = by_object['Text563'][1]
                ref = bindings[screen['key'], reading['id']]['variable_key']
                frequency = variables[ref]['definition']['source_path']
                assert frequency.endswith('补水2频率') and label['text'] == '2#补水泵'
                reason = '原2#标签误引补水1；按同图Text563已确认补水2频率与2#文字校正'
            if frequency.endswith('频率反馈'):
                run = {'新南站新华线循环泵频率反馈': '新南站新华线循环泵运行',
                       '新南站新华线补水泵频率反馈': '新南站新华线补水泵运行反馈'}[frequency]
            else:
                assert frequency.endswith('频率'), frequency
                run = frequency.removesuffix('频率') + '变频运行'
            # Assert the original frequency itself resolves; an unresolved template
            # cannot acquire a run binding by string substitution.
            resolve(frequency)
            variable = resolve(run, boolean=True)
            lamp = p.text_node('state-' + label['id'], '', max(0, label['x'] - 20), label['y'] + (label['height'] - 16) / 2, 16, 16)
            lamp.update(kind='ellipse', label=label['text'] + ' · 运行反馈', color='#64748b', fill='#94a3b8',
                        state_display=dict(active_value=1, inactive_value=0, active_text='运行', inactive_text='停止', active_color='#16a34a', inactive_color='#dc2626'))
            bind(screen, lamp, variable)
            added.append(lamp)
            audit.append([station, name, lamp['id'], '泵状态', obj['bindings'][0]['path'], run, variable['definition']['source_path'], variable['key'], reason])

        # Restore the original fill range (0..100% mapped from 0..3 engineering
        # units), replacing stale model aliases with this screen's reviewed value.
        level_obj, old_bar = by_object['Rect63']
        bar = copy.deepcopy(old_bar)
        idx = objects.index(level_obj)
        segment = raw[level_obj['offset']:objects[idx + 1]['offset']]
        matches = list(re.finditer(rb'\x01\x00(.{4})\xff\xff\x00\x00\x00\x00\xff\xfe\xff\x00\x01\x00', segment, re.S))
        fields = [(m.start(), struct.unpack('<f', m[1])[0]) for m in matches if m.start() > 90]
        assert [v for _, v in fields[:4]] == [0.0, 100.0, 0.0, 3.0], (station, fields)
        water = [(n, bindings.get((screen['key'], n['id']))) for n in doc['nodes'] if n['kind'] == 'value']
        water = [(n, b, variables[b['variable_key']]) for n, b in water if b and b['operation'] == 'set' and '水位' in variables[b['variable_key']]['definition']['source_path']]
        assert len(water) == 1, (station, len(water))
        reading, binding, variable = water[0]
        assert variable['definition']['data_type'] in ('FLOAT', 'INT')
        bar.update(id='level-' + old_bar['id'], kind='level', width=8, label='水箱液位', color='#2F93BD', fill='#EDF2F4', level_display=dict(minimum=fields[2][1], maximum=fields[3][1], orientation='vertical'))
        bind(screen, bar, variable)
        added.append(bar)
        audit.append([station, 'Rect63', bar['id'], '液位0～3', level_obj['bindings'][0]['path'], reading['id'], variable['definition']['source_path'], variable['key'], '同图已确认水箱水位；保留原图0～3量程，未改采集倍率'])

        # Replace nonfunctional generic model lamps by the individual pump lamps.
        # Retain all other geometry, assets, readings and original point identities.
        obsolete = {old_bar['id']}
        for objname, (obj, node) in by_object.items():
            paths = [b['path'] for b in obj['bindings']]
            if any(p.REFERENCE.search(path) for path in paths):
                unresolved.append([station, objname, '；'.join(paths), '未绑定：模板占位引用无实例IO映射'])
            if node['kind'] == 'ellipse' and 'B_LightState' in [s['text'] for s in obj['strings']]:
                assert not node.get('point_id') and (screen['key'], node['id']) not in bindings
                obsolete.add(node['id'])
        doc['nodes'] = [n for n in doc['nodes'] if n['id'] not in obsolete] + added
        assert len({n['id'] for n in doc['nodes']}) == len(doc['nodes'])
        summary.append(dict(station=station, lamps=len(added) - 1, levels=1, replaced_model_lamps=len(obsolete) - 1, level_point=variable['key']))

    request['bundle']['variables'] = list(variables.values())
    save(OUT / '01-31张工艺图状态液位更新.json', {'retry_request': request})
    save(OUT / '回退/恢复更新前31张工艺图.json', {'retry_request': original})
    save(OUT / '02-31画面菜单-已有时不必重复导入.json', read(BASE / '02-完整31画面菜单.json'))
    auditdir = OUT / '核对资料'
    auditdir.mkdir(parents=True, exist_ok=True)
    for name, headers, rows in [
        ('状态液位逐项绑定.csv', ['站区','原对象','目标节点','显示','原KS引用','核对依据点','KIO路径','稳定变量','处理依据'], audit),
        ('原图模板引用未直接迁入.csv', ['站区','原对象','原引用','处理'], unresolved),
    ]:
        with (auditdir / name).open('w', encoding='utf-8-sig', newline='') as f:
            writer = csv.writer(f); writer.writerow(headers); writer.writerows(rows)
    result = dict(screens=len(summary), lamps=sum(s['lamps'] for s in summary), levels=len(summary),
                  variables_referenced=len(variables), variables_created=0, original_bindings_preserved=len(original['bundle']['bindings']),
                  original_template_references=len(unresolved), per_screen=summary, source_sha256=source_hashes,
                  baseline_sha256=hashlib.sha256((BASE / '01-完整31张工艺图与绑定.json').read_bytes()).hexdigest(), onsite_applied=False)
    save(auditdir / '统计与来源.json', result)
    print(json.dumps({k: v for k, v in result.items() if k not in ('per_screen', 'source_sha256')}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
