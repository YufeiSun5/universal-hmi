"""Package verified offline artifacts; never applies them to a live system."""
from pathlib import Path
import csv, hashlib, json, shutil, zipfile
from build import ROOT, OUT, AUDIT, CHECK, load, save, digest

stats=load(AUDIT/'统计与来源.json')
verified=load(CHECK/'import-verification.json')
catchup=load(CHECK/'catchup-verification.json')
rollback=load(CHECK/'rollback-verification.json')
overview=load(CHECK/'overview-gis-verification.json')
render=load(CHECK/'render-verification.json')
assert verified['preview_commit_repeat']=='passed' and catchup['preview_commit_repeat']=='passed'
assert rollback['rollback_to_1103n']=='passed' and overview['overview_import']=='passed'
assert len(render['screens'])==stats['updated_screens']==20
assert 'All tests passed!' in (CHECK/'flutter-render.log').read_text('utf-8-sig')
assert 'All tests passed!' in (CHECK/'flutter-import.log').read_text('utf-8-sig')
assert 'No issues found!' in (CHECK/'flutter-analyze.log').read_text('utf-8-sig')
assert 'FAIL' not in (CHECK/'go-test.log').read_text('utf-8-sig')
assert not (CHECK/'go-vet.log').read_text('utf-8-sig').strip()

with (AUDIT/'31张工艺图差异.csv').open(encoding='utf-8-sig') as f: rows=list(csv.DictReader(f))
changed=[r['站区'] for r in rows if r['纳入增量']=='True']
unchanged=[r['站区'] for r in rows if r['纳入增量']=='False']
with (AUDIT/'工艺读数逐项核对.csv').open(encoding='utf-8-sig') as f:
    missing=[r for r in csv.DictReader(f) if not r['新KIO目标']]

readme=f'''庄河 1104 画面、总览与 GIS 更新包
生成日期：2026-11-04

一、需要更新什么
1. 工艺画面：更新 20 张，另 11 张保持不变。
   红光美苑首站：9 处一次网测点转为中节能西站，新增 1 处原站阀门反馈。
   张屯换热站：4 处二次网热表改为 FI201 流量、热量的瞬时与累计值。
   中心站东南区、西北区：补水泵读数与标注位置更新，新增“2#补水泵”文字。
   其他变动画面主要是电量等文字/读数位置微调，具体见核对资料/画面节点差异.csv。
2. 数据总览：同步红光美苑首站 9 处、张屯 4 处，共 13 处引用。
   保留上一版循环泵从左至右的 1/2/3 顺序，以及已有室外温度引用。
3. GIS：红光美苑首站的公共一次网供、回水温度共 2 处同步。
4. 点表：KS 5,127 个定义未变；KIO 5,119 点无增删，仅中心站 53 个寄存器地址变化。
   本系统 MQTT 使用的来源、主题、变量路径和类型没有因此改变，所以本轮无需新增或重建变量。
   上游 KIO 的地址变化见“上游KIO核对”和对应差异清单。新表是否已在采集机应用需现场核对。

二、已导入上一轮 1103n 包时，按根目录编号操作
先用本机开发态导出当前工艺资料、总览配置和目标 GIS 站点，作为现场实际备份。

01-工艺画面增量更新.json
在“工艺资料导入/导出”导入，预览应为 20 张原画面更新。
导入身份：picx-independent-20261103；来源沿用原 KingIO。
只匹配已有变量，保留变量归属、稳定 ID、类型和存储配置。
若提示目标不存在或变量未匹配，先核对当前工程及来源映射，不能改成创建副本来绕过。
画面内容将更新为本包版本；现场手工编辑请先导出留存。

02-数据总览配置.json
在“数据总览 → 配置总览 → 导入总览配置”导入。
文件包含完整 31 站区、31 个指标列，仅相对上一版改变上述 13 处绑定。
核对行标识、变量匹配和列顺序后进入草稿，再点“保存总览”。
本包保留标准布局；若现场又修改过总览列或行，请先保留现场导出再比较。

03-GIS红光美苑首站-仅公共温度.json
进入 GIS 的“红光美苑首站”编辑，导入站点配置，选择“站公共数据”。
文件只含供水温度、回水温度 2 个公共字段；不含坐标、工艺跳转或分区。
匹配后的变量应为中节能_西站_供水_温度、中节能_西站_回水_温度，再保存 GIS。
变量稳定 ID 来自此前现场导出的 5,082 点快照，已在隔离导入后的同身份点表核实。
若现场已额外增加公共信息或重建过变量，请按“核对资料/GIS显示指标影响.csv”手动只改这两个绑定，保留新增字段。

三、尚未更新 1103n 的情况
仅适用于此前“现场5082变量核对版”已经创建同一身份画面的工程：
使用“补充资料-未更新1103n时使用”中的候选变量补齐文件，再导入“全部31张工艺图-更新原身份.json”。
这一路替代根目录 01，然后继续根目录 02、03。
73 条是上一轮遗留补齐候选，不是 1104 新增；已存在的路径会复用。不得删库或重建现有变量。
若原画面被删除或来自其他导入身份，本包会报告缺失，不自动创建。

四、上游资料中的实际问题
1. 中心站二区主循环泵“变频运行”和“远控状态”在新 KIO 表均为 DB1010.182.0。
   两者原来是不同地址。需硬件工程师确认；本包保留原始记录，没有猜测成 .1 或其他地址。
   “53点原格式记录-核对用.csv”是原字段/原编码摘录，供核对，不是本系统的变量导入文件。
2. 新包“实时数据报表.picx”脚本仍使用红光美苑首站、张屯站的上述 13 处旧引用。
   本系统总览已按新工艺图同步；原 KS 脚本未写回，需维护原报表时同步处理。
   历史/能耗数据库的采样和统计映射不能由画面导入自动改变；若现场也采用这些旧路径，应按同一清单核对。
3. 原有两处无效 KS 引用继续留空：
{chr(10).join('   '+r['站区']+' / '+r['对象']+'：'+r['KS路径'] for r in missing)}
   最新 XML 没有该变量，不能以同名猜测替换。

五、回退与验证
“回退到1103n”可恢复本包涉及的标准旧配置；现场有自定义改动时应优先用自己的导出备份恢复。
工艺回退已经隔离验证，保留原 31 张画面 ID 和全部变量定义。
已通过：当前 Go 全量 test/vet；Flutter analyze；20 张实际 ProcessScene 渲染（含内嵌设备图）；总览/GIS导入相关 11 项；隔离增量、旧版补齐、重复导入、回退和缺失身份阻断。
隔离结果：31 张原画面 ID、5,155 个补齐后的变量定义保留；原现场快照 5,082 个变量定义逐项未变；901 个读数绑定正确，2 个读数留空。
已完成离线资料交付，未导入现场、连接设备、修改 PLC、采集机或生产数据库。
运行端实时值与原生现场画面对照仍需导入后核对。PNG 预览不包含实时读数。

六、画面清单
本轮更新：{'、'.join(changed)}。
无需更新：{'、'.join(unchanged)}。
'''
(OUT/'00-需要更新哪些及导入说明.txt').write_text(readme,encoding='utf-8-sig')
(OUT/'上游KIO核对/先读说明.txt').write_text('本目录只有从用户最新CSV逐字字段摘录的53点原格式记录，编码GB18030。\n适用位置：原KingIO采集工程；不导入智慧供热集中监控系统。\n现场先核对是否已经应用新表，再由硬件工程师核实寄存器。主循环泵运行/远控同地址项未确认，不据此自动覆盖现场。\n本次未执行任何采集工程修改或设备写入。\n',encoding='utf-8-sig')

