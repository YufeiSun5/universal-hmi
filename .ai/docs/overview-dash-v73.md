# 数据总览空值横线 v73

2026-11-11用户要求没有数据时不显示“未知”，只留`-`。本批限Flutter live_overview展示：未绑定、缺失、离线、陈旧、坏质量和未知质量读数均显示ASCII短横线；表格、手机卡片、室外温度和CSV一致。详细原因及质量仍在提示中，有效零和其它正常值不变。无数据时间及手机未知接管标签同样为`-`；不改采集、绑定、后端状态、接管配色或共享工艺图格式器。

已调整现有总览/双泵/双设备测试的显示预期。Flutter analyze及684项测试通过（2项既有跳过），覆盖无效值隐藏、泵1有效零、双设备第二组异常显示及原交互。首次analyze误从仓库根目录启动，已停止并在app模块内通过检查。Windows/Web同源release和包内资源摘要核验通过。

初次封装因构建期间提交使Windows/Web记录的git revision不同而被拒绝；两者源码摘要相同。固定提交后重新构建Windows并通过最终两端身份及文件摘要核验，没有改写或放宽验证。

本批后端未修改，不重跑Go测试；未重跑浏览器交互和安装升级/卸载矩阵，未生成安卓APK，未部署现场或18153。只更新已有测试预期，未新增测试平台或变更质量语义。

应用提交`62229229b534f953d7b90787e98d794e2a43070f`，源码摘要`32ac899c7303ffd34d8bd4644395a60b7ecaac50bb2c748826eb199903487e86`。交付[完整包清单](evidence/20261111-v73/release.json)及[验证摘要](evidence/20261111-v73/verification.json)。Downloads中提供`Universal-HMI-20261111-Full-v73-Setup.exe`（268621822字节）、`v73-空值横线-说明.txt`和`v73-SHA256.txt`。SHA256：`1296e4407d05a07f3a2a21fdde05094d6e2345892cbb4c1a64c79acae9e6918f`。安装后刷新Web即可，不需重导变量或总览。

交付核对时，本应用提交的[Linux生命周期CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/42955358538)成功；[跨平台CI](https://github.com/YufeiSun5/universal-hmi/actions/runs/42955358557)仍运行中，不声称全部远端通过。最终安装器文件版本及产品版本均为0.1.0.73。
