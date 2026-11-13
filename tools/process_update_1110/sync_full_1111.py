"""Sync the HMI overview to the user-confirmed complete 46-slot delivery.

Only produces offline import artifacts. The realtime script is authoritative;
historical definitions are cross-checked without connecting to any database.
"""
from __future__ import annotations

import argparse
import copy
import csv
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

from sync_pumps_1111 import (
    CENTER_SLOTS, LOCAL, ROOT, SOURCE_ID, STANDARD_SLOTS, load, save, script_rows, sha,
)

DEFAULT_SOURCE = Path('D:/DEV_D/ZhuangHe16/庄河完整交付_20261111')
OUTPUT_NAME = '03-数据总览配置-完整交付46项同步.json'
HISTORY_COLUMNS = [13, 6, 14, 15, 7, 8, 9, 10, 11, 12, 1, 2, 3, 4,
                   17, 5, 16, 31, 32, 18, 19, 20, 21, 22, 23, 24, 25,
                   26, 29, 30, 27]
SECOND = {
    'zh-m16': (43, 36, '中心站一区FE202瞬时流量', 't/h'),
    'zh-m17': (44, 37, '中心站一区FE202瞬时热流量', 'GJ/h'),
    'zh-m18': (45, 38, '中心站一区FE202热量总累积值', 'GJ'),
    'zh-m19': (46, 39, '中心站一区FE202流量累积数值整数', 't'),
}
EXPECTED_PRIMARY_CHANGES = {
    ('华府怡景低区', 'zh-m8'): ('中节能_香港广场站_回水_压力', '中节能_华府怡景站_回水_压力'),
    ('华府怡景原阳光壹佰', 'zh-m20'): ('香港广场一区水箱水位', '华府怡景一区水箱水位'),
    ('张屯换热站', 'zh-m15'): ('张屯站一区泵出口压力', ''),
}


