import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../shared/api.dart';
import 'security_layout.dart';
import 'security_page.dart';

class KPSettingsPage extends StatefulWidget {
  const KPSettingsPage({super.key, required this.api});
  final PlatformApi api;
  @override
  State<KPSettingsPage> createState() => _KPSettingsPageState();
}

class _KPSettingsPageState extends State<KPSettingsPage> {
  final origins = TextEditingController(),
      server = TextEditingController(),
      project = TextEditingController(),
      container = TextEditingController(text: 'WebContainer1'),
      publicOrigin = TextEditingController();
  Json? snapshot;
  List<Json> users = [], mappings = [];
  bool enabled = false, busy = false, dirty = false;
  String? error, message;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in [origins, server, project, container, publicOrigin]) {
      c.dispose();
    }
    super.dispose();
  }

  void accept(Json data) {
    snapshot = data;
    origins.text = (data['kp_origins'] as List? ?? []).join('\n');
    server.text = '${data['kp_server'] ?? ''}';
    project.text = '${data['kp_project'] ?? ''}';
    publicOrigin.text = '${data['public_origin'] ?? ''}';
    mappings = (data['users'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    enabled = data['enabled'] == true;
    dirty = false;
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> load() async {
    if (dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('重新读取 KP 配置？'),
          content: const Text('本页尚未保存的修改将被放弃。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('重新读取'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    await run(() async {
      final data = await Future.wait([
        widget.api.request('GET', '/api/v1/security/kp-settings'),
        widget.api.request('GET', '/api/v1/security/users'),
      ]);
      if (mounted) {
        setState(() {
          accept(data[0]);
          users = (data[1]['items'] as List? ?? []).cast<Json>();
        });
      }
    });
  }

  Future<void> save() => run(() async {
    final data = await widget.api.request(
      'PUT',
      '/api/v1/security/kp-settings',
      body: {
        'revision': snapshot!['revision'],
        'enabled': enabled,
        'kp_server': server.text.trim(),
        'kp_project': project.text.trim(),
        'kp_origins': origins.text
            .split(RegExp(r'[\n,，]'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        'users': mappings,
      },
    );
    if (mounted) {
      setState(() {
        accept(data);
        message = '配置已保存，请应用后在 KP 画面验证登录。';
      });
    }
  });
  Future<void> apply() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('应用 KP 接入配置？'),
        content: const Text('当前 KP 关联会话将失效，用户重新打开 KP 画面后按新配置接入。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('应用配置'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await run(() async {
      final data = await widget.api.request(
        'POST',
        '/api/v1/security/kp-settings',
        body: {'revision': snapshot!['revision'], 'action': 'apply'},
      );
      if (mounted) {
        setState(() {
          accept(data);
          message = data['running'] == true
              ? 'KP 接入已生效，可在 KP 画面验证。'
              : enabled
              ? '配置已应用，公网 HTTPS 入口尚未监听。'
              : 'KP 接入已停用。';
        });
      }
    });
  }

  Future<void> check() => run(() async {
    final data = await widget.api.request(
      'POST',
      '/api/v1/security/kp-settings',
      body: {'revision': snapshot!['revision'], 'action': 'check'},
    );
    if (mounted) setState(() => message = '${data['message']}');
  });
  Future<void> editMapping([int? index]) async {
    final subject = TextEditingController(
      text: index == null ? '' : '${mappings[index]['subject']}',
    );
    String? selected = index == null
        ? null
        : mappings[index]['user_id'] as String?;
    String? formError;
    final result = await showDialog<Json>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(index == null ? '添加账号映射' : '修改账号映射'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: subject,
                    decoration: const InputDecoration(
                      labelText: 'KP 稳定用户 ID',
                      helperText: '填写 KP 身份接口返回的 userId',
                    ),
                  ),
                  const SizedBox(height: 20),
                  LayoutBuilder(
                    builder: (context, constraints) => DropdownMenu<String>(
                      width: constraints.maxWidth,
                      initialSelection: selected,
                      enableFilter: true,
                      enableSearch: true,
                      requestFocusOnTap: true,
                      label: const Text('搜索并选择监控账号'),
                      dropdownMenuEntries: [
                        for (final user in users)
                          DropdownMenuEntry(
                            value: '${user['id']}',
                            label:
                                '${user['username']}${user['disabled'] == true ? '（已停用）' : ''}',
                            enabled: user['disabled'] != true,
                          ),
                      ],
                      onSelected: (value) {
                        selected = value;
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('权限沿用所选监控账号的站点、画面和业务授权。'),
                  if (formError != null)
                    Text(formError!, style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (subject.text.trim().isEmpty ||
                    selected == null ||
                    mappings.asMap().entries.any(
                      (e) =>
                          e.key != index &&
                          e.value['subject'] == subject.text.trim(),
                    )) {
                  update(() => formError = '请填写唯一 KP 用户 ID 并选择监控账号。');
                  return;
                }
                Navigator.pop(context, <String, dynamic>{
                  'subject': subject.text.trim(),
                  'user_id': selected,
                  'role': 'viewer',
                  'display_name': '',
                });
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        if (index == null) {
          mappings.add(result);
        } else {
          mappings[index] = result;
        }
        dirty = true;
      });
    }
    // Publish the selection immediately; only controller disposal waits for
    // the closing route animation.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    subject.dispose();
  }

  String get openScript {
    final base = jsonEncode(
      publicOrigin.text.trim().replaceAll(RegExp(r'/+$'), ''),
    );
    final name = container.text.trim();
    return '''var hmiBase = $base;
function openHmi() {
    window.HMIKP.open(hmiBase, $name, function () { return GetCurrentUser(); });
}
if (window.HMIKP) {
    openHmi();
} else {
    $name.setURL(hmiBase + "/kp/kp-loading.html");
    var script = document.createElement("script");
    script.src = hmiBase + "/kp/kp_bridge.js";
    script.onload = openHmi;
    script.onerror = function () { $name.setURL(hmiBase + "/kp/kp-fallback.html#helper_unavailable"); };
    document.head.appendChild(script);
}''';
  }

  bool get scriptValid {
    final uri = Uri.tryParse(publicOrigin.text.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        (uri.path.isEmpty || uri.path == '/') &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(container.text.trim());
  }

  Future<void> copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('脚本已复制')));
    }
  }

  Widget field(
    TextEditingController c,
    String label,
    String help, {
    int lines = 1,
    bool config = true,
  }) => TextField(
    controller: c,
    enabled: !busy,
    minLines: lines,
    maxLines: lines,
    decoration: InputDecoration(
      labelText: label,
      helperText: help,
      helperMaxLines: 3,
    ),
    onChanged: (_) => setState(() {
      if (config) dirty = true;
    }),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('KP 接入'),
      automaticallyImplyLeading: !SecurityPageScope.isRoot(context),
    ),
    body: SecurityList(
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        if (message != null) SelectableText(message!),
        if (snapshot == null)
          OutlinedButton(
            onPressed: busy ? null : load,
            child: const Text('重新读取'),
          ),
        if (snapshot != null) ...[
          SecurityDetails(
            children: [
              Text(
                snapshot!['running'] == true
                    ? '实际状态：KP 接入已启用'
                    : '实际状态：KP 接入未运行',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                dirty
                    ? '本页有未保存修改'
                    : snapshot!['pending'] == true
                    ? '已保存配置待应用'
                    : '已保存配置与应用状态一致',
              ),
              if (snapshot!['public_listening'] != true)
                const Text('公网 HTTPS 入口尚未监听，请先配置并启动公网入口。'),
              if ('${snapshot!['status_error'] ?? ''}'.isNotEmpty)
                SelectableText(
                  '${snapshot!['status_error']}',
                  style: const TextStyle(color: Colors.red),
                ),
              const Text(
                '访问地点不限：已批准的浏览器设备证书可随设备跨网络使用；采用 IP 白名单的客户端仍需符合已批准规则。账号权限和只读范围继续生效。',
              ),
            ],
          ),
          SecurityDetails(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 KP 接入'),
                value: enabled,
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        enabled = v;
                        dirty = true;
                      }),
              ),
              field(
                origins,
                'KP 公网网页地址',
                '用户浏览器实际打开的 KP 地址，填写协议、域名/IP、端口；每行一个，最多8个。它表示 KP 网站来源，与访问者 IP 无关。',
                lines: 3,
              ),
              field(
                server,
                'KP 后台服务地址',
                '监控后台用于核验令牌的 KP 地址。同机可用回环 HTTP，跨机使用可信 HTTPS。',
              ),
              field(project, 'KP 工程名（可选）', '按实际 KP 工程填写，无需工程参数时留空。'),
            ],
          ),
          SecurityDetails(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '账号映射',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: busy ? null : () => editMapping(),
                    icon: const Icon(Icons.add),
                    label: const Text('添加'),
                  ),
                ],
              ),
              if (mappings.isEmpty) const Text('添加 KP 用户 ID，并选择已授权的监控账号。'),
              for (final entry in mappings.asMap().entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('KP 用户 ${entry.value['subject']}'),
                  subtitle: Text(
                    users
                            .where((u) => u['id'] == entry.value['user_id'])
                            .map((u) => '${u['username']}')
                            .firstOrNull ??
                        '账号已不存在',
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: '修改映射',
                        onPressed: busy ? null : () => editMapping(entry.key),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: '移除映射',
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                mappings.removeAt(entry.key);
                                dirty = true;
                              }),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton(
                onPressed: busy ? null : save,
                child: const Text('保存配置'),
              ),
              OutlinedButton(
                onPressed: busy || dirty ? null : apply,
                child: const Text('应用配置'),
              ),
              OutlinedButton(
                onPressed: busy || dirty ? null : check,
                child: const Text('检查已保存配置与连接'),
              ),
              TextButton(
                onPressed: busy ? null : load,
                child: const Text('重新读取'),
              ),
            ],
          ),
          SecurityDetails(
            children: [
              const Text(
                'KP 画面脚本',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const Text('画面打开与关闭事件各配置一次。保存配置后，将网页容器名称和监控 HTTPS 地址填在下方，再复制脚本。'),
              field(
                publicOrigin,
                '监控系统 HTTPS 地址',
                '使用浏览器实际可访问的监控地址。',
                config: false,
              ),
              field(
                container,
                '网页容器名称',
                '例如 WebContainer1，与 KP 画面中的控件名称一致。',
                config: false,
              ),
              if (!scriptValid) const Text('请填写有效的 HTTPS 来源地址和网页容器名称。'),
              if (scriptValid) ...[
                OutlinedButton.icon(
                  onPressed: () => copy(openScript),
                  icon: const Icon(Icons.copy),
                  label: const Text('复制画面打开时脚本'),
                ),
                SelectableText(
                  openScript,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      copy('if (window.HMIKP) window.HMIKP.close();'),
                  icon: const Icon(Icons.copy),
                  label: const Text('复制画面关闭时脚本'),
                ),
              ],
            ],
          ),
        ],
      ],
    ),
  );
}
