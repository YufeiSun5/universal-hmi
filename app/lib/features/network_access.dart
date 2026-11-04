import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../shared/api.dart';
import '../platform/save.dart';
import 'security_page.dart';
import 'security_layout.dart';

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
  Widget build(BuildContext context) => SecurityTheme(
    child: Material(
      color: const Color(0xfff8fafc),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Text(
              '网络访问入口',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (message != null || error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Text(
                error ?? message!,
                style: TextStyle(
                  color: error == null
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '内网和公网 Web 均只能查看数据。使用网络账号、密码和图形验证码登录，客户端 IP 需加入 Web 白名单。',
                      ),
                      const SizedBox(height: 24),
                      SecuritySection(
                        title: '内网 Web',
                        description: '从本机网卡中选择地址，也可以手动修改。保存后重启项目后台生效。',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('启用内网访问'),
                              subtitle: const Text('开发与管理接口仍仅允许本机访问'),
                              value: enabled,
                              onChanged: busy || snapshot == null
                                  ? null
                                  : (value) => setState(() {
                                      enabled = value;
                                      dirty = true;
                                    }),
                            ),
                            const SizedBox(height: 20),
                            if (objects(snapshot?['addresses']).isNotEmpty) ...[
                              const Text('本机检测到的内网地址'),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  for (final item in objects(
                                    snapshot?['addresses'],
                                  ))
                                    ActionChip(
                                      label: Text(
                                        '${item['interface']} · ${item['ip']}',
                                      ),
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
                              const Text(
                                '尚未检测到内网 IPv4。可以保存计划地址，启用前需在服务器网卡上配置此地址。',
                              ),
                            const SizedBox(height: 24),
                            Wrap(
                              spacing: 20,
                              runSpacing: 20,
                              children: [
                                SizedBox(
                                  width: 280,
                                  child: TextField(
                                    controller: address,
                                    enabled: !busy,
                                    decoration: const InputDecoration(
                                      labelText: '内网 IPv4 地址',
                                    ),
                                    onChanged: (_) =>
                                        setState(() => dirty = true),
                                  ),
                                ),
                                SizedBox(
                                  width: 160,
                                  child: TextField(
                                    controller: port,
                                    enabled: !busy,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'HTTPS 端口',
                                    ),
                                    onChanged: (_) =>
                                        setState(() => dirty = true),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            SelectableText(
                              '访问地址：https://${address.text}:${port.text}',
                            ),
                            const SizedBox(height: 10),
                            Text(
                              snapshot?['running'] == true
                                  ? '当前监听：${snapshot!['running_origin']}'
                                  : '当前内网入口未运行',
                            ),
                            if (snapshot?['restart_required'] == true)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text('已保存，等待重启项目后台'),
                              ),
                            if (snapshot?['status_error'] != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text('${snapshot!['status_error']}'),
                              ),
                            if (dirty)
                              const Padding(
                                padding: EdgeInsets.only(top: 12),
                                child: Text('有未保存修改'),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      SecuritySection(
                        title: '内网证书',
                        description:
                            '首次启用生成独立的十年期证书。内网浏览器需信任公开证书；更换 IP 后需要重新导出并配置。',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (snapshot?['fingerprint'] != null) ...[
                              const Text('SHA256 指纹'),
                              const SizedBox(height: 8),
                              SelectableText('${snapshot!['fingerprint']}'),
                              const SizedBox(height: 12),
                              Text('到期时间：${snapshot!['expires']}'),
                              const SizedBox(height: 20),
                            ] else ...[
                              const Text('尚未生成内网证书'),
                              const SizedBox(height: 16),
                            ],
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton(
                                onPressed: snapshot?['certificate_pem'] == null
                                    ? null
                                    : () async {
                                        try {
                                          await saveFile(
                                            Uint8List.fromList(
                                              utf8.encode(
                                                '${snapshot!['certificate_pem']}',
                                              ),
                                            ),
                                            'Universal-HMI-LAN-cert.pem',
                                          );
                                        } catch (e) {
                                          if (mounted) {
                                            setState(() => error = '$e');
                                          }
                                        }
                                      },
                                child: const Text('导出内网公开证书'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      SecuritySection(
                        title: '公网入口',
                        description: '此页不会更改已部署的公网地址或手机信任证书。',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SelectableText(
                              '${snapshot?['public_origin'] == '' ? '尚未配置公网地址' : snapshot?['public_origin'] ?? '加载中'}',
                            ),
                            const SizedBox(height: 10),
                            Text(
                              snapshot?['public_enabled'] == true
                                  ? '已配置启用'
                                  : '未配置启用',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xffe0e5ec))),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton(
                  onPressed: busy || snapshot == null || !dirty ? null : save,
                  child: const Text('保存入口配置'),
                ),
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
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
