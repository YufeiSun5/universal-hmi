"""Package the already verified offline process update for the user."""
from pathlib import Path
import hashlib
import json
import shutil
import zipfile
from build import ROOT, OUT

result = json.loads((OUT / '核对资料/验证记录.json').read_text('utf8'))
assert result['status'] == 'passed' and result['baseline_then_update_repeat_rollback']
(OUT / '00-导入说明.txt').write_text('''工艺状态与液位更新 · v48 · 2026-11-05

先覆盖升级到v48，再导入画面文件；安装软件不会自动改动你的画面。
在开发态的工艺资料导入入口选择“01-31张工艺图状态液位更新.json”，预览后提交。
已有完整31画面菜单时，不需要导入02；缺少菜单时在页面导航配置导入02、替换草稿并保存。
导入前可以先导出自己的当前画面备份；本包以你提供的28张导出和随后确认的完整31张更新为基准。

本包内容
1. 31张画面保留原身份、站区、设备图片、管路和903处原读数位置（901绑定、2原有空位）。
2. 新增81个泵反馈状态灯：运行绿、停止红、无数据/坏质量/断线灰色，默认常亮。
   一幅泵图标代表多台泵的，在每台泵名称旁分别显示。输入取已存在的BOOL运行反馈，不按频率或命令推断。
   中心站两处2#补水标签原误引1#频率，按同图已确认的2#读数校正对应运行点。
   原来62个未绑定模板灯由这些实际单泵灯替代。
3. 31条水箱液位条：宽8px、贴原水箱位置，无文字；复用各图已经确认的水位点。
   量程沿用PICX原图的0～3工程值；不转换单位或改变采集倍率。现场量程不同可在液位条属性中修改上下限。
   无效数据为未知斜线，不补零；越界有橙色边框，悬停可看比例与范围。
4. 只引用现有785个变量，不新增、删除或迁移变量，不改来源、账号、GIS、数据库及物理设备。
5. 允许重复导入，不创建重复画面。回退文件恢复本次更新前的完整31张画面；回退不等于恢复你后续另做的修改。

尚未猜绑的原图项目
原图的阀门仍使用“引用模型1.高温水供水调节阀反馈／泄压阀开关输出”等模板占位引用，
缺少各站实例到实际IO点的映射；本包保留原阀门图形和已有数值读数，没有虚构开关反馈。
全部原占位引用及逐项处理列在核对资料中；用户已确认“没有的就没有”，缺少实际点名的保持原显示。

核验
通过生产导入逻辑的预览、提交、重复导入和回退；5155变量不变、31画面身份保持、903处原读数不变。
31张图通过实际Flutter渲染器检查；“预览-模拟值”仅演示红绿灯和半满液位，不是现场数据。
没有向现场或本机18153导入，也没有写入PLC、KS、KIO或现场数据库。
''', 'utf-8-sig')
preview = OUT / '预览-模拟值'
preview.mkdir(exist_ok=True)
for name in ('中心站东南区', '新南站新华线区'):
    shutil.copy2(ROOT / '.local/process-state-restore-v48/previews' / (name + '.png'), preview)
archive = ROOT / 'outputs/工艺状态液位更新-20261105-v48.zip'
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
    for path in sorted(OUT.rglob('*')):
        if path.is_file():
            z.write(path, Path(OUT.name) / path.relative_to(OUT))
print(json.dumps({'file': str(archive), 'bytes': archive.stat().st_size,
                  'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}, ensure_ascii=False))
