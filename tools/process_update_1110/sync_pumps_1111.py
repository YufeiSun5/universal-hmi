"""Build the requested standard 31-zone overview from the supplied 42-slot map.

Offline only. Resolves KingSCADA references through the supplied XML to exact
existing KingIO source paths; never creates variables or writes a live project.
"""
from __future__ import annotations

import argparse
import copy
import csv
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
DOWNLOADS = Path('D:/Users/SunYufei/Downloads')
SOURCE_ID = 'source-1793013239860'
SCRIPT = '01_KS实时推送_31站区42项_补齐泵测点.txt'
OUTPUT_NAME = '03-数据总览配置-补水双泵与北站三泵.json'
ROLLBACK_NAME = '回退-上次标准31区总览.json'
LOCAL = '\\\\local\\'

# One-based realtime array positions, not historical Value column numbers.
STANDARD_SLOTS = [10, 11, 12, 13, 3, 5, 4, 6, 7, 8, 14, 16, 15, 17,
                  20, 18, 19, 36, 37, 22, 23, 24, 25, 26, 28, 29, 30,
                  31, 41, 42, 33]
CENTER_SLOTS = dict(zip(range(25, 31), [34, 35, 28, 29, 30, 31]))
PUMP2 = [
    {'id': 'zh-makeup2-current', 'group': '补水泵2', 'name': '补水泵2电流',
     'header': '电流', 'unit': 'A', 'decimals': 1},
    {'id': 'zh-makeup2-frequency', 'group': '补水泵2', 'name': '补水泵2频率',
     'header': '频率', 'unit': 'Hz', 'decimals': 1},
]
EXPECTED_ADDITIONS = {
    ('中心站东南区', 'zh-makeup2-current'): '中心站一区补水2电流',
    ('中心站东南区', 'zh-makeup2-frequency'): '中心站一区补水2频率',
    ('中心站西北区', 'zh-makeup2-current'): '中心站二区补水2电流',
    ('中心站西北区', 'zh-makeup2-frequency'): '中心站二区补水2频率',
    ('阳光壹佰高区', 'zh-makeup2-current'): '阳光壹佰一区#2补水泵电流',
    ('阳光壹佰高区', 'zh-makeup2-frequency'): '阳光壹佰一区#2补水泵频率',
    ('阳光壹佰低区', 'zh-makeup2-current'): '阳光壹佰二区#2补水泵电流',
    ('阳光壹佰低区', 'zh-makeup2-frequency'): '阳光壹佰二区#2补水泵频率',
    ('张屯换热站', 'zh-makeup2-current'): '张屯站一区#2补水泵电流',
    ('张屯换热站', 'zh-makeup2-frequency'): '张屯站一区#2补水泵频率',
    ('新北站南线', 'zh-m29'): '新北站二区循环泵3电流',
    ('新北站南线', 'zh-m30'): '新北站二区循环泵3频率',
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load(path: Path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def save(path: Path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n',
                    encoding='utf8', newline='\n')


def script_rows(script: str):
    samples = {}
    for key, expression in re.findall(
            r'sampleJson\[(\d+)\] = StrFromReal\(([^,]+), 2, "f"\);', script):
        assert key not in samples
        samples[key] = expression.strip()
    result = {}
    station, values = None, []
    for line in script.splitlines():
        line = line.strip()
        start = re.fullmatch(r'''rowJson = "'([^']+)'";''', line)
        sample = re.fullmatch(r'rowJson = rowJson \+ "," \+ sampleJson\[(\d+)\];', line)
        end = re.fullmatch(
            r'''requestText = requestText \+ "appendEnergyReportStationRow\('([^']+)',\[" \+ rowJson \+ "\]\);";''', line)
        if start:
            assert station is None
            station = start[1]
            values = [station]
        elif line == 'rowJson = rowJson + ",null";':
            assert station is not None
            values.append(None)
        elif sample:
            assert station is not None
            values.append(samples[sample[1]])
        elif end:
            assert end[1] == station and station not in result
            assert len(values) == 42
            result[station] = values
            station = None
        elif line.startswith('rowJson ='):
            raise AssertionError('Unrecognized row expression: ' + line)
    assert station is None and len(result) == 31
    return result


def build(source: Path, baseline: Path, xml: Path, points: Path, out: Path):
    original = load(baseline)
    assert original['format'] == 'universal-hmi-live-overview'
    assert original['version'] == 1
    assert len(original['rows']) == 31 and len(original['columns']) == 32
    assert {c['id'] for c in original['columns']} == {
        *[f'zh-m{i}' for i in range(1, 32)], 'zh-local-valve'}
    assert all('additional' not in r for r in original['rows'])
    assert original['outdoor'] == {
        'point_id': {'source_id': SOURCE_ID, 'source_path': '室外温度'}}

    with zipfile.ZipFile(source) as archive:
        assert archive.testzip() is None
        for item in json.loads(archive.read('SHA256.json').decode('utf-8-sig')):
            assert sha(archive.read(item['file'])) == item['sha256'], item['file']
        mapping = json.loads(archive.read('实际推送映射.json'))
        script = archive.read(SCRIPT)
        assert sha(script) == mapping['sha256']
        actual_rows = script_rows(script.decode('utf-8-sig'))
        assert actual_rows == {r['station']: r['values'] for r in mapping['rows']}
        assert len(mapping['columns']) == 42
        assert [c['key'] for c in mapping['columns'][38:]] == [
            '补水泵2电流', '补水泵2频率', '循环泵3电流', '循环泵3频率']

    assert set(actual_rows) == {r['station'] for r in original['rows']}
    tags = {t.attrib['TagName']: t.attrib for t in ET.parse(xml).iter('Tag')}
    definitions = load(points)
    assert isinstance(definitions, list)
    by_path = {}
    for definition in definitions:
        if definition.get('source_id') == SOURCE_ID:
            by_path.setdefault(definition.get('source_path'), []).append(definition)

    def resolve(path):
        if path is None:
            return '', ''
        assert path.startswith(LOCAL), path
        tag = tags[path[len(LOCAL):]]
        assert tag['IOEnable'] == '1', path
        access = re.fullmatch(r'server01\.(.+)\.Value', tag['IOAccess'])
        assert access, path
        assert float(tag['MaxRaw']) == float(tag['MaxValue']), path
        assert float(tag['MinRaw']) == float(tag['MinValue']), path
        source_path = access[1]
        candidates = by_path.get(source_path, [])
        assert len(candidates) == 1, (source_path, len(candidates))
        return source_path, candidates[0]['id']

    result = copy.deepcopy(original)
    # Omit the optional service configuration, so import keeps the current
    # enabled state/address. Row-to-zone mappings are the original stable ones.
    result.pop('control', None)
    for c in result['columns']:
        if c['id'] in ('zh-m23', 'zh-m24'):
            c['group'] = '补水泵1'
            if c.get('header', '') in ('', '补水\n电流', '补水\n频率'):
                c['header'] = '电流' if c['id'] == 'zh-m23' else '频率'
    index = next(i for i, c in enumerate(result['columns']) if c['id'] == 'zh-m24') + 1
    result['columns'][index:index] = copy.deepcopy(PUMP2)
    audit, changes, expected_ids = [], [], {}
    for row, previous in zip(result['rows'], original['rows']):
        assert row['station'] == previous['station']
        station = row['station']
        for column in result['columns']:
            key = column['id']
            if key in ('zh-makeup2-current', 'zh-makeup2-frequency'):
                slot = 39 if key == 'zh-makeup2-current' else 40
            elif key == 'zh-local-valve':
                slot = 38
            else:
                number = int(key.removeprefix('zh-m'))
                slot = STANDARD_SLOTS[number - 1]
                if station in ('中心站东南区', '中心站西北区') and number in CENTER_SLOTS:
                    slot = CENTER_SLOTS[number]
            ks_path = actual_rows[station][slot - 1]
            source_path, point_id = resolve(ks_path)
            before = previous['bindings'].get(key, {}).get('source_path', '')
            if source_path:
                row['bindings'][key] = {'source_id': SOURCE_ID, 'source_path': source_path}
                expected_ids.setdefault(row['id'], {})[key] = point_id
            else:
                row['bindings'].pop(key, None)
            record = [station, key, column['name'], slot, ks_path or '',
                      source_path, before, '新增绑定' if source_path != before else '保持']
            audit.append(record)
            if source_path != before:
                assert not before, record
                changes.append(record)
    assert {(r[0], r[1]): r[5] for r in changes} == EXPECTED_ADDITIONS
    assert len(audit) == 1054 and sum(bool(r[5]) for r in audit) == 895
    assert result['outdoor'] == original['outdoor']
    for previous, row in zip(original['rows'], result['rows']):
        assert {k: v for k, v in row.items() if k != 'bindings'} == {
            k: v for k, v in previous.items() if k != 'bindings'}

    out.mkdir(parents=True, exist_ok=True)
    save(out / OUTPUT_NAME, result)
    rollback = copy.deepcopy(original)
    rollback.pop('control', None)
    save(out / ROLLBACK_NAME, rollback)
    header = ['站区', '列ID', '指标', '实时数组位置（非历史Value）', 'KS来源',
              'KIO来源路径', '原来源路径', '结果']
    for name, rows in [('总览1054格逐项核对.csv', audit), ('本次新增12处绑定.csv', changes)]:
        with (out / name).open('w', encoding='utf-8-sig', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow(header)
            writer.writerows(rows)
    save(out / '解析后的预期绑定.json', expected_ids)
    metadata = {
        'reference_zip': str(source), 'reference_sha256': sha(source.read_bytes()),
        'script_sha256': sha(script), 'script_rows_equal_mapping': True,
        'baseline_sha256': sha(baseline.read_bytes()), 'ks_xml_sha256': sha(xml.read_bytes()),
        'points_fixture_sha256': sha(points.read_bytes()),
        'rows': 31, 'columns': 34, 'cells': 1054, 'bound_cells': 895,
        'unbound_cells': 159, 'old_standard_cells_unchanged': 990,
        'new_bindings': changes, 'existing_point_definitions_only': True,
        'root_control_settings': 'omitted to preserve current configuration',
        'outdoor_conversion': 'existing source path; original FLOAT/0.1 unchanged',
        'software_rebuilt': False, 'onsite_applied': False,
    }
    save(out / '生成核对结果.json', metadata)
    instructions = '''庄河总览泵点位更新 · 2026-11-11（标准31区，配套现有v73）

这次只更新数据总览配置，无需重新安装软件、重复导入变量或执行数据库脚本。
31区、34项指标；补水泵1/补水泵2独立分组，原列宽、同源合并和缺值“-”沿用v73。

导入方法
1. 数据总览 → 配置总览，先点“导出总览配置”留存当前文件。
2. 点“导入总览配置”，选择“03-数据总览配置-补水双泵与北站三泵.json”。
3. 选择全部31区，下一步；确认没有未匹配项，选择“整表替换”。
4. 检查后点“保存总览”才生效。无需再点“补水双泵布局”或重新应用采集配置。

这是按本次确认的“上次标准31区配置”生成的整表文件。
请用“整表替换”：v72界面新增泵2列使用独立生成的标识，直接“合并所选行”可能留下两套泵2列。
标准文件不包含手工增加的区内第二水箱/第二二网、额外行列；需要保留这些定制时应先提供当前导出文件定制更新。
文件省略接管服务设置，导入不会改变当前启用状态和服务地址。
如果预览出现未匹配项，先取消并核对变量详情，不把缺失匹配当成成功导入。

本次新增12处绑定
补水泵2电流/频率：中心站东南区、中心站西北区、阳光壹佰高区、阳光壹佰低区、张屯换热站，共10处。
循环泵3电流/频率：新北站南线，共2处，使用原有第三循环泵列。
中心站仍按主循环泵/辅助循1/辅助循2原顺序，未把新北站的第三泵复制到其他区域。
其余原990个标准格保持；总计895个有效绑定，159个无来源格保留为空，由v73显示“-”。有效零仍显示数值。
室外温度直接引用已有变量，保留现场FLOAT/0.1换算，不额外除10。
这些变量已存在于此前点表中，本包不创建变量、不修改归属或存储规则。

来源与核对
以用户提供的“庄河实时推送与HTML_历史泵列同步_20261111.zip”为来源。
实际周期脚本的31×42位置与包内映射逐项一致，KS路径经ks变量1110.xml解析到精确KingIO来源路径。
实时数组位置与数据库Value编号不是同一编号；本包不修改历史取数、SQL或采样脚本。
附“本次新增12处绑定.csv”和“总览1054格逐项核对.csv”供核对。

回退
优先导入操作前自己的导出备份，选择整表替换并保存。
仅需回到上次标准32列时，可用“回退-上次标准31区总览.json”；它会撤下补水泵2两列并清空北站南线新增的两格，接管服务设置保持。

本次为离线配置交付，未应用现场或18153；实际现场数据由保存后现有采集服务提供。
'''
    (out / '00-导入说明.txt').write_text(instructions, encoding='utf-8-sig', newline='\n')
    print(json.dumps({k: v for k, v in metadata.items() if k != 'new_bindings'},
                     ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-zip', type=Path, default=Path(
        'D:/DEV_D/ZhuangHe16/庄河HTML/output/庄河实时推送与HTML_历史泵列同步_20261111.zip'))
    parser.add_argument('--baseline', type=Path, default=ROOT / 'outputs/庄河1110现场温度兼容包/03-数据总览配置-现场温度兼容.json')
    parser.add_argument('--ks-xml', type=Path, default=DOWNLOADS / 'ks变量1110.xml')
    parser.add_argument('--points', type=Path, required=True,
                        help='Read-only existing point definitions for exact identity verification')
    parser.add_argument('--output', type=Path, default=ROOT / 'outputs/庄河1111总览泵点位更新')
    args = parser.parse_args()
    build(args.source_zip, args.baseline, args.ks_xml, args.points, args.output)


if __name__ == '__main__':
    main()
