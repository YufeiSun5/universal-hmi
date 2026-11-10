import 'dart:async';
import 'package:flutter/material.dart';
import '../shared/api.dart';
import 'security_layout.dart';

class OnlineConnectionsPanel extends StatefulWidget {
  const OnlineConnectionsPanel({super.key, required this.api});
  final PlatformApi api;
  @override
  State<OnlineConnectionsPanel> createState() => _OnlineConnectionsPanelState();
}

class _OnlineConnectionsPanelState extends State<OnlineConnectionsPanel> {
  Timer? timer;
  Json? snapshot;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (TickerMode.of(context)) load();
    });
  }

  Future<void> load() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final data = await widget.api.request('GET', '/api/v1/security/online');
      if (!mounted) return;
      setState(() {
        snapshot = data;
        error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        snapshot = null;
        error = e.toString();
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  String timeLabel(Object? value) {
    final date = DateTime.tryParse('$value')?.toLocal();
    if (date == null) return '—';
    String pad(int v) => '$v'.padLeft(2, '0');
    return '${date.year}-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}:${pad(date.second)}';
  }

  String channelLabel(Object? value) => switch (value) {
    'lan:http:engineering' || 'lan:http:web' => '内网 HTTP',
    'lan:engineering' => '内网 HTTPS',
    'public:web' => 'HTTPS 网页',
    'public:device' => '设备证书入口',
    '' || null => '本机入口',
    _ => '其他入口',
  };

  @override
  Widget build(BuildContext context) {
    final items = objects(snapshot?['items']);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 16,
            runSpacing: 8,
            children: [
              Text('当前在线', style: Theme.of(context).textTheme.titleLarge),
              OutlinedButton.icon(
                onPressed: busy ? null : load,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            snapshot == null
                ? '在线数：—'
                : '在线账号 ${snapshot!['users']} 人 · 在线连接 ${snapshot!['connections']} 个',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text('每 10 秒刷新；90 秒未通信移出名单。同一登录会话的多个标签页合并计数。'),
          const SizedBox(height: 12),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '无法获取在线状态：$error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: snapshot != null && items.isEmpty
                ? const Center(child: Text('当前没有在线连接'))
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final row = items[index];
                      return SecurityRecord(
                        leading: const Icon(Icons.person_outline),
                        title: Text('${row['username']}'),
                        subtitle: Text(
                          '${row['client']} · ${channelLabel(row['channel'])} · IP：${row['ip'] == '' ? '未知' : row['ip']}\n登录：${timeLabel(row['started'])}\n最近通信：${timeLabel(row['last_seen'])}',
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
