import 'package:flutter/material.dart';
import '../shared/api.dart';

const roleCapabilities = {
  'viewer': '查看画面与数据',
  'operator': '运行操作',
  'engineer': '开发配置、编辑与发布',
  'admin': '管理账号、角色与会话',
  'auditor': '查看审计记录',
};

class RoleManager extends StatefulWidget {
  const RoleManager({super.key, required this.api});
  final PlatformApi api;
  @override
  State<RoleManager> createState() => _RoleManagerState();
}

class _RoleManagerState extends State<RoleManager> {
  List<Json> roles = [], users = [];
  String? error;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final data = await Future.wait([
        widget.api.request('GET', '/api/v1/security/roles'),
        widget.api.request('GET', '/api/v1/security/users'),
      ]);
      if (!mounted) return;
      roles = (data[0]['items'] as List? ?? []).cast<Json>();
      users = (data[1]['items'] as List? ?? []).cast<Json>();
    } catch (e) {
      if (mounted) error = e.toString();
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> edit([Json? role]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RoleEditor(api: widget.api, role: role),
    );
    if (saved == true && mounted) await load();
  }

  Future<void> members(Json role) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RoleMembers(api: widget.api, role: role, users: users),
    );
    if (saved == true && mounted) await load();
  }

  Future<void> remove(Json role) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('删除角色 ${role['name']}'),
        content: const Text('仅可删除没有成员的自定义角色。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.api.request(
        'DELETE',
        '/api/v1/security/roles/${role['id']}',
        body: {'version': role['version']},
      );
      await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Row(
          children: [
            const Expanded(child: Text('岗位角色统一管理功能权限；站点与画面范围按用户设置。')),
            FilledButton.icon(
              onPressed: busy ? null : () => edit(),
              icon: const Icon(Icons.add),
              label: const Text('新建角色'),
            ),
          ],
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
      if (busy) const LinearProgressIndicator(),
      Expanded(
        child: roles.isEmpty && !busy
            ? const Center(child: Text('尚无自定义角色。可新建值班长、站长或维修人员。'))
            : ListView.separated(
                itemCount: roles.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = roles[i], g = r['grants'] as Json;
                  final labels = (g['roles'] as List? ?? [])
                      .map((v) => roleCapabilities[v] ?? v.toString())
                      .toList();
                  if (g['export'] == true) labels.add('导入导出');
                  if (g['control'] == true) labels.add('设备下设');
                  if (g['grant_control'] == true) labels.add('授予控制权限');
                  return ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: Text('${r['name']} · ${r['members']} 名成员'),
                    subtitle: Text(labels.join('、')),
                    trailing: Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton(
                          onPressed: busy ? null : () => members(r),
                          child: const Text('分配成员'),
                        ),
                        OutlinedButton(
                          onPressed: busy ? null : () => edit(r),
                          child: const Text('编辑角色'),
                        ),
                        IconButton(
                          tooltip: '删除角色',
                          onPressed: busy || r['members'] != 0
                              ? null
                              : () => remove(r),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    ],
  );
}

class _RoleEditor extends StatefulWidget {
  const _RoleEditor({required this.api, this.role});
  final PlatformApi api;
  final Json? role;
  @override
  State<_RoleEditor> createState() => _RoleEditorState();
}

class _RoleEditorState extends State<_RoleEditor> {
  late final name = TextEditingController(
    text: widget.role?['name']?.toString() ?? '',
  );
  late final Json original = widget.role?['grants'] as Json? ?? {};
  late final roles = (original['roles'] as List? ?? ['viewer'])
      .cast<String>()
      .toSet();
  late bool export = original['export'] == true,
      control = original['control'] == true,
      grantControl = original['grant_control'] == true;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.request(
        widget.role == null ? 'POST' : 'PUT',
        '/api/v1/security/roles${widget.role == null ? '' : '/${widget.role!['id']}'}',
        body: {
          'name': name.text.trim(),
          'version': widget.role?['version'] ?? 0,
          'grants': {
            'roles': roles.toList(),
            'all_stations': false,
            'station_ids': <String>[],
            'screen_ids': <String>[],
            'export': export,
            'control': control,
            'grant_control': grantControl,
          },
        },
      );
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

  Widget check(String title, bool value, ValueChanged<bool> change) =>
      CheckboxListTile(
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(title),
        value: value,
        onChanged: busy ? null : (v) => setState(() => change(v == true)),
      );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.role == null ? '新建角色' : '编辑角色'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: name,
              enabled: !busy,
              maxLength: 40,
              decoration: const InputDecoration(
                labelText: '角色名称',
                hintText: '例如：值班长',
              ),
            ),
            for (final entry in roleCapabilities.entries)
              check(
                entry.value,
                roles.contains(entry.key),
                (v) => v ? roles.add(entry.key) : roles.remove(entry.key),
              ),
            check('允许数据文件导入、导出', export, (v) => export = v),
            check('允许设备下设', control, (v) => control = v),
            check('可授予设备控制权限', grantControl, (v) => grantControl = v),
            const Text('开发、用户管理和全局审计仍要求用户拥有全部站点范围。角色变更将撤销成员的已有登录。'),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
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
        child: Text(busy ? '保存中…' : '保存角色'),
      ),
    ],
  );
}