def build(source: Path, baseline: Path, xml: Path, points: Path,
          database_doc: Path, out: Path):
    names = [
        '00_使用说明.txt', '03_点位与存储对应.txt',
        'KS脚本/01_KS实时推送_31站区46项.txt',
        '核对资料/实时推送映射_31区46项.json',
        '核对资料/历史采样映射_1037项.json', '核对资料/16项测点.json',
        '庄河HTML/config/energy-report-layout.js',
    ]
    manifest = {x['file']: x for x in load(source / 'SHA256清单.json')}
    fingerprints = {}
    for name in names:
        raw = (source / name).read_bytes()
        assert len(raw) == manifest[name]['bytes'], name
        assert sha(raw) == manifest[name]['sha256'], name
        fingerprints[name] = sha(raw)
    mapping = load(source / '核对资料/实时推送映射_31区46项.json')
    script = (source / names[2]).read_bytes()
    assert sha(script) == mapping['sha256']
    actual = script_rows(script.decode('utf-8-sig'), width=46)
    assert actual == {r['station']: r['values'] for r in mapping['rows']}
    assert len(mapping['columns']) == 46
    assert [c['key'] for c in mapping['columns'][42:]] == [
        '二网2供水流量', '二网2热量瞬时值', '二网2累计热量', '二网2累计流量']
    history_list = load(source / '核对资料/历史采样映射_1037项.json')
    history = {(x['StationName'], x['SampleColumn']): x for x in history_list}
    assert len(history) == len(history_list) == 1037
    tags = {t.attrib['TagName']: t.attrib for t in ET.parse(xml).iter('Tag')}
    by_path = {}
    for d in load(points):
        if d.get('source_id') == SOURCE_ID:
            by_path.setdefault(d.get('source_path'), []).append(d)

    def resolve(path):
        if path is None:
            return '', ''
        assert path.startswith(LOCAL), path
        tag = tags[path[len(LOCAL):]]
        assert tag['IOEnable'] == '1'
        match = re.fullmatch(r'server01\.(.+)\.Value', tag['IOAccess'])
        assert match, path
        assert float(tag['MinRaw']) == float(tag['MinValue']), path
        assert float(tag['MaxRaw']) == float(tag['MaxValue']), path
        candidates = by_path.get(match[1], [])
        assert len(candidates) == 1, (path, len(candidates))
        return match[1], candidates[0]['id']

    original = load(baseline)
    assert original['format'] == 'universal-hmi-live-overview' and original['version'] == 1
    assert len(original['columns']) == 34 and len(original['rows']) == 31
    assert all('additional' not in r for r in original['rows'])
    assert set(actual) == {r['station'] for r in original['rows']}
    result = copy.deepcopy(original)
    result.pop('control', None)
    audit, changes, expected = [], [], {}
    matched_history = set()

    def inspect(row, column, slot, historical, part, prior_path=''):
        station, key = row['station'], column['id']
        ks_path = actual[station][slot - 1]
        sample_column = f'Value{historical:02d}'
        item = history.get((station, sample_column))
        if item is None:
            assert historical in (34, 35) and ks_path is None
        else:
            assert (item['KS路径'] or None) == ks_path, (station, slot, sample_column)
            assert item['除数'] == 1
            matched_history.add((station, sample_column))
        path, point_id = resolve(ks_path)
        audit.append([station, part, key, column['name'], slot, sample_column,
                      ks_path or '', path, prior_path,
                      '新增第二组' if part == 2 else '保持' if path == prior_path else '修订'])
        target = expected.setdefault(row['id'], {'bindings': {}, 'additional': {}})
        if path:
            target['additional' if part == 2 else 'bindings'][key] = point_id
        return path

    for row, prior in zip(result['rows'], original['rows']):
        for c in result['columns']:
            key = c['id']
            if key in ('zh-makeup2-current', 'zh-makeup2-frequency'):
                slot, historical = (39, 34) if key == 'zh-makeup2-current' else (40, 35)
            elif key == 'zh-local-valve':
                slot, historical = 38, 33
            else:
                number = int(key.removeprefix('zh-m'))
                slot, historical = STANDARD_SLOTS[number - 1], HISTORY_COLUMNS[number - 1]
                if row['station'] in ('中心站东南区', '中心站西北区') and number in CENTER_SLOTS:
                    slot = CENTER_SLOTS[number]
            before = prior['bindings'].get(key, {}).get('source_path', '')
            path = inspect(row, c, slot, historical, 1, before)
            if path:
                row['bindings'][key] = {'source_id': SOURCE_ID, 'source_path': path}
            else:
                row['bindings'].pop(key, None)
            if path != before:
                changes.append(audit[-1])
        if row['station'] == '中心站东南区':
            extra = {'columns': list(SECOND), 'bindings': {}}
            for key, (slot, historical, expected_path, unit) in SECOND.items():
                c = next(c for c in result['columns'] if c['id'] == key)
                assert c['unit'] == unit == history[(row['station'], f'Value{historical:02d}')]['Unit']
                assert mapping['columns'][slot - 1]['unit'] == unit
                path = inspect(row, c, slot, historical, 2)
                assert path == expected_path
                d = by_path[path][0]
                assert d['scale_factor'] == 1 and d['offset'] == 0
                extra['bindings'][key] = {'source_id': SOURCE_ID, 'source_path': path}
            assert history[(row['station'], 'Value05')]['Unit'] == 't/h'
            row['additional'] = extra
        outdoor = history[(row['station'], 'Value28')]
        assert outdoor['KS路径'] == mapping['outdoor'] == LOCAL + '室外温度'
        assert outdoor['除数'] == mapping['outdoorDivisor'] == 10
        matched_history.add((row['station'], 'Value28'))

    assert {(r[0], r[2]): (r[8], r[7]) for r in changes} == EXPECTED_PRIMARY_CHANGES
    assert matched_history == set(history)
    assert len(audit) == 1058
    assert sum(bool(r[7]) for r in audit if r[1] == 1) == 894
    assert sum(bool(r[7]) for r in audit if r[1] == 2) == 4
    assert result['columns'] == original['columns'] and result['outdoor'] == original['outdoor']
    assert sum('additional' in r for r in result['rows']) == 1
    out.mkdir(parents=True, exist_ok=True)
    save(out / OUTPUT_NAME, result)
    save(out / '回退-仅泵点更新版.json', original)
    save(out / '解析后的预期绑定.json', expected)
    headers = ['站区', '设备行', '列ID', '指标', '实时位置', '历史列', 'KS来源', 'KIO路径', '原KIO路径', '结果']
    for name, rows in [('总览1058项绑定核对.csv', audit),
                       ('本轮7处修订.csv', [*changes, *(r for r in audit if r[1] == 2)])]:
        with (out / name).open('w', encoding='utf-8-sig', newline='') as f:
            writer = csv.writer(f); writer.writerow(headers); writer.writerows(rows)
    metadata = {
        'reference_directory': str(source), 'verified_reference_files': fingerprints,
        'manifest_sha256': sha((source / 'SHA256清单.json').read_bytes()),
        'database_document': str(database_doc), 'database_document_sha256': sha(database_doc.read_bytes()),
        'baseline_sha256': sha(baseline.read_bytes()),
        'point_fixture_sha256': sha(points.read_bytes()), 'ks_xml_sha256': sha(xml.read_bytes()),
        'realtime_script_slots': 46, 'script_matches_mapping': True,
        'historical_mapping_entries_crosschecked': len(matched_history),
        'logical_rows': 31, 'display_rows': 32, 'columns': 34,
        'primary_bindings': 894, 'additional_bindings': 4, 'unbound_primary_cells': 160,
        'prior_pump_bindings_retained': 12, 'primary_changes': changes,
        'new_additional_columns': list(SECOND), 'both_flow_units': 't/h',
        'current_control_service_settings_preserved': True,
        'software_changed': False, 'live_project_written': False,
        'source_priority': 'User confirmed complete delivery; earlier 42-slot ZIP superseded',
    }
    save(out / '生成核对结果.json', metadata)
    (out / '00-导入说明.txt').write_text('''庄河数据总览 · 完整交付46项同步版（2026-11-11）

采用用户确认正确的 D:/DEV_D/ZhuangHe16/庄河完整交付_20261111。
本版替代此前按42项增量ZIP生成的“补水双泵与北站三泵”配置；沿用已安装的v73，无需重新安装软件。

导入
1. 数据总览 → 配置总览，先导出当前配置备份。
2. 导入“03-数据总览配置-完整交付46项同步.json”，选全部31区。
3. 下一步，确认未匹配项为0，选择“整表替换”，核对后点“保存总览”。
4. 本文件已包含双补水泵及东南区第二组计量，不用再点“补水双泵布局”或手工启用整套双二网。
总览保存即更新显示配置，不需要创建变量、重复导入点表或重新应用采集配置。预览如有未匹配项，先取消并核对详情。

本版变化
- 中心站东南区二网计量：①东区FE201，②南区FE202。仅瞬时流量、瞬时热流量、累计热量、累计流量四项分两行；温度、压力、泵出口压力及其它共用指标仍合并。
- 两组瞬时流量单位t/h、累计流量t，原值不换算；第二组独立绑定，不复制第一组读数。
- 华府怡景低区一次网回水压力改为“中节能_华府怡景站_回水_压力”，与原阳光壹佰共用。
- 华府怡景原阳光壹佰水箱水位改为“华府怡景一区水箱水位”，与低区共用。
- 张屯换热站泵出口压力解除总览绑定，显示“-”；其他站同项保留，不删除变量或历史。
- 原12处泵点、双阀、中心站三泵顺序、西站分区水箱、室外温度已有换算保持。

仍是31个逻辑站区、34个指标列；东南区增加一行，表格共32行。894个第一组绑定+4个第二组绑定。
当前接管服务启用状态和地址保持。按用户选择的标准31区生成，整表替换会使用本文件的标准行列和唯一一组附加行；不会带入另行手工增加的配置。

范围与来源
实际46项实时脚本与映射逐项一致，并与完整交付中的1037项历史映射逐项对应。
实时第43～46项对应FE202，历史对应Value36～39，不能混用这两套编号。
用户确认完整交付中的实时来源正确；数据库原文内旧来源/单位快照不覆盖该完整交付的最终口径。
本文件直接引用本软件现有MQTT变量。SQL、HTML、KS脚本和历史页面按它们各自的交付流程维护，本次不执行或改写它们。
生成及导入检查在本地隔离数据和widget夹具完成，尚未应用现场或18153，也不代表FE202历史已落库。

回退
优先导入操作前自己的备份，整表替换后保存。
附“回退-仅泵点更新版.json”可回到本次之前的34列泵点版；会撤下FE202附加行并恢复此前三处绑定，其中包含旧来源及张屯假点，仅供追溯回退，不建议作为当前配置。
''', encoding='utf-8-sig', newline='\n')
    print(json.dumps({k: v for k, v in metadata.items() if k not in ('primary_changes', 'verified_reference_files')}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, default=DEFAULT_SOURCE)
    parser.add_argument('--baseline', type=Path, default=ROOT / 'outputs/庄河1111总览泵点位更新/03-数据总览配置-补水双泵与北站三泵.json')
    parser.add_argument('--ks-xml', type=Path, default=Path('D:/Users/SunYufei/Downloads/ks变量1110.xml'))
    parser.add_argument('--points', type=Path, required=True)
    parser.add_argument('--database-doc', type=Path, default=Path('D:/DEV_D/数据库设计/KIOHistory_数据库完整详情_20261111.md'))
    parser.add_argument('--output', type=Path, default=ROOT / 'outputs/庄河1111总览完整46项同步')
    args = parser.parse_args()
    build(args.source_dir, args.baseline, args.ks_xml, args.points, args.database_doc, args.output)


if __name__ == '__main__':
    main()
