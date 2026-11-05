"""Complete the user's exported process set through the existing transfer contract."""
from pathlib import Path
import collections, copy, hashlib, json

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'outputs/工艺图完整导入-20261105'
SOURCE = Path('D:/Users/SunYufei/Downloads/process-bundle.json')

def read(path):
    return json.loads(Path(path).read_text('utf-8-sig'))

def save(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':'))+'\n', encoding='utf8')

def main():
    actual = read(SOURCE)
    latest = read(ROOT/'.local/update-1104/full-request.json')['retry_request']
    by_name = {s['document']['name']:s for s in actual['screens']}
    assert len(by_name) == 28
    def signature(d):
        return (d['source_type'], latest['source_map'].get(d['source_id'], d['source_id']), d['topic'], d['source_path'], d['data_type'], d['unit'])
    candidates = collections.defaultdict(list)
    for v in actual['variables']:
        candidates[signature(v['definition'])].append(v)
    var_map = {}
    for v in latest['bundle']['variables']:
        matches = candidates[signature(v['definition'])]
        assert len(matches) == 1, (v['key'], len(matches))
        var_map[v['key']] = matches[0]
    request = copy.deepcopy(latest)
    request['bundle']['screens'] = []
    request['screen_targets'] = {}
    records = []
    for s in latest['bundle']['screens']:
        d = s['document']
        current = by_name.get(d['name'])
        target_station = (current or s)['document']['station']
        sid = 'sc_imp_'+hashlib.sha256(json.dumps([request['import_identity'],s['key'],target_station],ensure_ascii=False,separators=(',',':')).encode()).hexdigest()[:24]
        if current:
            assert current['key'] == 'screen_'+sid
        request['station_map'][d['station']] = target_station
        new = copy.deepcopy(current or s)
        new['key'] = s['key']
        # Keep the source station as the map key; the destination is the actual station.
        new['document']['station'] = d['station']
        request['bundle']['screens'].append(new)
        request['screen_targets'][s['key']] = {'mode':'update_imported' if current else 'create', 'id':sid}
        records.append({'screen_id':sid,'name':d['name'],'target_station':target_station,'existing':bool(current),'key':s['key']})
    used = {}
    for b in request['bundle']['bindings']:
        if b['operation'] == 'set':
            v = var_map[b['variable_key']]
            b['variable_key'] = v['key']
            used[v['key']] = v
    request['bundle']['variables'] = list(used.values())
    request['variable_targets'] = {k:{'mode':'match_existing'} for k in used}
    request['source_map'] = {v['definition']['source_id']:v['definition']['source_id'] for v in used.values()}
    for v in used.values():
        st = v['definition']['station']
        request['station_map'][st] = st
    request['create_stations'] = [r['target_station'] for r in records if not r['existing']]
    save(OUT/'01-完整31张工艺图与绑定.json', {'retry_request':request})
    menu = read(ROOT/'outputs/工艺图菜单-20261105/工艺图菜单-31画面-20261105.json')
    old = read(ROOT/'outputs/工艺图菜单-20261105/画面引用核对.json')
    names = {r['screen_id']:r['name'] for r in old}
    by_name_new = {r['name']:r for r in records}
    leaves = []
    def walk(nodes):
        for n in nodes:
            if n.get('screen_id'):
                n['screen_id'] = by_name_new[names[n['screen_id']]]['screen_id']
                leaves.append(n['screen_id'])
            walk(n.get('children',[]))
    walk(menu['nodes'])
    assert len(leaves) == len(set(leaves)) == 31
    assert set(leaves) == {r['screen_id'] for r in records}
    save(OUT/'02-完整31画面菜单.json', menu)
    save(OUT/'核验资料/画面引用核对.json', records)
    save(OUT/'核验资料/来源摘要.json', {'export_sha256':hashlib.sha256(SOURCE.read_bytes()).hexdigest(),'existing_screens':28,'new_screens':[r['name'] for r in records if not r['existing']],'variables_referenced':len(used),'variables_created':0,'bound_readings':sum(b['operation']=='set' for b in request['bundle']['bindings']),'blank_readings':sum(b['operation']=='clear' for b in request['bundle']['bindings']),'onsite_import':'pending'})
    (OUT/'00-导入说明.txt').write_text('''工艺图完整导入文件（2026-11-05）

以你本次导出的28张画面及5155个变量为基准，补齐为31张。
补入景泰高区、景泰低区、金岳福里低区；张屯4处FE201改为FI201。
保留现有28张画面的ID、归属、布局；只引用已有变量，不新建变量。
红光美苑高区、新北站北线各一处上游未确认的读数仍留空。

第一步：开发态 → 工艺资料导入 → 选择“01-完整31张工艺图与绑定.json”。
加载文件预设映射，保留全部画面、变量、绑定的选择，先预览。
预期：3张补齐，张屯更新，其余27张保持一致；无未处理项。
确认导入；若预览报告目标缺失或变量不唯一，保留错误信息，不改成创建变量。
如果3张图之前实际存在但本次未导出，同一导入身份会复用它们，不另造副本。

第二步：页面导航配置 → 导入菜单 → 选择“02-完整31画面菜单.json”。
替换菜单草稿 → 保存菜单。先导图再导菜单，避免缺失目标。
本次菜单按原菜单31站区组织；张屯指向现有真实画面ID。

导入后核对31张画面和景泰/金岳低区入口、张屯4个读数。
本包仅工艺画面与菜单，不覆盖GIS、总览、账号或采集来源配置。
信号灯红绿和文字条件变色属于后续软件功能，本文件尚未加入。
离线预览/提交/重复导入验证不等于现场实时数据验收。
''', encoding='utf-8-sig')
    print('Created complete bundle:', len(records), 'screens,',len(used),'existing variables')

if __name__ == '__main__':
    main()
