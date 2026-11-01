import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/desktop_dialog.dart';
import 'role_management.dart';
import 'public_access.dart';
import 'device_registrations.dart';
import 'public_access_events.dart';

/// Security administration is independent of the engineering workspace.
class SecurityPanel extends StatefulWidget {
  const SecurityPanel({super.key, required this.api});
  final PlatformApi api;
  @override
  State<SecurityPanel> createState() => _SecurityPanelState();
}

class _SecurityPanelState extends State<SecurityPanel> {
  List<Json> users = [],
      stations = [],
      screens = [],
      externalScreens = [],
      sessions = [],
      audit = [],
      customRoles = [];
  bool loading = true;
  String? error;
  int tab = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  List<Json> rows(Json data) => (data['items'] as List? ?? []).cast<Json>();
  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (tab == 0) {
        final results = await Future.wait([
          widget.api.request('GET', '/api/v1/security/users'),
          widget.api.request('GET', '/api/v1/security/roles'),
          widget.api.request('GET', '/api/v1/security/stations'),
          widget.api.request('GET', '/api/v1/screens', query: {'all': 'true'}),
          widget.api.request('GET', '/api/v1/external/screens'),
        ]);
        if (!mounted) return;
        users = rows(results[0]);
        customRoles = rows(results[1]);
        stations = rows(results[2]);
        screens = rows(results[3]);
        externalScreens = rows(results[4]);
      } else if (tab == 1) {
        sessions = rows(
          await widget.api.request('GET', '/api/v1/security/sessions'),
        );
      } else if (tab == 2) {
        audit = rows(await widget.api.request('GET', '/api/v1/security/audit'));
      }
    } catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> edit([Json? user]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _UserEditor(
        api: widget.api,
        user: user,
        stations: stations,
        screens: screens,
        externalScreens: externalScreens,
        customRoles: customRoles,
      ),
    );
    if (saved == true && mounted) await load();
  }

  Future<void> revoke(Json session) async {
    try {
      await widget.api.request(
        'POST',
        '/api/v1/security/sessions/revoke',
        body: {'user_id': session['user_id'], 'session_id': session['id']},
      );
      await load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    shape: DesktopDialogStyle.shape,
    clipBehavior: Clip.antiAlias,
    backgroundColor: DesktopDialogStyle.background,
    insetPadding: MediaQuery.sizeOf(context).width < 600
        ? const EdgeInsets.all(16)
        : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
    child: SizedBox(
      width: 900,
      height: 650,
      child: Column(
        children: [
          Container(
            padding: DesktopDialogStyle.titlePadding,
            decoration: const BoxDecoration(
              color: DesktopDialogStyle.header,
              border: Border(
                bottom: BorderSide(color: DesktopDialogStyle.line),
              ),
            ),
            child: LayoutBuilder(
              builder: (context, box) {
                final title = Row(
                  children: [
                    const Icon(Icons.manage_accounts_outlined),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '用户与权限',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (box.maxWidth < 560)
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                  ],
                );
                final actions = Wrap(
                  children: [
                    IconButton(
                      tooltip: '公网 Web 白名单（仅本机）',
                      icon: const Icon(Icons.shield_outlined),
                      onPressed: () => showDialog<void>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => PublicAccessPanel(api: widget.api),
                      ),
                    ),
                    IconButton(
                      tooltip: '公网请求记录（仅本机）',
                      icon: const Icon(Icons.receipt_long_outlined),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            PublicAccessEventsPanel(api: widget.api),
                      ),
                    ),
                    IconButton(
                      tooltip: '设备登记（仅本机，未开通手机访问）',
                      icon: const Icon(Icons.phonelink_setup_outlined),
                      onPressed: () => showDialog<void>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) =>
                            DeviceRegistrationsPanel(api: widget.api),
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新',
                      onPressed: loading ? null : load,
                      icon: const Icon(Icons.refresh),
                    ),
                    if (box.maxWidth >= 560)
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                  ],
                );
                return box.maxWidth < 560
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [title, actions],
                      )
                    : Row(
                        children: [
                          Expanded(child: title),
                          actions,
                        ],
                      );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: LayoutBuilder(
              builder: (context, box) {
                final segments = box.maxWidth < 560
                    ? Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final entry in const {
                            0: '账号与范围',
                            1: '登录会话',
                            3: '角色管理',
                          }.entries)
                            ChoiceChip(
                              label: Text(entry.value),
                              selected: tab == entry.key,
                              onSelected: (_) {
                                setState(() => tab = entry.key);
                                load();
                              },
                            ),
                        ],
                      )
                    : SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 0, label: Text('账号与范围')),
                          ButtonSegment(value: 1, label: Text('登录会话')),
                          ButtonSegment(value: 3, label: Text('角色管理')),
                        ],
                        selected: {tab},
                        onSelectionChanged: (v) {
                          setState(() => tab = v.first);
                          load();
                        },
                      );
                final create = FilledButton.icon(
                  onPressed: loading ? null : () => edit(),
                  icon: const Icon(Icons.person_add_alt_1, size: 17),
                  label: const Text('新建账号'),
                );
                return box.maxWidth < 560
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          segments,
                          if (tab == 0) ...[const SizedBox(height: 8), create],
                        ],
                      )
                    : Row(
                        children: [
                          segments,
                          const Spacer(),
                          if (tab == 0) create,
                        ],
                      );
              },
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (loading) const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Expanded(
            child: tab == 3
                ? RoleManager(api: widget.api)
                : tab == 0
                ? ListView.separated(
                    itemCount: users.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final u = users[i];
                      final g = u['grants'] as Json;
                      final assignedNames = customRoles
                          .where(
                            (r) => (u['custom_role_ids'] as List? ?? [])
                                .contains(r['id']),
                          )
                          .map((r) => r['name'])
                          .join('、');
                      return ListTile(
                        leading: Icon(
                          u['disabled'] == true
                              ? Icons.person_off_outlined
                              : Icons.person_outline,
                        ),
                        title: Text(u['username'].toString()),
                        subtitle: Text(
                          '${assignedNames.isEmpty ? '' : '$assignedNames · '}${(g['roles'] as List? ?? []).map(roleName).join('、')} · ${g['all_stations'] == true ? '全部站点' : '${(g['station_ids'] as List? ?? []).length}个站点'}${u['disabled'] == true ? ' · 已停用' : ''}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '重置双因素验证',
                              icon: const Icon(Icons.lock_reset),
                              onPressed: () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (c) => AlertDialog(
                                    title: const Text('重置双因素验证'),
                                    content: Text(
                                      '重置 ${u['username']} 的验证器并撤销其所有会话。下次远程登录需要重新绑定。',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(c, false),
                                        child: const Text('取消'),
                                      ),
                                      FilledButton(
                                        onPressed: () => Navigator.pop(c, true),
                                        child: const Text('重置'),
                                      ),
                                    ],
                                  ),
                                );
                                if (confirmed != true) {
                                  return;
                                }
                                try {
                                  await widget.api.request(
                                    'POST',
                                    '/api/v1/security/mfa/reset',
                                    body: {'user_id': u['id']},
                                  );
                                  await load();
                                } catch (e) {
                                  if (mounted) {
                                    setState(() => error = e.toString());
                                  }
                                }
                              },
                            ),
                            OutlinedButton(
                              onPressed: () => edit(u),
                              child: const Text('编辑权限'),
                            ),
                          ],
                        ),
                      );
                    },
                  )
                : tab == 1
                ? ListView.builder(
                    itemCount: sessions.length,
                    itemBuilder: (_, i) {
                      final s = sessions[i];
                      return ListTile(
                        title: Text(
                          users
                                  .where((u) => u['id'] == s['user_id'])
                                  .map((u) => u['username'])
                                  .firstOrNull
                                  ?.toString() ??
                              s['user_id'].toString(),
                        ),
                        subtitle: Text('登录：${s['started']}\n最近访问：${s['last']}'),
                        isThreeLine: true,
                        trailing: OutlinedButton(
                          onPressed: () => revoke(s),
                          child: const Text('撤销会话'),
                        ),
                      );
                    },
                  )
                : ListView.separated(
                    itemCount: audit.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final a = audit[i];
                      return ListTile(
                        dense: true,
                        title: Text('${a['action']} · ${a['result']}'),
                        subtitle: Text(
                          '${a['at']}\n${a['actor']} → ${a['target']}',
                        ),
                        isThreeLine: true,
                      );
                    },
                  ),
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '权限变更使原有登录失效。开发、设备控制和授权管理分别授予。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}

