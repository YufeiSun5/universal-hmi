# 第一版接入合同

唯一架构母本：[architecture.md](architecture.md)。以下格式来自本版 adapter 与自动测试，不是任意厂商版本的兼容保证。

## 来源与站点映射

来源定义包含 id、name、broker、topic、protocol；protocol 为 generic / kep / kingio。broker 使用 tcp:// 或 ssl://，首版不提供用户名密码及自定义证书配置，也不把凭据放在 URI。连接必须显式启动；断开后手工重连，重启不自动连接。

点位定义通过 source_id + topic + source_path 找到对应源事实，再由 station 组织显示。不按 MQTT 数组下标定位设备。一个订阅携带 10 站数据可以映射成 10 个逻辑站；第一版是一个本地工程，独立多工程尚未实现。来源身份、点位稳定 ID、显示名称和写目标分别保存。

## MQTT 读取示例

generic：
~~~json
{"points":[{"path":"IO-01.temperature","value":21,"quality":"good","timestamp":"2026-10-01T00:00:00Z"},{"path":"IO-02.temperature","value":22,"quality":"good","timestamp":"2026-10-01T00:00:00Z"}]}
~~~

kep（Kepware values 格式，t 为 Unix 毫秒）：
~~~json
{"values":[{"id":"Channel.IO01.temperature","v":21,"q":true,"t":1790812800000},{"id":"Channel.IO02.temperature","v":22,"q":true,"t":1790812800000}]}
~~~

kingio（Objs 格式，2 接受 Unix 秒或毫秒，3=192 才为 good）：
~~~json
{"Objs":[{"N":"IO01.temperature","1":21,"2":1790812800000,"3":192}]}
~~~

generic 仅 quality=good 判为有效；kep 仅明确 q=true 判为有效。缺失质量不得默认正常，缺失或非法时间拒绝该消息。坏质量、缺失、陈旧及公式失败不触发事件。每条消息最多 1 MiB / 10000 样本，运行队列最多 128 批，满载计数可见。

## 换算与下设

工程值 = 原值 × scale_factor + offset。下设重新校验点位可写属性、数值类型、工程值范围和当前运行配置版本，并逆算原值；虚拟点不能据公式自动逆写。

示例：scale_factor=2、offset=10 时，读取原值 21 得到工程值 52；下设工程值 70 对应原值 30。

HTTP 下设入口 POST /api/v1/write：
~~~json
{"command_id":"unique-command-id","point_id":"stable-point-id","value":70,"version":"current-runtime-version"}
~~~

generic 发布到点位 write_topic：
~~~json
{"command_id":"unique-command-id","path":"IO-01.setpoint","value":30}
~~~

命令 ID 重复且请求一致返回原结果，不重复发布；同 ID 不同请求拒绝。写入意图先持久化，进程中断/超时的未知结果不自动重放。QoS 1 的 PUBACK 只对应 sent，不等于设备 ACK，也不会把 UI 实时值伪造为目标值。手工/模拟点的本地更新可标 readback_confirmed；物理 Kepware/KingIO 写在 codec 未配置时拒绝。

未来接入真实厂商需要明确写主题、载荷、数据类型、ACK/错误载荷、关联 ID、读回路径与超时语义，并保留设备测试证据。

## 虚拟点和事件

虚拟点通过稳定输入 ID 和 v[0]、v[1] 等索引表达受限算术/比较/条件公式。激活检查依赖环、表达式长度、输入数及节点上限；不开放进程、文件系统或数据库。

事件支持 AND/OR、多条件、持续满足时间、冷却、rising/periodic/recovery，动作按序调用同一写入/快照/存储服务。规则预览不产生副作用，执行保存每步结果；跨设备和数据库没有原子事务。未知输入不触发，重启规则默认禁用。
