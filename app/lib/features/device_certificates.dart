import 'package:flutter/material.dart';
import '../shared/api.dart';

/// Local administrators approve public leaves; private keys stay on the phone.
class DeviceCertificatesPanel extends StatefulWidget {
  const DeviceCertificatesPanel({super.key, required this.api});
  final PlatformApi api;
  @override
  State<DeviceCertificatesPanel> createState() =>
      _DeviceCertificatesPanelState();
}

class _DeviceCertificatesPanelState extends State<DeviceCertificatesPanel> {
  static const path = '/api/v1/security/device-certificates';
  final certificate = TextEditingController();
  final expiry = TextEditingController(
    text: DateTime.now()
        .toUtc()
        .add(const Duration(days: 30))
        .toIso8601String(),
  );
  List<Json> devices = [], approvals = [];
  String? selected, error;
  int revision = 0;
  bool busy = false, loaded = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    certificate.dispose();
    expiry.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      loaded = false;
    });
    try {
      final registrations = await widget.api.request(
        'GET',
        '/api/v1/security/devices',
      );
      final result = await widget.api.request('GET', path);
      if (!mounted) return;
      setState(() {
        devices = objects(registrations['items']);
        approvals = objects(result['items']);
        revision = result['revision'] as int;
        if (!devices.any(
          (d) => d['id'] == selected && d['state'] == 'approved',
        )) {
          selected = null;
        }
        loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => error = '读取失败，请刷新核对；已有显示不能代表当前授权。');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> mutate(String id, {required bool revoke}) async {
    if (busy || !loaded) return;
    final expires = DateTime.tryParse(expiry.text.trim());
    if (!revoke &&
        (certificate.text.trim().isEmpty ||
            expires == null ||
            !expires.isAfter(DateTime.now()))) {
      setState(() => error = '请粘贴手机导出的公开证书，并填写将来的有效期。');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(revoke ? '撤销此设备证书？' : '批准此设备证书？'),
        content: Text(
          revoke ? '该设备的现有连接和登录会话将失效。' : '请核对手机与登记的公钥指纹及归属账号。重新批准将使旧登录会话失效。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认'),
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
        '$path/$id/${revoke ? 'revoke' : 'approve'}',
        body: {
          'revision': revision,
          if (!revoke) 'leaf_pem': certificate.text.trim(),
          if (!revoke) 'expires_at': expires!.toUtc().toIso8601String(),
        },
      );
      if (mounted) {
        setState(() {
          revision = result['revision'] as int;
          approvals = objects(result['items']);
          if (!revoke) certificate.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loaded = false;
          error = e is PlatformRequestException && e.statusCode == 409
              ? '授权已改变，请保留输入并刷新后核对。'
              : '操作失败，请核对登记、证书、公钥和有效期，或重新登录后刷新。';
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
        width: 820,
        height: 680,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '手机证书授权（仅本机）',
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
                    '先登记手机导出的签名请求并审批归属账号，再批准同一公钥的公开证书。手机仍需账号、密码及双因素验证，只能查看已获授权的数据。',
                  ),
                  const Text('手机入口须在公网 HTTPS 配置中启用。此处不导入私钥，也不自动连接现场。'),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: busy ? null : load,
                      child: const Text('刷新授权'),
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(selected),
                    initialValue: selected,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '已审批设备'),
                    items: [
                      for (final d in devices.where(
                        (d) => d['state'] == 'approved',
                      ))
                        DropdownMenuItem(
                          value: '${d['id']}',
                          child: Text(
                            '${d['label']} · ${d['owner_user_id']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() => selected = value),
                  ),
                  TextField(
                    controller: certificate,
                    enabled: !busy,
                    minLines: 3,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      labelText: '手机导出的公开证书 PEM',
                    ),
                  ),
                  TextField(
                    controller: expiry,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: '授权有效期（ISO 8601，含时区）',
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed: busy || !loaded || selected == null
                          ? null
                          : () => mutate(selected!, revoke: false),
                      child: const Text('核对并批准证书'),
                    ),
                  ),
                  for (final item in approvals)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${devices.where((d) => d['id'] == item['registration_id']).map((d) => d['label']).firstOrNull ?? item['registration_id']} · ${item['revoked_at'] != null
                                  ? '已撤销'
                                  : DateTime.tryParse('${item['expires_at']}')?.isBefore(DateTime.now()) == true
                                  ? '已过期'
                                  : '已审批'}',
                            ),
                            Text('归属账号：${item['owner_user_id']}'),
                            Text('有效期：${item['expires_at']}'),
                            SelectableText('证书 SHA-256：${item['leaf_sha256']}'),
                            SelectableText('公钥 SHA-256：${item['spki_sha256']}'),
                            TextButton(
                              onPressed:
                                  busy || !loaded || item['revoked_at'] != null
                                  ? null
                                  : () => mutate(
                                      '${item['registration_id']}',
                                      revoke: true,
                                    ),
                              child: const Text('撤销证书授权'),
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
