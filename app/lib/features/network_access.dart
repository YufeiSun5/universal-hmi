import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../shared/api.dart';
import '../platform/save.dart';
import '../platform/backend_management.dart';
import '../platform/desktop_lifecycle.dart';
import '../platform/autostart.dart';
import 'autostart_settings.dart';
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
  String protocol = 'http';
  bool enabled = false, allowDevelopment = false, busy = false, dirty = false;
  String? error, message;
  Timer? applyPoll;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    applyPoll?.cancel();
    address.dispose();
    port.dispose();
    super.dispose();
  }

  void accept(Json data) {
    snapshot = data;
    protocol = '${data['protocol'] ?? 'https'}';
    address.text = '${data['address'] ?? ''}';
    port.text = '${data['port'] ?? 18443}';
    enabled = data['enabled'] == true;
    allowDevelopment = data['allow_development'] == true;
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
          'protocol': protocol,
          'enabled': enabled,
          'allow_development': allowDevelopment,
          'address': address.text.trim(),
          'port': int.tryParse(port.text.trim()) ?? 0,
        },
      );
      if (mounted) {
        setState(() {
          accept(data);
          message = data['restart_required'] == true
              ? '配置已保存，点击“应用内网配置”使新监听生效。'
              : '配置已保存，与实际监听一致。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> apply() async {
    if (busy || dirty || snapshot == null) return;
    final proceed = await openSecurityPage<bool>(
      context: context,
      builder: (context) => SecurityForm(
        title: const Text('应用已保存的内网配置？'),
        content: const Text(
          '内网浏览器连接可能短暂中断，请使用新地址重新访问。采集、公网和本机开发端保持运行，未保存的画面内容保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('应用内网配置'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    final revision = snapshot!['revision'];
    setState(() {
      busy = true;
      error = null;
      message = '正在准备应用内网配置';
    });
    var polling = false;
    applyPoll = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      if (polling) return;
      polling = true;
      try {
        final data = await widget.api.request(
          'GET',
          '/api/v1/security/network-access',
        );
        if (mounted && busy) {
          setState(() {
            snapshot = data;
            message = phaseText(data);
          });
        }
      } catch (_) {
        // The apply request reports the final error; polling never clears drafts.
      } finally {
        polling = false;
      }
    });
    try {
      final data = await widget.api.request(
        'POST',
        '/api/v1/security/network-access',
        body: {'revision': revision},
      );
      if (mounted) {
        setState(() {
          accept(data);
          message = phaseText(data);
          if (data['phase'] == 'failed') {
            error = '${failureText(data)}\n${recoveryText(data)}';
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e\n可重新读取实际状态后重试，保存成功不代表监听已生效。');
    } finally {
      applyPoll?.cancel();
      applyPoll = null;
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> restartBackend() async {
    if (busy || dirty || snapshot == null) return;
    if (await focusOtherDeveloperForRestart()) {
      if (mounted) {
        setState(() => error = '本工程开发端已打开，已切换到开发端。请在开发端执行重启，以便检查并保存画面草稿。');
      }
      return;
    }
    if (!await applicationExitGuards.canRestart() || !mounted) return;
    final confirmed = await openSecurityPage<bool>(
      context: context,
      builder: (context) => SecurityForm(
        title: const Text('重启后台并应用？'),
        content: const Text(
          '采集、Web 和移动端连接会短暂中断，其他已打开的用户端也会受到影响。工程、账号、证书、数据库、画面和绑定保留；后台启动并验证后需要重新登录。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重启后台并应用'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      try {
        Json allowed;
        try {
          allowed = await widget.api.request(
            'POST',
            '/api/v1/security/network-access',
            body: {
              'action': 'authorize_restart',
              'revision': snapshot!['revision'],
            },
          );
        } on PlatformRequestException catch (e) {
          if (e.statusCode != 405) rethrow;
          // Legacy backends have no restart authorization verb. Saving the
          // unchanged snapshot uses their existing admin/recent-login/CSRF gate.
          final current = snapshot!;
          await widget.api.request(
            'PUT',
            '/api/v1/security/network-access',
            body: {
              'revision': current['revision'],
              'enabled': current['enabled'],
              'allow_development': current['allow_development'] == true,
              'address': current['address'],
              'port': current['port'],
            },
          );
          allowed = {'authorized': true};
        }
        if (allowed['authorized'] != true) throw StateError('后台重启未获本机管理员授权');
        if (mounted) await backendManagement.run('restart');
      } catch (e) {
        if (mounted) setState(() => error = '$e');
      }
    }
  }

  String phaseText(Json data) => switch (data['phase']) {
    'preparing' => '正在准备',
    'stopping' => '正在停止旧内网监听',
    'starting' => '正在启动新内网监听',
    'verifying' => '正在验证实际 Web 监听',
    'restoring' => '正在恢复原可用监听',
    'applied' =>
      data['running'] == true ? '已生效：${data['running_origin']}' : '已生效：内网入口已关闭',
    'failed' => '应用失败',
    _ => '等待应用',
  };
  String failureText(Json data) =>
      '${switch (data['error_code']) {
        'port_in_use' => '端口被占用，请修改端口，或通过占用程序自己的界面处理',
        'invalid_address' => '地址无效或已不属于本机网卡',
        'permission_denied' => '没有监听此地址或端口的权限',
        'certificate_failed' => '内网证书加载失败，请重新保存配置后应用',
        'stop_timeout' => '停止旧监听超时',
        _ => '新监听启动或验证失败',
      }}：${data['status_error'] ?? ''}';
  String recoveryText(Json data) => switch (data['recovery']) {
    'previous_unchanged' => '原监听保持原状。',
    'previous_restored' => '原监听已恢复并通过实际连接验证。',
    'restore_failed' => '原监听恢复失败，请检查错误后重试。',
    'unverified' => '原监听状态尚未确认，请重新读取。',
    _ => '',
  };

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
                      if (autostartAvailable) ...[
                        AutostartSettings(api: widget.api),
                        const SizedBox(height: 24),
                      ],
                      const Text(
                        '使用原账号、密码和图形验证码登录，客户端 IP 需加入 Web 白名单。内网可单独开放工程师开发，公网权限不变。',
                      ),
                      const SizedBox(height: 24),
                      SecuritySection(
                        title: '内网 Web',
                        description: '先保存配置，再应用内网监听；实际连接验证通过后才显示已生效。',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('启用内网访问'),
                              subtitle: const Text('仅监听此电脑指定的内网地址'),
                              value: enabled,
                              onChanged: busy || snapshot == null
                                  ? null
                                  : (value) => setState(() {
                                      enabled = value;
                                      dirty = true;
                                    }),
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('允许工程师通过内网 Web 开发'),
                              subtitle: const Text(
                                '保留账号原有开发权限，普通用户仍按原授权使用。更改后保存并应用，内网用户需重新登录。',
                              ),
                              value: allowDevelopment,
                              onChanged: busy || snapshot == null
                                  ? null
                                  : (value) => setState(() {
                                      allowDevelopment = value;
                                      dirty = true;
                                    }),
                            ),
                            const SizedBox(height: 20),
                            if (objects(snapshot?['addresses']).isNotEmpty) ...[
                              DropdownButtonFormField<String>(
                                key: ValueKey(protocol),
                                initialValue: protocol,
                                decoration: const InputDecoration(
                                  labelText: '访问协议',
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'http',
                                    child: Text('HTTP（无需安装证书）'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'https',
                                    child: Text('HTTPS（加密连接）'),
                                  ),
                                ],
                                onChanged: busy
                                    ? null
                                    : (value) => setState(() {
                                        protocol = value!;
                                        dirty = true;
                                      }),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                protocol == 'http'
                                    ? '内网浏览器直接访问，无需安装证书；HTTP 连接不加密。'
                                    : 'HTTPS 加密连接，浏览器需信任内网证书。',
                              ),
                              const SizedBox(height: 16),
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
                                      labelText: 'Web 端口',
                                    ),
                                    onChanged: (_) =>
                                        setState(() => dirty = true),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            SelectableText(
                              '编辑地址：$protocol://${address.text}:${port.text}',
                            ),
                            SelectableText(
                              '已保存配置：${snapshot?['enabled'] == true ? snapshot!['origin'] : '内网关闭'}',
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
                                child: Text('已保存配置与实际监听不一致，请应用'),
                              ),
                            if (snapshot?['status_error'] != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text('${snapshot!['status_error']}'),
                              ),
                            for (final owner in objects(
                              snapshot?['port_owners'],
                            ))
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  '占用程序：${owner['program']} · PID ${owner['pid']}（未结束该进程）',
                                ),
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
                      if (protocol == 'https')
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
                                  onPressed:
                                      snapshot?['certificate_pem'] == null
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
                  onPressed:
                      busy || dirty || snapshot?['apply_available'] != true
                      ? null
                      : apply,
                  child: const Text('应用内网配置'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : load,
                  child: const Text('重新读取本机地址'),
                ),
                if (backendManagementAvailable)
                  OutlinedButton(
                    onPressed: busy || dirty || snapshot == null
                        ? null
                        : restartBackend,
                    child: const Text('重启后台并应用'),
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
