# 当前上下文

更新：2026-10-10 素材接管修复。截图中的板式换热器空隙源于 SVG 等比居中而端口按元素外框计算，旋转也未同步。新增纯 `symbol_geometry.dart` 和离线生成的 462 项 viewBox 尺寸常量，绘制/吸附/管道解析统一；四个自绘设备使用实际绘图接触坐标，未审阅外部设备仍只提供内容框边点。稳定端口名与后端文档不变，已有连接随缩放/旋转校正，自由管道不猜测绑定。Go test/vet、Flutter analyze/131项/68文件只读格式、Python3项、Windows/Web release+verify-only passed，源码 `c8ecdd90…`，构建基线10af848。四设备×四方向像素断口、真实 Chrome 右边拖宽/接新管/撤销和640×360嵌入通过；18139仅更新Web，三张用户图摘要未变，用户页未刷新。证据 `.ai/docs/evidence/20261010-process-symbol-ports/verification.json`。此前10af848 CI38022212602及生命周期38022212630 success，本修复新head以PR14为准。

更新：2026-10-10 管道/箭头批次。`codex/process-canvas` 增加端点/中部拼接、草稿按点击撤销/重做、直角单轴投影与方向迟滞、自由角及 5/10/15/30/45/90° 步长；伪 3D 圆管、独立圆角/半径/弯头设置；智能参考线/吸附及 Shift 拖动约束；箭头间距/整条总数（旧 segments 归一）、动画、反向朝向与运动、最多八项 AND/OR 显示/运动条件。模板导出及所有实例化清空实际绑定，实例才选择该站变量。纯几何/展示模块在 features/process，Go process 唯一校验/原子保存，不触发设备控制。Go 全量 test/vet、Flutter analyze/全量128项/65文件只读格式、Windows/Web release+verify-only passed，工作树源码摘要 `180a2896…`、Git 基线 f6cbc01。独立真实 Chrome 验证水平防偏移/绘制撤销/保存重读、中心参考线、管道分支、模板占位到实例绑定、整条三个反向箭头和实时条件；同一640×360嵌入弹窗样本20→5隐藏箭头，文档revision=2不变，控制台无错误/警告。证据见 [.ai/docs/process-screens.md](.ai/docs/process-screens.md)。18139 已换本批 Go/Web，原三张画面字节不变，用户未保存页未刷新；f6cbc01基线CI38016543298/生命周期38016543300全绿，新提交CI独立核查。原生人工/DPI/race/现场仍未验。

更新：2026-10-10 编辑交互修复。`codex/process-canvas` 已修复右侧文字/数值草稿点击画布不提交：操作前同步提交、回写原元素 ID、去重提交。矩形/椭圆及文字/数据/设备支持左键拖出任意范围，绘制预览松开才提交；选中元素四边整段及四角均可缩放，另一侧固定、最小尺寸/画布边界保留、单步撤销。新增 19 项回归，Flutter 全量 115 项/analyze/59 文件只读格式、Go test/vet、Windows/Web release+verify-only passed，工作树源码摘要 `aa57175b…`。独立真实 Chrome 文字点击另一元素立即生效、拖出三种范围、四边非中点拖动逐次保存重读与撤销重做 passed，控制台无错误/警告；证据见 [.ai/docs/process-screens.md](.ai/docs/process-screens.md)。用户 18139 提供新 Web，未自动刷新其未保存页面；当前 Go 支持 process_screens，Windows 构建目录旧 Go 已替换。基线 a53ead27 的完整 CI 37910510085/生命周期 37910510073 passed，新提交远端验收另核；原生人工/DPI/现场仍未验。

更新：2026-10-09 参考图/嵌入组件批次。PR #14 的 `codex/process-canvas` 已加入明确「新建模板」（空白/三换热器供热站）、1280×660 可编辑蓝图（120 元素、33 个默认未绑定变量位置）和四个自绘设备 SVG。统一 ProcessScene 绘制、ProcessViewport 等比适配、只读 ProcessDiagram；总览可嵌入，开发页四种容器预览，缩放/拖动/正常字号变量表，宿主提供实时快照、不另开轮询。label/单位/小数保存及新接管点向后兼容。Go test/vet、Flutter analyze/全量 96 项、最终专项 6 项、Python 扩展 8 项/素材 2 项、Windows/Web release 与 verify-only passed，最终工作树源码摘要 e6f26720…。真实 Chrome 四尺寸、总览宽/窄/低高、预览打开时 65.43→77.78°C 更新、两站文档与 revision 查看后不变已验；证据和文件组织评价见 [.ai/docs/process-screens.md](.ai/docs/process-screens.md)。原 head 6c54216 的 CI37902463317 因 MCP 数量旧断言 32/实际40失败，已校准总数并检查新增八工具；新 head 远端检查以 PR 为准。未验原生窗口/DPI/现场设备；当前全站合计64画面/单图8MiB、图片嵌入副本、独立全局用户模板版本库尚未实现。