class _RoleMembers extends StatefulWidget {
  const _RoleMembers({
    required this.api,
    required this.role,
    required this.users,
  });
  final PlatformApi api;
  final Json role;
  final List<Json> users;
  @override
  State<_RoleMembers> createState() => _RoleMembersState();
}

class _RoleMembersState extends State<_RoleMembers> {
  late final original = widget.users
      .where(
        (u) =>
            (u['custom_role_ids'] as List? ?? []).contains(widget.role['id']),
      )
      .map((u) => u['id'] as String)
      .toSet();
  late final selected = {...original};
  bool busy = false;
  String? error;
  String filter = '';
  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.request(
        'POST',
        '/api/v1/security/roles/${widget.role['id']}/members',
        body: {
          'version': widget.role['version'],
          'changes': [
            for (final u in widget.users)
              if (selected.contains(u['id']) != original.contains(u['id']))
                {
                  'user_id': u['id'],
                  'version': u['version'],
                  'assigned': selected.contains(u['id']),
                },
          ],
        },
      );
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

  @override
  Widget build(BuildContext context) {
    final visible = widget.users
        .where(
          (u) => u['username'].toString().toLowerCase().contains(
            filter.toLowerCase(),
          ),
        )
        .toList();
    return AlertDialog(
      title: Text('分配成员 · ${widget.role['name']}'),
      content: SizedBox(
        width: 560,
        height: 400,
        child: Column(
          children: [
            TextField(
              enabled: !busy,
              decoration: const InputDecoration(labelText: '搜索用户'),
              onChanged: (v) => setState(() => filter = v),
            ),
            Row(
              children: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(
                          () => selected.addAll(
                            visible.map((u) => u['id'] as String),
                          ),
                        ),
                  child: const Text('全选搜索结果'),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(
                          () => selected.removeAll(visible.map((u) => u['id'])),
                        ),
                  child: const Text('清除搜索结果'),
                ),
              ],
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final u in visible)
                    CheckboxListTile(
                      dense: true,
                      title: Text(u['username'].toString()),
                      subtitle: Text(
                        u['disabled'] == true ? '账号已停用' : '保留此用户的站点与画面范围',
                      ),
                      value: selected.contains(u['id']),
                      onChanged: busy
                          ? null
                          : (v) => setState(
                              () => v == true
                                  ? selected.add(u['id'] as String)
                                  : selected.remove(u['id']),
                            ),
                    ),
                ],
              ),
            ),
            Text('已选 ${selected.length} 人；变更后相关用户需重新登录。'),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: Text(busy ? '保存中…' : '保存成员'),
        ),
      ],
    );
  }
}