String roleName(dynamic role) =>
    const {
      'viewer': '查看员',
      'operator': '操作员',
      'engineer': '工程师',
      'admin': '安全管理员',
      'auditor': '审计员',
    }[role] ??
    role.toString();

class _UserEditor extends StatefulWidget {
  const _UserEditor({
    required this.api,
    required this.user,
    required this.stations,
    required this.screens,
    required this.externalScreens,
    required this.customRoles,
  });
  final PlatformApi api;
  final Json? user;
  final List<Json> stations, screens, externalScreens, customRoles;
  @override
  State<_UserEditor> createState() => _UserEditorState();
}

class _UserEditorState extends State<_UserEditor> {
  final formScroll = ScrollController();
  late final name = TextEditingController(
    text: widget.user?['username']?.toString() ?? '',
  );
  final password = TextEditingController();
  late final Json original =
      (widget.user?['direct_grants'] as Json?) ??
      (widget.user?['grants'] as Json?) ??
      {};
  late final custom = (widget.user?['custom_role_ids'] as List? ?? [])
      .cast<String>()
      .toSet();
  late final roles = ((original['roles'] as List?) ?? ['viewer'])
      .cast<String>()
      .toSet();
  late final stations = ((original['station_ids'] as List?) ?? [])
      .cast<String>()
      .toSet();
  late final screens = ((original['screen_ids'] as List?) ?? [])
      .cast<String>()
      .toSet();
  late final external = ((original['external_screen_ids'] as List?) ?? [])
      .cast<String>()
      .toSet();
  late bool all = original['all_stations'] == true,
      export = original['export'] == true,
      control = original['control'] == true,
      grantControl = original['grant_control'] == true,
      disabled = widget.user?['disabled'] == true;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    formScroll.dispose();
    name.dispose();
    password.clear();
    password.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.request(
        widget.user == null ? 'POST' : 'PUT',
        '/api/v1/security/users${widget.user == null ? '' : '/${widget.user!['id']}'}',
        body: {
          'username': name.text.trim(),
          if (password.text.isNotEmpty) 'password': password.text,
          'disabled': disabled,
          'version': widget.user?['version'] ?? 0,
          'custom_role_ids': custom.toList(),
          'grants': {
            'roles': roles.toList(),
            'all_stations': all,
            'station_ids': stations.toList(),
            'screen_ids': screens.toList(),
            'external_screen_ids': external.toList(),
            'export': export,
            'control': control,
            'grant_control': grantControl,
          },
        },
      );
      password.clear();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          busy = false;
        });
      }
    }
  }

  Widget check(
    String title,
    bool value,
    ValueChanged<bool> changed, {
    String? subtitle,
  }) => CheckboxListTile(
    dense: true,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    value: value,
    onChanged: busy ? null : (v) => setState(() => changed(v == true)),
    controlAffinity: ListTileControlAffinity.leading,
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    shape: DesktopDialogStyle.shape,
    clipBehavior: Clip.antiAlias,
    backgroundColor: DesktopDialogStyle.background,
    insetPadding: DesktopDialogStyle.insetPadding,
    titlePadding: EdgeInsets.zero,
    contentPadding: DesktopDialogStyle.contentPadding,
    actionsPadding: DesktopDialogStyle.actionsPadding,
    title: DesktopDialogTitle(
      widget.user == null ? '新建账号' : '编辑 ${widget.user!['username']}',
    ),
    content: SizedBox(
      width: 560,
      child: Scrollbar(
        controller: formScroll,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: formScroll,
          padding: const EdgeInsets.only(right: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: name,
                enabled: !busy,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                enabled: !busy,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: widget.user == null
                      ? '初始密码（${widget.api is SessionApi ? (widget.api as SessionApi).session?.passwordMinLength ?? 7 : 7}–128字符）'
                      : '重置密码（留空保留）',
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '自定义角色',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              if (widget.customRoles.isEmpty) const Text('可在角色管理中新建岗位角色。'),
              for (final r in widget.customRoles)
                check(
                  r['name'].toString(),
                  custom.contains(r['id']),
                  (v) => v
                      ? custom.add(r['id'] as String)
                      : custom.remove(r['id']),
                  subtitle: '与直接权限合并；沿用下方用户范围',
                ),
              const SizedBox(height: 12),
              const Text(
                '直接权限 / 预置角色',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final role in [
                'viewer',
                'operator',
                'engineer',
                'admin',
                'auditor',
              ])
                check(
                  roleName(role),
                  roles.contains(role),
                  (v) => v ? roles.add(role) : roles.remove(role),
                ),
              check('允许数据文件导入、导出', export, (v) => export = v),
              check(
                '允许设备下设',
                control,
                (v) => control = v,
                subtitle: '仍受目标站点、点位可写属性和后端校验约束',
              ),
              check(
                '全部站点',
                all,
                (v) => all = v,
                subtitle: '全局开发发布及用户管理需要工程级范围',
              ),
              if (roles.contains('admin'))
                check(
                  '可授予设备控制权限',
                  grantControl,
                  (v) => grantControl = v,
                  subtitle: '管理授权能力，与本人下设权限分别设置',
                ),
              if (!all) ...[
                const Text(
                  '可访问站点',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                for (final st in widget.stations)
                  check(
                    st['name'].toString().isEmpty
                        ? '公共范围'
                        : st['name'].toString(),
                    stations.contains(st['id']),
                    (v) => v
                        ? stations.add(st['id'] as String)
                        : stations.remove(st['id']),
                  ),
                const SizedBox(height: 8),
                const Text('额外画面（包含图中的静态文字，不附带跨站变量权限）'),
                for (final s in widget.screens)
                  check(
                    '${s['station']} / ${s['name']}',
                    screens.contains(s['id']),
                    (v) => v
                        ? screens.add(s['id'] as String)
                        : screens.remove(s['id']),
                  ),
              ],
              const SizedBox(height: 12),
              const Text(
                '外数据画面（独立授权，包含外部源的全部启用站区）',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              if (widget.externalScreens.isEmpty) const Text('尚未创建外数据画面。'),
              for (final s in widget.externalScreens)
                check(
                  '${s['name']}',
                  external.contains(s['id']),
                  (v) => v
                      ? external.add(s['id'] as String)
                      : external.remove(s['id']),
                ),
              if (widget.user != null)
                check('停用账号', disabled, (v) => disabled = v),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: busy ? null : save,
        child: Text(busy ? '保存中…' : '保存权限'),
      ),
    ],
  );
}
