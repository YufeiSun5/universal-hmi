# 验证与发布条件

母本：[架构](architecture.md)、[桌面体验](desktop-experience.md)。当前阶段结果见 [v0.1.md](v0.1.md) 与 [HANDOFF.md](../../HANDOFF.md)。本页更新：2026-10-02；以下区分最终源码验证、候选包、远程 CI 与历史结果。

## 当前证据范围（2026-10-02）

工程从公开基底 `7cafe7c5a6597c72d71fdf9694370c2fc5db6333` 重新实施。最新已验证产品 head 为 `cb98d1b385984d1084fe0f86c567901cc7436d62`，已合入产品提交 `d7f267ad0a93ac267f404114926f63e0dfde5966`。不宣称未保留源码逐字恢复，也不沿用旧版本测试数字。

| 验证 | 已通过证据 | 范围 |
| --- | --- | --- |
| PR #5 完整 CI / 关闭专项 | [36975590393](https://github.com/YufeiSun5/universal-hmi/actions/runs/36975590393)、[36975590463](https://github.com/YufeiSun5/universal-hmi/actions/runs/36975590463)，head `b923243`，均成功且已合并 | 该批次独立记录 |
| PR #6 完整 CI / 关闭专项 | [36975726752](https://github.com/YufeiSun5/universal-hmi/actions/runs/36975726752)、[36975726754](https://github.com/YufeiSun5/universal-hmi/actions/runs/36975726754)，head `cb98d1b`，均成功且已合并 | 54个Flutter测试与analyze通过；Go Linux/Windows、Flutter Linux/Web/Windows、组包共6项完整CI成功；两次专项分别自有1次+快速复用10次，全exit0 |
| 精确帧/退出顺序 | 最终帧提交→视图分离→同一帧光栅完成→engine dispose→shutdown完成的顺序匹配，专项关闭约1.07秒 | 不用超时、等待固定时长或强制kill冒充成功 |
| 最新同源 profile | [来源](evidence/20261002-ci/github-provenance.json)、[报告](evidence/20261002-ci/performance-verification.json)：120.030秒、22项UI检查与9项容量检查通过 | CI合并测试提交`179d988`的tree与head `cb98d1b`完全一致；123项已跟踪源文件+2份锁定字体逐字匹配 |
| 采集处理 | 5个真实本地Mosquitto、30×500变量；3,150,003样本/1,053批accepted=processed，0drop；历史目录15,000身份 | 含预检/稳态/恢复累计；1次解码错误为预期注入；**不是每个采集样本都已历史持久化** |
| 矩阵/质量 | CI全局15,000点起始/末尾仅挂载49/48格；原生单站1180×812实际截图63完整格、真实bad/stale/恢复见[桌面体验](desktop-experience.md) | CI和本地视口环境分别计数，不混合“挂载/完整/可点击” |
| Web与产物 | 完整CI含真实键盘筛选、CSV/XLSX文件流和最终组包；官方Linux/Windows artifact已可下载，见[阶段记录](v0.1.md) | Windows编译通过不等于Windows真机人工验收 |
| 最终本地tar | `9249aa11af7a2605437ce7d1e8208d0944460676f1cd6221ecd94a2aa00e4b01` 实际解包后，原生文件选择/保存、owned/reused退出及同包Web文件流全部通过 | [实包](evidence/20261002-ci/final-package-smoke.json)、[原生文件](evidence/20261002-ci/final-native-file-flow.json)、[同包Web](evidence/20261002-ci/final-browser-flow.json)；不套用为CI下载artifact内tar的独立校验 |

[发布检查点](evidence/20261002-ci/release-checkpoint.json)记录各head、run和下载对应关系。真实设备/厂商现场、Windows真机人工/DPI/多屏/原生文件交互、用户可操作的cloud-browser预览、长期现场负载及生产认证部署仍未验收。

