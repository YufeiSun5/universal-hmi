import 'package:flutter/material.dart';
import '../shared/api.dart';

/// Bounded view of server-generated request records, not a browsing history.
class PublicAccessEventsPanel extends StatefulWidget {
  const PublicAccessEventsPanel({super.key, required this.api});
  final PlatformApi api;
  @override
  State<PublicAccessEventsPanel> createState() =>
      _PublicAccessEventsPanelState();
}

class _PublicAccessEventsPanelState extends State<PublicAccessEventsPanel> {
  static const maximum = 500;
  List<Json> events = [];
  Json? status;
  int before = 0, generation = 0;
  bool busy = false, loaded = false, closing = false;
  String? error;

  @override
  void initState() {
    super.initState();
    load(reset: true);
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  Future<void> load({bool reset = false}) async {
    if (busy || (!reset && (before == 0 || events.length >= maximum))) return;
    final request = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'GET',
        '/api/v1/security/public-access/events',
        query: {'limit': 100, if (!reset) 'before': before},
      );
      if (!mounted || request != generation) return;
      final incoming = objects(result['items']);
      final next = result['next_before'];
      final health = result['status'];
      if (next is! int || next < 0 || health is! Map) {
        throw const FormatException('请求记录响应格式无效');
      }
      setState(() {
        final combined = reset ? <Json>[] : List<Json>.from(events);
        final seen = combined.map((e) => e['seq']).toSet();
        for (final event in incoming) {
          if (combined.length >= maximum) break;
          if (seen.add(event['seq'])) combined.add(event);
        }
        events = combined;
        before = next;
        status = Map<String, dynamic>.from(health);
        loaded = true;
      });
    } catch (_) {
      if (mounted && request == generation) {
        setState(() => error = '请求记录加载失败。已有记录仅为先前结果，不能据此判断记录完整或公网安全。');
      }
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  String decision(Object? value) =>
      const {
        'allowed': '允许',
        'public_ip_denied': 'IP 白名单拒绝',
        'public_read_only': '公网只读限制',
        'public_path_denied': '公网路径拒绝',
        'authentication_required': '需要认证',
        'authentication_failed': '登录认证失败',
        'forbidden': '权限拒绝',
        'request_failed': '请求失败',
        'stream_closed': '事件连接结束',
        'stream_access_revoked': '事件连接访问资格失效',
      }[value] ??
      '未识别结果';

  String kind(Object? value) =>
      const {
        'api_request': 'API 请求',
        'static_denied': '被拒资源请求',
        'stream_end': '事件连接结束',
      }[value] ??
      '请求记录';

  String shown(Object? value, String empty) =>
      value == null || value == '' ? empty : '$value';

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 940,
      height: 680,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '公网请求记录（仅本机）',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '关闭请求记录',
                  onPressed: () {
                    if (closing) return;
                    closing = true;
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                const Text('公网请求记录，不等于页面浏览证明，正常资源请求不记录。'),
                const Text(
                  '仅服务器生成的 API 请求、被拒静态请求和事件连接结束记录；异步队列与保留上限可能造成缺口，不是全量审计。',
                ),
                const Text(
                  '保留策略固定为 14 天 / 最多 100000 条；本页最多显示 500 条，不提供清空或修改保留策略。',
                ),
                const SizedBox(height: 8),
                Text(
                  status == null
                      ? '记录服务状态尚未确认'
                      : status!['enabled'] == true
                      ? '本地记录器已就绪（不保证记录完整）'
                      : '本地记录器未就绪或不可用',
                ),
                if (status != null && error != null)
                  const Text('以下服务状态来自上次成功响应，当前状态尚未确认。'),
                if (status != null) ...[
                  Text(
                    '排队 ${status!['queue_depth'] ?? '—'} · 已丢弃 ${status!['dropped'] ?? '—'} · 写入失败 ${status!['write_failures'] ?? '—'}',
                  ),
                  Text('最近写入：${shown(status!['last_write_at'], '暂无可用时间')}'),
                  if (status!['last_error'] != null &&
                      status!['last_error'] != '')
                    const Text('记录服务报告写入异常；可能存在未保存的请求。'),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: busy ? null : () => load(reset: true),
                      child: const Text('刷新记录'),
                    ),
                    Text('当前显示 ${events.length} 条'),
                  ],
                ),
                if (busy) const LinearProgressIndicator(),
                if (loaded && !busy && error == null && events.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text('当前查询没有记录；不代表没有访问或拒绝事件。'),
                  ),
                for (final event in events)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${event['at']} · ${kind(event['kind'])} · ${decision(event['decision'])} · HTTP ${event['status']}',
                        ),
                        SelectableText(
                          '来源 IP：${event['ip']} · 通道：${shown(event['channel'], '未解析')}',
                        ),
                        Text('当时人工归属标签：${shown(event['owner_label'], '未标注')}'),
                        Text(
                          '当时人工关联账号 ID：${shown(event['owner_user_id'], '未关联')}（不代表认证身份）',
                        ),
                        SelectableText(
                          '已认证账号 ID：${shown(event['user_id'], '未认证或未解析')}',
                        ),
                        Text(
                          '${shown(event['method'], '未知方法')} ${shown(event['route'], '未知路径模板')}',
                        ),
                        Text('当时匹配规则 ID：${shown(event['rule_id'], '无')}'),
                        const Divider(),
                      ],
                    ),
                  ),
                if (loaded && events.length >= maximum)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('已达本页 500 条上限；更早记录未展示。刷新可重新查看最新记录。'),
                  )
                else if (loaded && before != 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: OutlinedButton(
                      onPressed: busy ? null : () => load(),
                      child: const Text('加载更早'),
                    ),
                  )
                else if (loaded && events.isNotEmpty && error == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('当前查询范围已无更早记录；不表示记录完整。'),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
