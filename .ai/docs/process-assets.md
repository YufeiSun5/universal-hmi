# 免费实物与伪 3D 素材筛选

筛选日期：2026-10-09。用户要求免费、适用于工艺画面的实物素材，并支持自有透明 PNG。这里只记录已核对的来源；不把研究结果当作已随软件内置的素材。现有 458 个 MIT 静态 SVG 和上传流程见 [工艺画面](process-screens.md)。

| 来源 | 免费与许可依据 | 设备与效果 | 当前适用方式 |
| --- | --- | --- | --- |
| [Visual Toolkit](https://grindstone-systems.github.io/visual-toolkit/) | [官方仓库](https://github.com/Grindstone-Systems/visual-toolkit) 明示代码 Apache-2.0、图库 CC0-1.0、导出 SVG 归使用者；无需账户。嵌入代码须保留 [许可证](https://github.com/Grindstone-Systems/visual-toolkit/blob/main/LICENSE) 及适用通知 | README 列出泵、阀门、电机、罐、输送机、换热器、风机、压缩机、静态混合器、仪表、管件 11 类。实际浏览器已显示带电机与底座的离心泵 3D 模型 | 免费候选。SVG/PNG 按钮导出二维符号；3D 导出为 GLB，要作为现有画布透明 PNG 素材还需离线渲染。项目仍为 preview，不能承诺图库全面或所有设备的 3D 导出均已验证 |
| [Openclipart](https://openclipart.org/) | [官方 FAQ](https://openclipart.org/share) 明示上传采用 CC0、可修改及无限商用。逐项避开 pd_issue 等来源疑问标记 | 已查看 [端吸离心泵](https://openclipart.org/detail/271782/end-suction-pump)，为渐变二维侧视图，立体感弱于完整模型；另有 [立式罐](https://openclipart.org/detail/243312/tanque)、[卧式罐](https://openclipart.org/detail/243313/tanque-acostado)、[料斗](https://openclipart.org/detail/243315/tolva)、[料仓](https://openclipart.org/detail/243311/silo) 设备页面 | 免费补充来源，各页面提供 SVG/PNG 下载；风格零散，需逐张筛选。罐/料斗页面已核查，但本轮未完成所有图的实际渲染检查 |

截至本次筛选，没有确认一个同时满足“长期免费、统一逼真实物风格、工艺设备覆盖全面、可随通用软件再分发”的成熟完整包。可用现有 MIT 工艺符号作为基础，再逐项补充免费模型渲染图和 CC0 实物图；用户自有透明 PNG 通过「我的素材」进入相同放置/拖拽流程。

[离心泵实际网站 3D 预览](evidence/20261009-process/free-3d-pump-preview.png) 展示带电机、联轴器与底座的立体效果；这是预览截图，不是已经导出的透明 PNG。本轮还实际查看了 Openclipart 料斗的金属渐变侧视图；储罐系列未逐张渲染核验。

## 不作为长期免费内置来源

- [KonnectSymbols 定价](https://www.konnectsymbols.com/pricing) 在核查时公开 beta 免费，未来有付费计划；[许可](https://www.konnectsymbols.com/license) 允许项目使用，但不允许作为独立素材库、模板或源文件包再分发。因此不能把“当前可免费导出”解释成长期免费随软件内置。
- Opto 22 的 [SVG 库介绍](https://blog.opto22.com/optoblog/optonews-add-context-with-svg-image-library) 称素材免费，但通用 [网站条款](https://www.opto22.com/special-pages/terms-conditions) 对下载/复制默认限定个人非商业用途；本轮未找到足够明确的商用再分发例外。不纳入已审阅内置包；FUXA 根 MIT 不自动覆盖其带 Opto 22 版权的其他素材目录。

素材版权与软件集成需要分别核查。后端只接收解码过的 PNG/JPEG，不执行外部 SVG/GLB 或脚本；新增第三方 SVG/模型引擎应另行审阅并记录固定来源。
