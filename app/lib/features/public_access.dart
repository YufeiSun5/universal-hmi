import 'package:flutter/material.dart';
import '../shared/api.dart';

const _policyPath = '/api/v1/security/public-access';

/// Local management of public Web IP policy, not proof of account ownership.
class PublicAccessPanel extends StatefulWidget {
  const PublicAccessPanel({super.key, required this.api});
  final PlatformApi api;
  @override
  State<PublicAccessPanel> createState() => _PublicAccessPanelState();
}

class _PublicAccessPanelState extends State<PublicAccessPanel> {
  Json? policy;
  List<Json> rules = [], users = [];
  bool busy = true, modal = false, dirty = false, closing = false;
  String? error, ownerError;
  bool get locked => busy || modal || closing;

  @override
  void initState() {
    super.initState();
    fetch();
    loadUsers();
  }

  Future<void> loadUsers() async {
    try {
      final result = await widget.api.request('GET', '/api/v1/security/users');
      if (mounted) setState(() => users = objects(result['items']));
    } catch (_) {
      if (mounted) setState(() => ownerError = '账号列表不可用；保留已有归属 ID，不推断身份。');
    }
  }

  Future<void> fetch() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request('GET', _policyPath);
      if (!mounted) return;
      setState(() {
        policy = result;
        rules = objects(
          result['rules'],
        ).map((r) => Map<String, dynamic>.from(r)).toList();
        dirty = false;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
    if (mounted) setState(() => busy = false);
  }

  Future<bool> confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> leave({bool refresh = false}) async {
    if (locked) return;
    setState(() => modal = true);
    final accepted =
        !dirty || await confirm('放弃未保存的修改？', '草稿尚未改变公网访问策略。', '放弃修改');
    if (!mounted) return;
    setState(() => modal = false);
    if (!accepted) return;
    if (refresh) {
      await fetch();
    } else {
      setState(() => closing = true);
      Navigator.pop(context);
    }
  }

  Future<void> edit([int? index]) async {
    if (locked || policy == null) return;
    setState(() => modal = true);
    final result = await showDialog<Json>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _RuleEditor(users: users, rule: index == null ? null : rules[index]),
    );
    if (!mounted) return;
    setState(() {
      modal = false;
      if (result != null) {
        if (index == null) {
          rules.add(result);
        } else {
          rules[index] = result;
        }
        dirty = true;
      }
    });
  }

  Future<void> remove(int index) async {
    if (locked) return;
    setState(() => modal = true);
    final accepted = await confirm(
      '删除这条规则？',
      '${rules[index]['cidr']}\n仅修改草稿，保存后才停止批准此规则。',
      '删除规则',
    );
    if (!mounted) return;
    setState(() {
      modal = false;
      if (accepted) {
        rules.removeAt(index);
        dirty = true;
      }
    });
  }

  Future<void> save() async {
    if (locked || policy == null || !dirty) return;
    // Lock before confirmation as well as during the request: double clicks
    // cannot create two confirmations or submit two revisions.
    setState(() => modal = true);
    if (policy!['source'] == 'file') {
      final accepted = await confirm(
        '切换为数据库策略',
        '首次保存后数据库成为白名单唯一来源，配置文件不再决定规则。空列表拒绝全部公网访问，本机管理不受影响。',
        '确认保存',
      );
      if (!mounted) return;
      if (!accepted) {
        setState(() => modal = false);
        return;
      }
    }
    setState(() {
      modal = false;
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'PUT',
        _policyPath,
        body: {
          'revision': policy!['revision'],
          'rules': [
            for (final r in rules)
              {
                for (final key in [
                  'id',
                  'cidr',
                  'owner_label',
                  'remark',
                  'enabled',
                ])
                  key: r[key],
                if ((r['owner_user_id']?.toString() ?? '').isNotEmpty)
                  'owner_user_id': r['owner_user_id'],
                if ((r['expires_at']?.toString() ?? '').isNotEmpty)
                  'expires_at': r['expires_at'],
              },
          ],
        },
      );
      if (!mounted) return;
      setState(() {
        policy = result;
        rules = objects(result['rules']);
        dirty = false;
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is PlatformRequestException && e.statusCode == 409
              ? '策略已被其他管理员修改。草稿已保留；请记录修改后重新加载并核对。'
              : e.toString(),
        );
      }
    }
    if (mounted) setState(() => busy = false);
  }