最终本地tar来源为`cb98d1b` / `9f573dc2db8a97e4e6b2fdb3f046cb74e9dfa258908f7669e7c1bb5f22dd1471`。原生导出XLSX仅有40/60两行、ZIP CRC与XML校验通过，SHA-256为`68c89d774f86102bb3d422ed6e818c4f4d4face8f2e04da4f9671fcf639a2b45`。人工日志`close_wait_ms`含等待操作者操作，不能当成退出耗时；自动专项的约1.07秒另计。官方CI产物通过与本地tar独立解包验证是两项证据，不能把本地摘要套到CI下载包。

### 当前CI与历史本地测量分列

| 指标 | 当前CI：cb98同树179d988 | 历史本地：952dbfd |
| --- | --- | --- |
| 机器 | EPYC7763，4个可用vCPU | EPYC9V74，9个可用vCPU |
| 稳态 / UI检查 | 120.030秒 / 22项 | 120.174秒 / 22项 |
| 累计样本 / 批 / drop | 3,150,003 / 1,053 / 0 | 2,880,003 / 963 / 0 |
| 停流 / 恢复 | 10.342秒 / 1.779秒 | 10.357秒 / 1.449秒 |
| 稳态源年龄均值 / 最大 | 0.952 / 1.669秒 | 0.973 / 1.672秒 |
| 帧数 / build、raster、total P99 | 1,004 / 45.186、30.777、60.722ms | 1,032 / 39.805、17.056、56.803ms |
| 超过16.7ms帧数 | 340 | 162 |
| Flutter RSS峰 / CPU P95 | 533.867MiB / 209.76%（约2.098核） | 450.773MiB / 194.20%（约1.942核） |
| 后端 RSS峰 / CPU P95 | 125.941MiB / 29.61%（约0.296核） | 116.098MiB / 21.81%（约0.218核） |
| 全局矩阵挂载格：起始/末尾 | 49 / 48 | 56 / 55 |

来源/主机不同，不能混合这两列或据此断言优化、回退。两次均为1280×720、DPR1的profile，CPU每500ms采样、100%=一核；通过不表示稳定60FPS。操作延迟包括动作完成与pumpAndSettle，不是纯输入分发延迟。当前CI完整帧/采样/操作分位数见[测量报告](evidence/20261002-ci/performance-verification.json)；本检查点保存同一摘要中的历史环境对照，原始逐样本记录不随文档重复发布。

CI的运行前后来源摘要为`8157611c8598003a8f9bccd2ee519d4830be9582e5cc91787a9e75884ce4e961`；完整来源清单125项已核对。GitHub测试提交`179d9884126bf145c55ca1ce4be6db76c985c925`的tree为`f6b62beaff8657f1142a72ce718f7316e56ae7b6`，与产品head同树，不能仅因提交SHA不同误判产品源码不同。

## 固定工具链与只读源码门禁

当前工作流见 [verify.yml](../../.github/workflows/verify.yml)：Go 1.24.7、Flutter 3.35.4 / Dart 3.9.2；使用既有 runner 和锁文件。常规验证不再执行 `go mod tidy`、写入式 `gofmt`、`dart fix`、写入式 `dart format` 或 `flutter create`。以下是当前门禁命令，不是对尚未完成的新批次声明通过。

在仓库根目录，将上述官方固定工具链加入 PATH。记录 `go version`、`flutter --version --machine` 和 `git rev-parse HEAD` 后执行：

~~~sh
mkdir -p dist
(
  cd backend
  test -z "$(gofmt -l ./cmd ./internal)"
  go mod verify
  go test -mod=readonly -race ./...
  go vet -mod=readonly ./...
  go build -mod=readonly -o ../dist/universal-hmi-server ./cmd/server
)
python ci/test_release_gates.py
python -m unittest discover -s ci -p test_package_process.py
python -m pip install -r ci/requirements-fonts.txt
python ci/prepare_fonts.py
python ci/prepare_fonts.py --check
python -m unittest discover -s ci -p test_prepare_fonts.py
(
  cd app
  flutter pub get --enforce-lockfile
  dart format --output=none --set-exit-if-changed lib test integration_test test_driver
  flutter analyze --no-pub
  flutter test --no-pub test
)
~~~

