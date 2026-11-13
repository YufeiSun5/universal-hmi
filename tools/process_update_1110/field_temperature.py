"""Offline v66 variant for the reported FLOAT / 0.1 outdoor point.

The original package was built against INT / 1 metadata. Never overwrite an
existing engineering conversion merely to make that package match.
"""
from pathlib import Path
import copy
import hashlib
import json
import zipfile

ROOT = Path(__file__).resolve().parents[2]
DOWNLOADS = Path('D:/Users/SunYufei/Downloads')
OUT = ROOT / 'outputs/庄河1110现场温度兼容包'


def build():
    original = json.loads((ROOT / 'outputs/庄河1110更新包/01-新增31变量与室外温度派生.json').read_text('utf-8'))
    data = copy.deepcopy(original)
    request = data['retry_request']
    variables = request['bundle']['variables']
    outdoor = next(v for v in variables if v['definition'].get('source_path') == '室外温度')
    assert outdoor['definition']['data_type'] == 'INT'
    assert outdoor['definition']['scale_factor'] == 1
    outdoor['definition'].update(data_type='FLOAT', scale_factor=0.1)
    request['bundle']['variables'] = [v for v in variables if v['key'] != 'outdoor-div10']
    del request['variable_targets']['outdoor-div10']
    assert len(request['bundle']['variables']) == 32
    assert request['bundle']['variables'][:31] == original['retry_request']['bundle']['variables'][:31]
    assert request['variable_targets'][outdoor['key']] == {'mode': 'match_existing'}

    overview = json.loads((ROOT / 'outputs/庄河1110北站点位修正/03-数据总览配置-北站点位修正.json').read_text('utf-8'))
    overview['outdoor'] = {'point_id': {'source_id': outdoor['definition']['source_id'], 'source_path': '室外温度'}}
    OUT.mkdir(parents=True, exist_ok=True)
    files = {
        '01-新增31变量与已有室外温度.json': data,
        '03-数据总览配置-现场温度兼容.json': overview,
    }
    for name, content in files.items():
        (OUT / name).write_text(json.dumps(content, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')

    instructions = '''庄河1110现场温度兼容版（配套已安装的v66，无需重装）

适用现场：室外温度来源source-1793013239860、路径室外温度、FLOAT、倍率0.1、偏移0。
旧包按INT/倍率1匹配，造成室外温度及其依赖派生点两项未匹配。本版严格匹配现场FLOAT/0.1配置，保留原变量身份、归属、类型和倍率；直接显示已有工程值，不新增或使用÷10派生点。原始值100由原采集变量换算为10，总览仍显示10，不会再次变成1。

操作顺序：
0. 先导出当前工程/总览备份。当前旧导入预览用“更换导入文件”换本版01，不要强制匹配旧包的两个未匹配项。
1. 工艺包导入：01-新增31变量与已有室外温度.json，预览后提交。首次增加31个只读采集变量，已有室外温度应显示保持不变；已由旧包成功增加的同身份31点重复导入不新增副本。
2. 工艺包导入：02-全部31张透明工艺图.json（与前包相同，已完成可跳过）。
3. 数据总览→配置总览→导入总览配置：03-数据总览配置-现场温度兼容.json，预览、合并所选行、保存总览。必须使用此03，它同时保留北站两处修正，并将标题温度改用已有室外温度。标准行列会更新，先备份自己的定制。
4. 原31图菜单正常则跳过04；缺菜单才导入04。
5. 新增变量保存只修改配置；如界面提示运行配置未应用，完成检查后按原流程应用，再查看实时数据。不要把预览或保存当成已开始采集。

如果预览还有其他未匹配项，保留详情，不强制修改原变量。现有室外温度倍率保持0.1，不要改1，也不要额外除10。若旧派生点已经建成，本版不删除它，但总览不再使用它。
接管状态仍默认关闭，由工程师核对后启用；室外温度无需另设显示倍率。
00文件是说明，不导入；回退目录仅在需要回退时使用，以操作前自己的备份为准。

旧00导入说明及核对资料描述的是此前基线，涉及“新增室外温度派生、原值÷10”的内容由本说明替代。31张图的2个未定义PIC引用与这次室外温度匹配问题无关，仍保持缺值。本版仅为离线配置交付，未应用现场，未修改现场数据库或软件程序。
'''
    (OUT / '00-现场温度兼容版使用顺序.txt').write_text(instructions, encoding='utf-8-sig', newline='\n')
    archive = DOWNLOADS / '庄河1110更新包-v66-现场温度兼容版.zip'
    with zipfile.ZipFile(DOWNLOADS / '庄河1110更新包-v66-北站修正版.zip') as source, zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as target:
        for item in source.infolist():
            name = item.filename
            if name.endswith('/01-新增31变量与室外温度派生.json'):
                name = name.replace('01-新增31变量与室外温度派生.json', '01-新增31变量与已有室外温度.json')
                payload = (OUT / '01-新增31变量与已有室外温度.json').read_bytes()
            elif name.endswith('/03-数据总览配置.json'):
                name = name.replace('03-数据总览配置.json', '03-数据总览配置-现场温度兼容.json')
                payload = (OUT / '03-数据总览配置-现场温度兼容.json').read_bytes()
            else:
                payload = source.read(item)
            target.writestr(name, payload)
        target.writestr('庄河1110更新包/00-现场温度兼容版使用顺序.txt', (OUT / '00-现场温度兼容版使用顺序.txt').read_bytes())
    for name in [*files, '00-现场温度兼容版使用顺序.txt']:
        (DOWNLOADS / name).write_bytes((OUT / name).read_bytes())
    hashes = '\n'.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}' for p in [archive, *(DOWNLOADS / n for n in files)]) + '\n'
    (DOWNLOADS / '庄河1110现场温度兼容-SHA256.txt').write_text(hashes, encoding='utf-8-sig')
    print(hashes)


if __name__ == '__main__':
    build()
