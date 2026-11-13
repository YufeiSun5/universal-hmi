"""Align the delivered overview with the user's authoritative 31-zone KS table.

Only produces offline import artifacts; never writes a running project.
"""
from pathlib import Path
import copy, csv, hashlib, json, re, zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path('D:/DEV_D/KS_HELP/output/庄河实时与存储_北站修正_20261110/庄河实时与历史存储_KS变量逐站核对表_20261110.md')
DOWNLOADS = Path('D:/Users/SunYufei/Downloads')
OUT = ROOT/'outputs/庄河1110北站点位修正'
ORDER = [13,6,14,15,7,8,9,10,11,12,1,2,3,4,17,5,16,31,32,18,19,20,21,22,23,24,25,26,29,30,27]

def build():
    rows = {}; station = None
    for line in SOURCE.read_text('utf-8-sig').splitlines():
        if line.startswith('## '): station = None
        match = re.match(r'### \d+\. (.+)（([\d-]+)）',line)
        if match:
            station = match[1]; assert station not in rows; rows[station] = {}
        if station and line.startswith('| □ | Value'):
            fields = [f.strip() for f in line.split('|')[1:-1]]
            if len(fields) != 6: continue
            number = int(fields[1][5:]); assert number not in rows[station]
            paths = re.findall(r'`([^`]+)`',fields[4]); assert len(paths) <= 1
            rows[station][number] = paths[0].removeprefix('\\\\local\\') if paths else ''
    assert len(rows)==31 and all(set(r)==set(range(1,34)) for r in rows.values())
    assert sum(bool(v) for row in rows.values() for v in row.values())==914
    assert {r[28] for r in rows.values()}=={'室外温度'}
    ks = {t.attrib['TagName']:t.attrib for t in ET.parse(DOWNLOADS/'ks变量1110.xml').iter('Tag')}
    old = json.loads((ROOT/'outputs/庄河1110更新包/03-数据总览配置.json').read_text('utf8'))
    result = copy.deepcopy(old); changes = []; audit = []
    for row in result['rows']:
        for column in result['columns']:
            key = column['id']; number = 33 if key=='zh-local-valve' else ORDER[int(key[4:])-1]
            name = rows[row['station']][number]; path = ''
            if name:
                tag = ks[name]; assert tag['IOEnable']=='1'
                match = re.fullmatch(r'server01\.(.+)\.Value',tag['IOAccess']); assert match
                path = match[1]
            prior = row['bindings'].get(key,{}).get('source_path','')
            audit.append([row['station'],key,column['name'],f'Value{number:02d}',name,path,prior,'一致' if prior==path else '修正'])
            if path!=prior:
                changes.append(audit[-1])
                if path: row['bindings'][key]={'source_id':'source-1793013239860','source_path':path}
                else: row['bindings'].pop(key,None)
    assert len(audit)==992 and len(changes)==2
    assert {(r[0],r[1]) for r in changes}=={('新北站南线','zh-m4'),('原北3#伟业区','zh-m6')}
    assert result['columns']==old['columns'] and result['outdoor']==old['outdoor'] and result['control']==old['control']
    OUT.mkdir(parents=True,exist_ok=True)
    revised = (json.dumps(result,ensure_ascii=False,separators=(',',':'))+'\n').encode('utf8')
    (OUT/'03-数据总览配置-北站点位修正.json').write_bytes(revised)
    (OUT/'回退-修正前总览.json').write_bytes((ROOT/'outputs/庄河1110更新包/03-数据总览配置.json').read_bytes())
    with (OUT/'总览992项逐项核对.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.writer(f); writer.writerow(['站区','列ID','指标','历史对应','权威KS路径','目标KIO路径','原KIO路径','结果']); writer.writerows(audit)
    explanation = '''v66 北站实时点位修正版（仅导入配置，无需重装软件）

以用户指定的“庄河实时与历史存储_KS变量逐站核对表_20261110.md”为准，核对31区全部33项定义、总览32列共992项绑定。
仅两处修正：
1. 新北站南线/一次网累计流量：中节能_北站_回水_累计_流量 → 中节能_北站_供水_累计_流量。
2. 原北3#伟业区/一次网回水温度：中节能_中心站_回水_温度 → 中节能_北站_回水_温度。
其他990项、双阀20/31区绑定、中心站泵序、标题温度后端÷10及原小数位设置保持。表内明确保留的跨站引用不擅自替换。

已导入上一版配置：只导入“03-数据总览配置-北站点位修正.json”。在数据总览→配置总览→导入总览配置，预览后合并所选行并保存。不需要重新安装软件或重复导入变量、工艺图和菜单。导入前先导出自己的当前配置备份；此文件包含全部31行标准配置，合并会更新所选标准行和标准列的设置，无关自定义行列保留。
尚未导入上一版配置：使用“完整导入包-北站修正版.zip”，按包内00说明依次导入；其中03已替换为修正版，其他原文件字节保持。
回退仅本次两处改动：导入“回退-修正前总览.json”，选择按行列标识合并并保存；自定义内容以操作前自己的导出备份为准。

本次修改总览配置，不改变采集变量定义、设备控制、现场数据库或软件安装。两份现场脚本的质量位与两位小数描述用于口径核对，本次不改变MQTT质量处理或现有显示精度。未连接现场核验仪表实际值。
完整包中原“总览逐格核对.csv”和“总览最终差异.csv”保留为此前1110生成记录；北站两处以新增“总览992项逐项核对-北站修正.csv”为准。
'''
    (OUT/'00-本次修正与导入说明.txt').write_text(explanation,encoding='utf-8-sig')
    with zipfile.ZipFile(DOWNLOADS/'庄河1110更新包-v66-双阀版.zip') as source, zipfile.ZipFile(OUT/'完整导入包-北站修正版.zip','w',zipfile.ZIP_DEFLATED,compresslevel=6) as target:
        for item in source.infolist():
            target.writestr(item.filename,revised if item.filename.endswith('/03-数据总览配置.json') else source.read(item))
        target.writestr('庄河1110更新包/00-北站修正补充说明.txt',explanation.encode('utf-8-sig'))
        target.writestr('庄河1110更新包/核对资料/总览992项逐项核对-北站修正.csv',(OUT/'总览992项逐项核对.csv').read_bytes())
    metadata={'source':str(SOURCE),'source_sha256':hashlib.sha256(SOURCE.read_bytes()).hexdigest(),'stations':31,'definitions':1023,'bound_definitions':914,'overview_cells':992,'changed':changes,'software_rebuilt':False,'onsite_applied':False}
    (OUT/'核对结果.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n',encoding='utf8')
    print(json.dumps(metadata,ensure_ascii=False))

if __name__=='__main__': build()
