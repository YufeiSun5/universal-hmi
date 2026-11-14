# 通用报表时间列时区转换 v90

2026-11-14 用户起初提到报警系统表可能为UTC，随后明确要求对时间列通用选择时区转换。本轮按最终澄清实现，不增加报警专用时间偏移，不修改SQL查询范围或确认人匹配。

## 使用与边界

开发态打开报表并查询结果，进入“报表样式 → 列设置”，选中时间列，点击“时间列时区转换”（窄窗为时钟图标）。默认不转换；启用后分别选择来源/显示UTC偏移，应用到列后保存样式。UTC原始值可选UTC+00:00→UTC+08:00。已有明确Z或数字时区的值优先使用自身时区，不重复加时差。

同一机制服务报警、标准历史、明细、统计、自定义过程等使用现有报表列设置的表格；以稳定字段key保存，独立列互不影响，运行端只消费配置。CSV沿用同一时间转换，数值仍保持原精度。关闭后恢复原显示；旧配置缺省关闭，重命名不清除已存转换。

支持年月日+时分/秒、可选小数秒及Z/数字时区；保留原小数秒精度、跨日/月/年，支持正负及非整小时固定UTC偏移。纯日期、只有时分、空值、无效日期及非时间内容不转换；固定UTC偏移不自动处理夏令时。此设置为显示格式，不改变筛选条件口径、数据源时间、SQL、确认人匹配或数据库原值。

## 实现与验证

- 后端externaldata.ReportColumn增加可选time_zone，验证来源/显示偏移完整且均在±840分钟内。沿用Screen.report_layouts公开契约、开发权限、版本冲突和持久化，没有新业务接口或依赖。
- Flutter共享ReportProjection统一表格/CSV转换；历史、明细、统计向格式化传递保留时区的原值。开发列设置和样式文件交换沿用既有模块。
- 后端回归覆盖报警/标准/明细/日报的保存、关闭、重命名保持、旧修订拒绝、查看用户禁止修改及无效时区拒绝；最终Go全test/vet通过。
- Flutter定向测试已通过转换、跨年/闰日、负偏移、显式时区优先、纳秒文本精度、空/错值保持、表格/CSV一致、源时间后缀保留、编辑/保存/重开/关闭及窄窗键盘布局。最终Flutter analyze无问题，768项测试通过/2项既有跳过；Windows/Web同源码构建及完整EXE组包校验通过。

现场/18153未操作。未修改既有工程配置；全部设置验证只在隔离工程或测试夹具进行。

## 最终包与交付

正式Chrome使用隔离loopback工程、正常测试账号登录，实际Screen配置API完成样式保存/重开/关闭；仅报警查询响应使用合成夹具，未连接现场SQL。转换前后日期、相邻未配置列、CSV及控制台结果见浏览器证据；截图仅含合成数据。包内后端/Web主文件与实际测试二进制/资源逐字一致。本轮浏览器和隔离后台已关闭。

独立完整EXE、说明、验收记录、截图与SHA256放在 `D:/Users/SunYufei/Downloads/时间列时区转换_v90_20261114`，无ZIP；源码de0b8206。不部署现场/18153，不执行安装器，不重跑完整安装生命周期矩阵或Windows原生WebView2交互。远端CI独立记录，未全部完成前保留草稿PR。

安装器SHA256：`9ff9e55c8f9cebb8a5927ed66fe2ff07521a628d168b6115caa5d10dcd7eb102`；大小285000212字节。

证据：[浏览器](evidence/20261114-report-timezone-v90/browser-result.json)、[发布结果](evidence/20261114-report-timezone-v90/release-result.json)、[Go测试](evidence/20261114-report-timezone-v90/go-test.log)、[Go vet](evidence/20261114-report-timezone-v90/go-vet.log)、[Flutter分析](evidence/20261114-report-timezone-v90/flutter-analyze.log)、[Flutter测试](evidence/20261114-report-timezone-v90/flutter-test.log)、[CI快照](evidence/20261114-report-timezone-v90/ci-summary.json)、[PR65](https://github.com/YufeiSun5/universal-hmi/pull/65)。
