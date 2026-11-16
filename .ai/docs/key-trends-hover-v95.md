# 重点曲线浮窗与范围柱 v95

本轮仅修改`tools/key_trends/core.mjs`及其生成的前端静态资源。热量图悬浮只列出热量，温压图悬浮只列出温度/压力；使用ECharts原生分区轴提示，移除跨图axisPointer关联，两个时间轴的缩放和拖选仍联动。

浮窗数值和纵轴刻度统一两位小数，使用原生Intl.NumberFormat显示格式化；原始十进制字符串、查询接口和后端统计不变。缺值仍为破折号、零为0.00，不把显示舍入回写到数据。

高低细线改为实际最低～最高值的填充矩形。宽度与分组位置由ECharts的barLayout根据当前可见时段和可见序列分配，最大32px，缩放放大后自动变宽；隐藏序列释放占用宽度。供水填充较实，回水较淡并有虚线边框。最低值等于最高值时保留1.5px水平矩形，无虚构OHLC或从零开始的假柱高。

验证：Node8项通过；Playwright使用生产前端资源及隔离合成小时报数据，通过热量/温压分图、来回悬浮切换、两位小数、温压同时显示、填充范围柱、缩放增宽、隐藏序列重分配宽度和480px布局9项检查。双站默认柱宽4.74px，缩放后11.38px，只保留一条范围序列时32px。截图已目视检查。

本轮未修改Go/Flutter业务代码或依赖，不重复将v94的全量回归当作本轮执行。Windows/Web构建、完整安装包及后端/Web/离线图表同源字节核对通过。产品源码09498d52，安装包SHA256：`36774cc1fe9689e795b8e3143c483fb9bf163e715dc81e2e595c7b71c6d6c814`。未部署现场、未修改18153。

[交付摘要](evidence/20261116-key-trends-v95/release-result.json)、[核心回归](evidence/20261116-key-trends-v95/node-test.log)、[浏览器交互](evidence/20261116-key-trends-v95/browser-flow.log)、[构建](evidence/20261116-key-trends-v95/build.log)。

截图：[热量浮窗](evidence/20261116-key-trends-v95/heat.png)、[温压浮窗](evidence/20261116-key-trends-v95/ranges.png)、[缩放增宽](evidence/20261116-key-trends-v95/zoom.png)、[窄窗](evidence/20261116-key-trends-v95/mobile.png)。均使用隔离合成数据。

草稿[PR70](https://github.com/YufeiSun5/universal-hmi/pull/70)依赖v94，未合并，远端CI以[同步记录](evidence/20261116-key-trends-v95/remote-status.json)单列。
