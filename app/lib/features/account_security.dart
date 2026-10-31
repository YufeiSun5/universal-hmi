import 'package:flutter/material.dart';
import '../shared/api.dart';

class AccountSecurity extends StatefulWidget {
  const AccountSecurity({
    super.key,
    required this.api,
    this.requiredEnrollment = false,
  });
  final SessionApi api;
  final bool requiredEnrollment;
  @override
  State<AccountSecurity> createState() => _AccountSecurityState();
}

class _AccountSecurityState extends State<AccountSecurity> {
  final password = TextEditingController(),
      next = TextEditingController(),
      code = TextEditingController();
  bool busy = false;
  String? secret, error, message;
  List<String> recovery = [];
  List<Json> sessions = [];
  List<Json> audit = [];
  @override
  void dispose() {
    for (final c in [password, next, code]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function() work) async {
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) error = e.toString();
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> begin() => run(() async {
    final r = await widget.api.request(
      'POST',
      '/api/v1/security/mfa/begin',
      body: {'password': password.text},
    );
    password.clear();
    secret = r['secret'] as String;
  });
  Future<void> confirm() => run(() async {
    final r = await widget.api.request(
      'POST',
      '/api/v1/security/mfa/confirm',
      body: {'code': code.text.trim()},
    );
    code.clear();
    secret = null;
    recovery = (r['recovery_codes'] as List).cast<String>();
  });
  Future<void> changePassword() => run(() async {
    await widget.api.request(
      'POST',
      '/api/v1/security/password',
      body: {'current_password': password.text, 'new_password': next.text},
    );
    password.clear();
    next.clear();
    await widget.api.readSession();
  });
  Future<void> loadSessions() => run(() async {
    final r = await widget.api.request('GET', '/api/v1/security/sessions');
    sessions = objects(r['items']);
  });
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.requiredEnrollment ? '绑定双因素验证器' : '账号安全'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.requiredEnrollment)
              const Text('此服务要求双因素登录。完成绑定后才能进入工作空间。'),
            if (recovery.isNotEmpty) ...[
              const Text('绑定成功。请将以下恢复码保存在安全位置；每个只能使用一次，关闭后不再显示。'),
              const SizedBox(height: 12),
              SelectableText(recovery.join('\n')),
            ] else if (secret != null) ...[
              const Text('在验证器中手动添加账号：类型选择基于时间（TOTP），6位，30秒。密钥：'),
              const SizedBox(height: 12),
              SelectableText(secret!),
              TextField(
                controller: code,
                decoration: const InputDecoration(labelText: '验证器显示的6位验证码'),
                onSubmitted: (_) => busy ? null : confirm(),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : confirm,
                child: const Text('确认绑定'),
              ),
            ] else ...[
              TextField(
                controller: password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '当前密码'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: busy ? null : begin,
                child: const Text('绑定验证器'),
              ),
              if (!widget.requiredEnrollment) ...[
                if (widget.api.session?.canAudit == true) ...[
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            final r = await widget.api.request(
                              'GET',
                              '/api/v1/security/audit',
                            );
                            audit = objects(r['items']);
                          }),
                    child: const Text('查看安全审计'),
                  ),
                  for (final event in audit)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${event['action']} · ${event['result']}'),
                      subtitle: Text(
                        '${event['at']}\n${event['actor']} · ${event['target']}',
                      ),
                    ),
                ],
                const Divider(height: 28),
                TextField(
                  controller: next,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText:
                        '新密码（${widget.api.session?.passwordMinLength ?? 7}–128字符）',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: busy ? null : changePassword,
                  child: const Text('修改密码并撤销所有会话'),
                ),
                const Divider(height: 28),
                OutlinedButton(
                  onPressed: busy ? null : loadSessions,
                  child: const Text('查看登录会话'),
                ),
                for (final s in sessions)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(s['started'].toString()),
                    subtitle: Text('最近访问：${s['last']}'),
                    trailing: TextButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              await widget.api.request(
                                'POST',
                                '/api/v1/security/sessions/revoke',
                                body: {
                                  'user_id': s['user_id'],
                                  'session_id': s['id'],
                                },
                              );
                              sessions.remove(s);
                              message = '会话已撤销';
                              await widget.api.readSession();
                            }),
                      child: const Text('撤销'),
                    ),
                  ),
              ],
            ],
            if (busy) const LinearProgressIndicator(),
            if (message != null) Text(message!),
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
      if (!widget.requiredEnrollment)
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      if (widget.requiredEnrollment && recovery.isEmpty)
        TextButton(
          onPressed: busy ? null : widget.api.logout,
          child: const Text('退出登录'),
        ),
      if (recovery.isNotEmpty)
        FilledButton(
          onPressed: busy ? null : widget.api.readSession,
          child: const Text('已保存恢复码，继续'),
        ),
    ],
  );
}