更新：2026-10-09。本轮接手已同步 main `b8d3b77`，对应 CI37034415067成功；在 `codex/process-canvas` 实施工艺画面。用户授权直接嵌入免费工艺素材，并追加独立「开发页」用于先拖摆示例、由 AI 完善模板。已加入 458 个固定提交 FUXA 静态 SVG、设备/直角管道、图片/文字/实时变量、位置/精度/显示单位、保存冲突与 JSON 模板导入导出；开发页编辑、工艺画面查看。素材来源与边界见 `.ai/docs/process-screens.md`、`app/assets/process/README.md`。已追加工作区共享「我的素材」：上传透明 PNG/JPEG，名称/分类、搜索/拖放，原字节保留，各站画面嵌入独立副本。免费实物来源筛选见 `.ai/docs/process-assets.md`。Go 全量 test/vet、Flutter 全量 88 + 新素材 2 项、analyze、素材完整性 2 项、本地 Windows/Web release 与 verify-only 已通过（最终源码摘要 d4aa5386…，交互批次 ea3e8312…）。实际 Chrome 文件选择上传、A 点击放置/B 拖入、保存字节/精度/单位独立已通过，证据见工艺画面说明；新 head CI 待远端结果，不沿用旧批次验收数字。

更新：2026-10-02。用户追加三平台实际安装包、广泛测试、截图，以及在 dot 电脑展示安装后的 Linux 应用和浏览器 Web。当前从 main `656011b` 开始实现；macOS 目标 Intel/Apple Silicon 通用，Windows/Linux x64。默认仅回环，未授权真实凭据、生产部署或签名证书。计划及边界见 `.ai/docs/installers.md`，实际证据待新 head CI，不沿用旧包结论。

更新：2026-10-02。登录/MCP后续主线push CI37014419461揭示旧虚拟点恢复缺陷：人工无效计算时间阻止延迟good源时间恢复，物理值52/动作66但虚拟保持null/bad。已最小修正为仅虚拟锁内重算跳过物理乱序过滤；物理帧防护和最早依赖源时间保留。最终5变体20轮race、独立10轮、120个Go顶层测试及未改动的真实MQTT/15000点smoke通过，详情 `.ai/docs/virtual-recovery-verification.md`；最终远端门禁以对应修复PR为准。此缺陷不是登录失败；先前e7aa产物仍是有独立通过证据的旧版，不能称包含本修复。

更新：2026-10-02。内网登录与现有业务 API 的 MCP 覆盖已实现并完成隔离验证。产品 head `32607c7`，PR #10；118个顶层Go/race测试（265含子测试）、76个Flutter测试、Linux/Web release构建通过，初始head完整CI37010627839六项和生命周期37010628064成功。原生CUA证实错误/正确登录、主动退出、60秒过期、重新登录和过期时私有弹窗清理；正常关闭exit0，桌面fixture已停止。独立安全复核的问题均已修复，详见 `.ai/docs/auth-mcp-verification.md`。

默认本机模式保留并限制回环Host；显式内网认证要求用户准备bcrypt账号与受信任TLS。cookie/短期bearer共享过期/撤销、CSRF与HTTP/MCP鉴权；32个工具覆盖所有现有业务REST，默认MCP只读。未部署真实内网或创建用户持久凭据；OAuth-only MCP客户端不在兼容承诺内。后续CUA入口只增加运行时fixture环境参数，不改生产行为；最终head检查与合并状态以PR #10为准。

上一轮用户指定五项基础能力已完成：读取/写入缩放偏移、定时存储、条件存储、条件触发的受限动作序列。PR #8 产品 head `22d41721057e4b49d3c193cc51f53a6e4bdc6e07` 已合入 main `62398358c09533d93d8d4d292620937e16b15493`；完整 CI 36994103672 六项 success，关闭专项 36994103735 success。

精确远端 head 本地 80 个 Go/race 测试（含真实本地 MQTT，无跳过）、55 个 Flutter 测试及 vet/analyze/格式通过。原生 CUA 核对读取20、负倍率写15/原值10、条件预览及执行、1000ms定时约10秒新增40行；只读SQLite证明48行、一个规则执行及停止配置。实际本地tar核验59项摘要、包内换算/存储/重启/同包Web接口通过。详细证据、来源树等价关系与下载见 `.ai/docs/focused-functional-tests.md` 和 `.ai/docs/v0.1.md`。

已修复逆算不可表达目标假成功、大偏移错误读回、INT不安全范围、非有限原值污染JSON、重复开始存储重置周期、保存未变规则重放、独立作用域错误被覆盖、缺失阈值默认零、无效预览和比较运算符校验。独立复核中发现的大整数小数误舍入及十进制过零拒绝也已回归修复。

原生存储页面需点击筛选才能刷新旧计数、ATK可访问性读取警告及历史浏览器首字符丢失观察仍明确记录；本轮浏览器门禁通过，不把之前 main 的失败称为全绿。脚本不是任意系统代码；历史无独立落库时间；重启规则禁用且不重放运行样本。真实设备、长期负载、Windows人工、多工程隔离及远程认证仍未验。未部署或发布Release。

产品母本 `agent.md`，唯一活跃看板 `AI_BOARD.md`。上一轮已闭环；登录/MCP本轮证据及部署边界已记录，剩余产品缺口在 AI_BOARD.md。
