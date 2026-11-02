import 'security_page.dart';
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
    final confirmed = await openSecurityPage<bool>(
      context: context,
      builder: (c) => SecurityForm(
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

  Future<void> ban() async {
    if (busy || !loaded) return;
    final ip = TextEditingController();
    var minutes = 1440;
    final input = await openSecurityPage<Json>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => SecurityForm(
          title: const Text('手动封禁来源 IP'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('立即阻止此 IP 的公网 Web 与手机访问。本机管理入口保留；同一出口的其他用户也会受影响。'),
                const SizedBox(height: 12),
                TextField(
                  controller: ip,
                  decoration: const InputDecoration(
                    labelText: '来源 IP（IPv4 / IPv6）',
                    hintText: '例如 203.0.113.10',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: minutes,
                  decoration: const InputDecoration(labelText: '封禁时长'),
                  items: const [
                    DropdownMenuItem(value: 15, child: Text('15 分钟')),
                    DropdownMenuItem(value: 60, child: Text('1 小时')),
                    DropdownMenuItem(value: 1440, child: Text('24 小时')),
                    DropdownMenuItem(value: 10080, child: Text('7 天')),
                    DropdownMenuItem(value: 43200, child: Text('30 天')),
                    DropdownMenuItem(value: 525600, child: Text('1 年')),
                  ],
                  onChanged: (value) {
                    if (value != null) update(() => minutes = value);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, <String, dynamic>{
                'ip': ip.text.trim(),
                'minutes': minutes,
              }),
              child: const Text('确认封禁'),
            ),
          ],
        ),
      ),
    );
    // Wait until the dialog's exit animation retires its text field.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    ip.dispose();
    if (!mounted || input == null || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'POST',
        '/api/v1/security/public-bans/ban',
        body: {'revision': revision, ...input},
      );
      if (mounted) setState(() => accept(result));
    } catch (_) {
      if (mounted) {
        setState(() {
          loaded = false;
          error = '封禁未能确认，请核对 IP、重新登录或刷新后再试。';
        });
      }
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: SecuritySurface(
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
                  if (!SecurityPageScope.isRoot(context))
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
                    '攻击规则命中、连续登录失败或持续超限会自动封禁 15 分钟。手动封禁按所选时长生效，跨重启保留；同一出口的其他用户可能同时受影响。解封后仍须通过白名单或设备认证。',
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: busy ? null : load,
                        child: const Text('刷新封禁'),
                      ),
                      FilledButton.icon(
                        onPressed: busy || !loaded ? null : ban,
                        icon: const Icon(Icons.block, size: 17),
                        label: const Text('手动封禁 IP'),
                      ),
                    ],
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
                              '${item['ip']} · ${const {'waf': '攻击规则命中', 'login_failures': '连续登录失败', 'request_rate': '请求持续超限', 'manual': '管理员手动封禁'}[item['reason']] ?? '未知原因'}',
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