字体是锁定官方来源、输入/输出 SHA-256 和工具版本的可重建依赖；`prepare_fonts.py` 只准备规定的字体资源，不能悄悄修改产品源代码。离线使用已校验的内置资源；不要以未确认的大文件上传代替可复现配方。

CI 对干净 checkout 执行 `git diff --exit-code`；本地已有授权未提交修改时，应记录前后完整源码清单/摘要并确认没有测试引入的变化，不能通过临时修源码、放宽断言或删除既有改动让门禁变绿。当前产品head的上述CI已有成功证据；后续修改仍需对应新head门禁，不能仅看工作流配置或旧绿灯。

Linux 依赖包括 clang、cmake、ninja-build、pkg-config、GTK 3 开发/运行库、EGL/GL、liblzma、可用字体、Mosquitto 与客户端；隔离 CI 图形测试使用 Xvfb，包自动关闭/截图使用 xdotool/ImageMagick。Windows 构建须在 Windows + Visual Studio C++ 工具链独立执行。

## 可复现流程及顺序

下面从仓库根目录执行。每次用新输出目录，不覆盖上面的已通过或失败证据。测试只用隔离临时数据和回环服务；18080、18081、18884、18890–18894、18980 等 fixture 端口已占用时应停止并报告，不能替换现有后端或碰现场数据。

### 1. 后端协议及容量

~~~sh
python ci/run_backend_smoke.py --output dist/backend-new-run
~~~

脚本先验证 generic MQTT 的换算/去重，再验证独立 5 broker、30 站×500 点 KIO 解析、质量与时戳、来源/topic/path 隔离、历史目录和精确队列计数。该项不包含前端持续性能，不能单独当作整体容量验收。ACK、超时/重复/乱序和物理读回状态须同时以当前后端回归用例及实际日志核对，不能把 broker sent 或合成 ACK 写成现场设备执行成功。

### 2. 原生流程及持续 profile

~~~sh
# 仅用于允许启动隔离 Xvfb 的 CI/测试环境
python ci/run_linux_ui.py --xvfb --flow --duration 120 --output dist/profile-new-run
~~~

已有授权桌面时改用 `--display "$DISPLAY"`，不创建/替换显示服务；两个选项互斥。`--preflight` 仅代表两轮预检，不能宣称 120 秒稳态通过。完整门禁检查真实可见值/源时间变化、实际趋势样本、15,000/500 行滚动和筛选、站点状态恢复、多轮操作、独立至少 10 秒停流/陈旧/恢复、收发精确计数、帧 P99、CPU/RSS；保存 `command.json`、`run-metadata.json`、`native-profile.json`、`cpu-rss.json` 与 capacity 子目录。最新总览/监视结构的交互断言须随产品行为更新，不能绕开新视图只复跑旧路径。

### 3. 串行 release、组包与正常关闭

profile/debug 测试必须先结束，再串行运行 release；各模式共享 Flutter Linux ephemeral 构建目录，禁止并发混用 engine/AOT。

~~~sh
python ci/build_release.py linux
python ci/build_release.py web
python ci/package_desktop.py linux
# 从本次已校验 build 更新 staging，再验证当前来源及产物
python ci/package_final.py --targets linux --stage-local
# 验收从最终 tar 解出的实际交付内容，不能只启动 staging
# 使用新目录，保留已有解包/诊断证据
test ! -e dist/tar-new-run
mkdir -p dist/tar-new-run
tar -xzf dist/final/universal-hmi-linux-x64.tar.gz -C dist/tar-new-run
python ci/package_smoke.py --bundle dist/tar-new-run/universal-hmi --xvfb --reuse-close-attempts 10 --output dist/package-new-run
~~~