  String owner(Json rule) {
    final id = rule['owner_user_id']?.toString() ?? '';
    if (id.isEmpty) return '未关联账号';
    final matches = users.where((u) => u['id'] == id);
    final name = matches.isEmpty ? '未解析账号' : '${matches.first['username']}';
    final status =
        const {
          'active': '账号可用',
          'disabled': '账号已停用',
          'missing': '账号已不存在',
          'unassigned': '未关联账号',
        }[rule['owner_status']] ??
        '归属状态待确认';
    return '$name · ID $id · $status';
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: closing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) leave();
    },
    child: Dialog(
      child: SizedBox(
        width: 820,
        height: 620,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '公网 Web 白名单（仅本机）',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭白名单',
                    onPressed: locked ? null : () => leave(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '公网始终只读。本页不更改 HTTPS、端口或启用状态。归属仅为人工 IP 备注，不是访问者身份认证。',
                  ),
                  Text(
                    policy?['source'] == 'file'
                        ? '当前来源：配置文件。首次保存将切换为数据库权威策略。'
                        : '当前来源：${policy == null ? '加载中' : '数据库'}',
                  ),
                  const Text('空列表拒绝全部公网访问，本机不受影响；保存立即生效，并终止不再批准的公网事件连接。'),
                  if (ownerError != null) Text(ownerError!),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (dirty) const Text('未保存修改'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: locked ? null : () => leave(refresh: true),
                        child: const Text('重新加载'),
                      ),
                      OutlinedButton(
                        onPressed: locked || policy == null
                            ? null
                            : () => edit(),
                        child: const Text('添加规则'),
                      ),
                      FilledButton(
                        onPressed: locked || !dirty ? null : save,
                        child: const Text('保存策略'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (!busy && rules.isEmpty) const Text('没有白名单规则。'),
                  for (var i = 0; i < rules.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${rules[i]['cidr']} · ${rules[i]['enabled'] == true ? '启用' : '停用'}',
                          ),
                          Text(
                            '归属标签：${rules[i]['owner_label'] ?? ''} · ${owner(rules[i])}',
                          ),
                          Text('备注：${rules[i]['remark'] ?? ''}'),
                          Text('到期：${rules[i]['expires_at'] ?? '不设到期'}'),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: locked ? null : () => edit(i),
                                child: const Text('编辑规则'),
                              ),
                              TextButton(
                                onPressed: locked ? null : () => remove(i),
                                child: const Text('删除规则'),
                              ),
                            ],
                          ),
                          const Divider(),
                        ],
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

class _RuleEditor extends StatefulWidget {
  const _RuleEditor({required this.users, this.rule});
  final List<Json> users;
  final Json? rule;
  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late final cidr = TextEditingController(
    text: widget.rule?['cidr']?.toString() ?? '',
  );
  late final label = TextEditingController(
    text: widget.rule?['owner_label']?.toString() ?? '',
  );
  late final remark = TextEditingController(
    text: widget.rule?['remark']?.toString() ?? '',
  );
  late final expiry = TextEditingController(
    text: widget.rule?['expires_at']?.toString() ?? '',
  );
  late String ownerID = widget.rule?['owner_user_id']?.toString() ?? '';
  late bool enabled = widget.rule?['enabled'] != false;
  bool dirty = false, confirming = false, closing = false;
  String? error;
  @override
  void dispose() {
    for (final c in [cidr, label, remark, expiry]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> cancel() async {
    if (confirming || closing) return;
    if (dirty) {
      confirming = true;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('放弃规则编辑？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('放弃编辑'),
            ),
          ],
        ),
      );
      confirming = false;
      if (accepted != true || !mounted) return;
    }
    setState(() => closing = true);
    Navigator.pop(context);
  }

  void apply() {
    if (closing || confirming) return;
    final text = expiry.text.trim();
    final at = text.isEmpty ? null : DateTime.tryParse(text);
    if (cidr.text.trim().isEmpty ||
        (text.isNotEmpty &&
            (at == null || !RegExp(r'(Z|[+-]\d\d:\d\d)$').hasMatch(text)))) {
      setState(() => error = '请输入 IP/CIDR；到期时间须为带时区的 RFC3339 或留空。');
      return;
    }
    setState(() => closing = true);
    Navigator.pop(context, <String, dynamic>{
      'id': widget.rule?['id'] ?? '',
      'cidr': cidr.text.trim(),
      'owner_label': label.text.trim(),
      'owner_user_id': ownerID,
      'remark': remark.text.trim(),
      'enabled': enabled,
      if (at != null) 'expires_at': at.toUtc().toIso8601String(),
      if (widget.rule?['owner_user_id'] == ownerID)
        'owner_status': widget.rule?['owner_status'],
    });
  }

  Widget field(String name, TextEditingController c) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: Key('public-rule-$name'),
      controller: c,
      decoration: InputDecoration(labelText: name),
      onChanged: (_) => dirty = true,
    ),
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: closing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) cancel();
    },
    child: AlertDialog(
      title: const Text('白名单规则'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              field('IP/CIDR', cidr),
              field('归属标签', label),
              DropdownButtonFormField<String>(
                initialValue: ownerID,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '人工关联账号（可选）'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('不关联账号')),
                  for (final u in widget.users)
                    DropdownMenuItem(
                      value: '${u['id']}',
                      child: Text(
                        '${u['username']} · ${u['id']}${u['disabled'] == true ? '（已停用）' : ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (ownerID.isNotEmpty &&
                      !widget.users.any((u) => u['id'] == ownerID))
                    DropdownMenuItem(
                      value: ownerID,
                      child: Text(
                        '$ownerID（未解析，保留原值）',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() {
                  ownerID = value ?? '';
                  dirty = true;
                }),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('人工归属不证明实际请求来自此账号。'),
              ),
              field('备注', remark),
              field('到期时间 RFC3339（可选）', expiry),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用规则'),
                value: enabled,
                onChanged: (value) => setState(() {
                  enabled = value == true;
                  dirty = true;
                }),
              ),
              if (error != null) Text(error!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: cancel, child: const Text('取消')),
        FilledButton(onPressed: apply, child: const Text('应用到草稿')),
      ],
    ),
  );
}
