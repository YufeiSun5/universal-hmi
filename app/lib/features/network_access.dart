import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../shared/api.dart';
import '../platform/save.dart';
import 'security_page.dart';

class NetworkAccessPage extends StatefulWidget {
  const NetworkAccessPage({super.key, required this.api});
  final PlatformApi api;
  @override
  State<NetworkAccessPage> createState() => _NetworkAccessPageState();
}

class _NetworkAccessPageState extends State<NetworkAccessPage> {
  final address = TextEditingController(), port = TextEditingController();
  Json? snapshot;
  bool enabled = false, busy = false, dirty = false;
  String? error, message;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    address.dispose();
    port.dispose();
    super.dispose();
  }

  void accept(Json data) {
    snapshot = data;
    address.text = '${data['address'] ?? ''}';
    port.text = '${data['port'] ?? 18443}';
    enabled = data['enabled'] == true;
    dirty = false;
  }

  Future<void> load() async {
    if (busy) return;
    if (dirty) {
      final discard = await openSecurityPage<bool>(
        context: context,
        builder: (context) => SecurityForm(
          title: const Text('重新读取网络入口？'),
          content: const Text('这会放弃本页尚未保存的地址和端口修改。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃并重新读取'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final data = await widget.api.request(
        'GET',
        '/api/v1/security/network-access',
      );
      if (mounted) setState(() => accept(data));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> save() async {
    if (busy || snapshot == null) return;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      final data = await widget.api.request(
        'PUT',
        '/api/v1/security/network-access',
        body: {
          'revision': snapshot!['revision'],
          'enabled': enabled,
          'address': address.text.trim(),
          'port': int.tryParse(port.text.trim()) ?? 0,
        },
      );
      if (mounted) {
        setState(() {
          accept(data);
          message = '配置已保存。需要重启项目后台后生效；仅关闭界面不会重启后台。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xfff8fafc),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '网络访问入口',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (message != null || error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              error ?? message!,
              style: error == null
                  ? null
                  : TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              const Text(
                '内网 Web 与公网 Web 均为只读入口，使用网络账号、密码和图形验证码。客户端 IP 必须在 Web 白名单中获准；此处不会自动开放整个内网。',
              ),
              const SizedBox(height: 18),
              const Text(
                '公网入口',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              SelectableText('${snapshot?['public_origin'] ?? '尚未配置'}'),
              Text(
                snapshot?['public_enabled'] == true
                    ? '已配置启用 · 本页不更换公网地址和手机信任证书'
                    : '未配置启用',
              ),
              const Divider(height: 32),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用内网 Web'),
                subtitle: const Text('仅绑定所选内网 IP，开发与管理接口仍只在本机开放'),
                value: enabled,
                onChanged: busy || snapshot == null
                    ? null
                    : (value) => setState(() {
                        enabled = value;
                        dirty = true;
                      }),
              ),
              if (objects(snapshot?['addresses']).isNotEmpty) ...[
                const Text('本机检测到的内网地址'),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final item in objects(snapshot?['addresses']))
                      ActionChip(
                        label: Text('${item['interface']} · ${item['ip']}'),
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                address.text = '${item['ip']}';
                                dirty = true;
                              }),
                      ),
                  ],
                ),
              ] else if (!busy)
                const Text('没有检测到可用的内网 IPv4；可填写计划地址，启用前需在服务器网卡上配置该地址。'),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    SizedBox(
                      width: 260,
                      child: TextField(
                        controller: address,
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: '内网 IPv4 地址',
                        ),
                        onChanged: (_) => setState(() => dirty = true),
                      ),
                    ),
                    SizedBox(
                      width: 140,
                      child: TextField(
                        controller: port,
                        enabled: !busy,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'HTTPS 端口',
                        ),
                        onChanged: (_) => setState(() => dirty = true),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SelectableText('访问地址：https://${address.text}:${port.text}'),
              Text(
                snapshot?['running'] == true
                    ? '当前监听：${snapshot!['running_origin']}'
                    : '当前内网入口未运行',
              ),
              if (snapshot?['restart_required'] == true)
                const Text('已保存配置与当前运行状态不同，等待重启项目后台'),
              if (snapshot?['status_error'] != null)
                Text('${snapshot!['status_error']}'),
              const SizedBox(height: 16),
              const Text(
                '首次启用会生成匹配所选 IP 的十年期内网证书，与公网/手机证书分开。内网浏览器需信任导出的公开证书；地址改变后须重新导出并信任新证书。',
              ),
              if (snapshot?['fingerprint'] != null) ...[
                const SizedBox(height: 8),
                SelectableText('证书 SHA256：${snapshot!['fingerprint']}'),
                Text('到期时间：${snapshot!['expires']}'),
              ],
              if (dirty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('未保存修改'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: busy ? null : load,
                child: const Text('重新读取本机地址'),
              ),
              OutlinedButton(
                onPressed: snapshot?['origin'] == null
                    ? null
                    : () => Clipboard.setData(
                        ClipboardData(text: '${snapshot!['origin']}'),
                      ),
                child: const Text('复制已保存地址'),
              ),
              OutlinedButton(
                onPressed: snapshot?['certificate_pem'] == null
                    ? null
                    : () async {
                        try {
                          await saveFile(
                            Uint8List.fromList(
                              utf8.encode('${snapshot!['certificate_pem']}'),
                            ),
                            'Universal-HMI-LAN-cert.pem',
                          );
                        } catch (e) {
                          if (mounted) setState(() => error = '$e');
                        }
                      },
                child: const Text('导出内网公开证书'),
              ),
              FilledButton(
                onPressed: busy || snapshot == null || !dirty ? null : save,
                child: const Text('保存入口配置'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