曾出现新 build 未复制到 staging、最终误装旧 UI 的问题，现有 `--stage-local` 与当前来源校验拒绝旧 staging。仍须核对 build→staging→tar 解包后的文件/产物摘要及实际界面；对应失败和修复验收见[历史记录](v0.1.md)。不能只比较两个旧 staging 彼此一致。

已有桌面并由操作者正常关闭窗口时，最后一步使用 `--display "$DISPLAY" --review-close`，该模式仅进行一次 reused 关闭，必须与自动十次快速关闭分开记录。检验 release engine 等于官方 `linux-x64-release`、AOT 为 ELF、源码与产物摘要对应，以及 desktop/Web 来源摘要一致；最终 tar 的摘要保存在 `dist/final/SHA256SUMS`。检查自有 sidecar 随正常关闭退出、复用 sidecar 不被关闭，所有退出为 0，日志严格证明 engine dispose 在 shutdown 之前，并重验独立历史与同源 Web。自动门禁还做十次刚出现窗口后的快速 reused 关闭；人工等待后关闭一次不能代替该竞态覆盖。强制 kill 不能冒充正常窗口关闭。

Windows 在自己的 runner 上生成 Go `.exe`，执行 `python ci/build_release.py windows`、`python ci/package_desktop.py windows`，最终工作流汇合已验证的 Web/desktop 产物。Linux 成功不替代 Windows 构建或真机窗口、DPI、文件对话框验收。

### 4. 隔离 Web 文件回归

普通 CI 安装 Playwright 1.55.0 及匹配 Chromium；本地建议使用独立 venv，并确认浏览器能够发现有效系统字体。执行：

~~~sh
python ci/browser_flow.py --server dist/tar-new-run/universal-hmi/universal-hmi-server --web dist/tar-new-run/universal-hmi/web --output dist/browser-new-run
~~~

先验证独立 HTML 输入事件，再完成真实文件选择→CSV 映射预览→导入→以实际键盘事件输入 30/70→数值筛选→XLSX 下载并重读 40/60、排除 20；保存实际请求证据确认筛选参数未被异步刷新覆盖。字体/输入探针失败应记为 blocked 并使门禁失败，不能直接注入业务状态替代交互或放松文件断言。这是隔离工程回归，与用户可见的 cloud-browser 交互预览分开记录；后者本轮仍未验。

## 最终验收矩阵与证据纪律

| 层次 | 最终新批次必须核查 |
| --- | --- |
| Go / 数据归属 | 原子配置及 Demo 完整目录发布、保存/应用版本分离、站点策略/规则/快照隔离、受控写入类型/范围/逆算/去重、KIO ACK 与读回分离、坏质量/陈旧/乱序和虚拟循环 |
| 历史 / 文件 | 无检测前置、冻结历史单位/换算/版本、导入幂等及错误行阻断、安全文本、完整筛选统计与当前页统计区别、冻结分页/导出边界、取消/失败可见 |
| widget / 静态检查 | 矩阵阶段本地49测试/analyze记录保留；最新cb98完整CI的格式/analyze/54个Flutter测试均通过，后续变化按新head复验 |
| Linux native / profile | cb98同源CI为22项/120.030秒；952本地22项/120.174秒单列历史；原生63完整格/质量/陈旧截图已核验 |
| 发布包 / Web | 官方完整CI、两次自有+10复用快速关闭专项及本地9249aa最终tar的原生/同包Web文件流全部通过；未独立下载校验CI artifact内tar |
| 仍未验 | 真实设备/客户厂商环境、长期现场负载、Windows 真机人工交互/DPI/生命周期、用户可见 cloud-browser 交互预览、远程认证与生产部署 |

每轮独立记录 passed / failed / unexecuted / blocked、Git 基点、工作树源码摘要、工具链/机器、命令、时间窗口、实际操作及产物。新结果追加为新批次，不覆盖历史成功或失败，不把来源不同的 profile/release/截图拼成同一版完成证据。真实设备、生产数据或权限范围变化另需明确授权；本轮未连接生产设备。
