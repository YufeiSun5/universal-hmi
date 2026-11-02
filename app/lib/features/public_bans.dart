import 'package:flutter/material.dart';
import '../shared/api.dart';

class PublicBansPanel extends StatefulWidget {
  const PublicBansPanel({super.key, required this.api});
  final PlatformApi api;
  @override
  State<PublicBansPanel> createState() => _PublicBansPanelState();
}

class _PublicBansPanelState extends State<PublicBansPanel> {
  List<Json> items = [];
  int revision = 0;
  bool busy = false, loaded = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  void accept(Json result) {
    items = objects(result['items']);
    revision = result['revision'] as int;
    loaded = true;
  }

  Future<void> load() async {
    if (busy) return;
    setState(() {
      busy = true;
      loaded = false;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'GET',
        '/api/v1/security/public-bans',
      );
      if (mounted) setState(() => accept(result));
    } catch (_) {
      if (mounted) setState(() => error = '读取封禁失败；已有显示不能代表当前状态。');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> unban(Json item) async {
    if (busy || !loaded) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('解除临时封禁？'),
        content: Text('请先核对请求记录，确认 ${item['ip']} 可以恢复访问。解封后仍须通过白名单或设备认证。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认解封'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'POST',
        '/api/v1/security/public-bans/unban',
        body: {'revision': revision, 'ip': item['ip']},
      );
      if (mounted) setState(() => accept(result));
    } catch (_) {
      if (mounted) {
        setState(() {
          loaded = false;
          error = '解封失败，请重新登录或刷新列表后核对。';
        });
      }
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Dialog(
      child: SizedBox(
        width: 760,
        height: 580,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '公网异常封禁（仅本机）',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: busy ? null : () => Navigator.pop(context),
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    '攻击规则命中、连续登录失败或持续超限会临时封禁来源 IP，15 分钟后自动到期。封禁跨重启保留；同一出口的其他手机可能同时受影响。本机管理员可核对请求记录后解封。',
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: busy ? null : load,
                      child: const Text('刷新封禁'),
                    ),
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (loaded && items.isEmpty) const Text('当前没有有效封禁。'),
                  for (final item in items)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${item['ip']} · ${const {'waf': '攻击规则命中', 'login_failures': '连续登录失败', 'request_rate': '请求持续超限'}[item['reason']] ?? '未知原因'}',
                            ),
                            Text(
                              '开始：${item['created_at']}\n到期：${item['expires_at']}',
                            ),
                            TextButton(
                              onPressed: busy || !loaded
                                  ? null
                                  : () => unban(item),
                              child: const Text('核对并解封'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
