# v87 · 物料菜单、窄树、页面三列布局

2026-11-14按用户纠正实施：**侧边菜单 → 超窄树形 → 页面**，替代此前“菜单下方分类树”的布局。源码 `74f00da439965245cad51800d781a0dee94d6cf6`；构建摘要 `ee35d933a6142a3df620bd857af518c67971137e624df97ca47a4cba1ed6b33a`。

桌面业务菜单保留既有248px；分类树独立120px列并占满工作区高度；业务页面占剩余空间。树使用紧凑缩进、两行名称及完整路径提示，搜索和分页保持，展开/收起归入树顶操作菜单。收起业务菜单不会移除分类树。纯申请/审批不出现分类筛选，手机物料隐藏保持。后端查询、权限和存储均未修改。

## 验证

- Go全test/vet通过；Flutter analyze无问题、完整761项通过/2项既有跳过，37项布局及相关回归通过。
- 两种窗口widget断言菜单/树/页面横向相邻且不嵌套，树宽120px、全高；选子类请求正确，收起菜单保留树，清除分类恢复查询。
- 真实Chrome正常TLS/MFA会话，1366×768、1920×1080、1093×614截图已检查。父类筛出2种物料/1张单，清除恢复6张单；菜单收起保留树、全部收起与展开正常。
- Windows/Web相同源码摘要及组包校验通过；完整安装器0.1.0.87，Android版本87；APK22项单测/Lint通过、5743个内嵌Web文件逐字匹配，签名沿用原证书。
- 上轮远端CI43462985518最终四端Flutter均失败于同一旧测试：将宿主日期误当北京时间；北京时间14日时UTC宿主仍13日。本轮修正测试预期为UTC+8，不改产品业务日期。新[CI43553495629](https://github.com/YufeiSun5/universal-hmi/actions/runs/43553495629)核对时Linux/Windows后端和Android通过，macOS及后续目标在途，不声称远端全部成功。

本轮未部署现场/18153，没有重跑完整安装覆盖/卸载矩阵、原生系统DPI/IME、真实KP或手机真机。缩小视口仅证明对应可用空间布局。

## 交付

`D:/Users/SunYufei/Downloads/物料三列布局_v87_20261114`：独立完整EXE、同签名APK、说明、截图、验收及SHA256，无ZIP。包含v86及此前功能，无需先安装v86。

| 文件 | SHA256 |
| --- | --- |
| Universal-HMI-20261114-Full-v87-Setup.exe | `084f33951927b34fd7e1c4171b521a586b7828ccd1c882a9b88f48954a402c22` |
| Universal-HMI-Android-v87.apk | `080574453df41556ea151ead197621942159681b55016bb70b2738e32cde200b` |

[发布摘要](evidence/20261114-materials-v87/release-result.json)、[实际浏览器](evidence/20261114-materials-v87/browser-result.json)、[APK核对](evidence/20261114-materials-v87/apk-verification.json)、[CI快照](evidence/20261114-materials-v87/ci-summary.json)。同目录保留相关测试及构建日志。

截图：[三列1366](evidence/20261114-materials-v87/v87-three-columns-1366.png)、[父类筛选](evidence/20261114-materials-v87/v87-category-filter-1366.png)、[1920宽屏](evidence/20261114-materials-v87/v87-three-columns-1920.png)、[缩小窗口](evidence/20261114-materials-v87/v87-three-columns-effective125.png)、[菜单收起树保留](evidence/20261114-materials-v87/v87-menu-hidden-tree-kept.png)。