checks=OUT/'核对资料/验证结果';checks.mkdir(exist_ok=True)
for name in ['import-verification.json','catchup-verification.json','rollback-verification.json','overview-gis-verification.json','render-verification.json','go-test.log','go-vet.log','flutter-render.log','flutter-import.log','flutter-analyze.log']:
    shutil.copy2(CHECK/name,checks/name)
(checks/'当前程序CI说明.txt').write_text('程序基线：bbe46983ad134daac7efd2594108645f978aba53。\nGitHub Verify 41808864699 失败：Flutter client_layout_test.dart 仍查找旧站名“A站 (A)”，与v38只显示站名的实现不一致；四个Flutter平台均在测试步骤失败，打包跳过。Go三个平台、Android成功；Linux lifecycle 41808865425成功。\n本任务只交付配置数据，未更改运行程序或制作新的EXE/APK；未将旧CI标为本次配置验收成功。上述失败保持登记，本次资料验证见相邻日志。\n',encoding='utf-8-sig')
preview=OUT/'画面预览';preview.mkdir(exist_ok=True)
for path in (CHECK/'previews').glob('*.png'): shutil.copy2(path,preview/path.name)
assert len(list(preview.glob('*.png')))==20
save(AUDIT/'生成工具摘要.json',{str(path.relative_to(ROOT)):digest(path) for path in sorted((ROOT/'tools/picx_update_1104').glob('*')) if path.is_file()})

manifest=OUT/'SHA256SUMS.txt'
files=sorted(p for p in OUT.rglob('*') if p.is_file() and p!=manifest)
manifest.write_text(''.join(f'{digest(p)}  {p.relative_to(OUT).as_posix()}\n' for p in files),encoding='utf-8')
archive=ROOT/'outputs/庄河1104-画面点表更新包-20261104.zip'
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for path in sorted(OUT.rglob('*')):
        if path.is_file(): z.write(path,OUT.name+'/'+path.relative_to(OUT).as_posix())
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    for path in files:
        assert hashlib.sha256(z.read(OUT.name+'/'+path.relative_to(OUT).as_posix())).hexdigest()==digest(path)
destination=Path('D:/Users/SunYufei/Downloads/Downloads')/archive.name
shutil.copy2(archive,destination)
assert digest(archive)==digest(destination)
for path in (archive,destination): path.with_suffix('.zip.sha256').write_text(digest(path)+'  '+path.name+'\n',encoding='utf-8')
print(json.dumps(dict(file=str(destination),bytes=destination.stat().st_size,sha256=digest(destination),files=len(files)+1),ensure_ascii=False))
