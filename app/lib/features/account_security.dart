import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/mobile_client.dart';
import 'security_page.dart';
import 'security_layout.dart';
import 'materials/signature.dart';
import 'account_home.dart';

class AccountSecurity extends StatefulWidget {
  const AccountSecurity({super.key, required this.api, this.onOpenHome});
  final SessionApi api;
  final ValueChanged<String>? onOpenHome;
  @override
  State<AccountSecurity> createState() => _AccountSecurityState();
}

class _AccountSecurityState extends State<AccountSecurity> {
  final password = TextEditingController(), next = TextEditingController();
  bool busy = false, sessionsLoaded = false, auditLoaded = false;
  String? error, message;
  List<Json> sessions = [], audit = [];
  @override
  void dispose() {
    for (final controller in [password, next]) {
      controller.clear();
      controller.dispose();
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
    final data = await widget.api.request('GET', '/api/v1/security/sessions');
    sessions = objects(data['items']);
    sessionsLoaded = true;
  });
  @override
  Widget build(BuildContext context) => SecurityForm(
    title: const Text('账号安全'),
    content: SizedBox(
      width: 820,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.api.session?.pageAccessSupported == true) ...[
              AccountHome(api: widget.api, onOpen: widget.onOpenHome),
              const SizedBox(height: 24),
            ],
            if (widget.api.session?.managedIdentity == true &&
                !isMobileProductClient()) ...[
              PersonalSignature(api: widget.api),
              const SizedBox(height: 24),
            ],
            if (busy) const LinearProgressIndicator(),
            if (error != null || message != null) ...[
              Text(
                error ?? message!,
                style: TextStyle(
                  color: error == null
                      ? null
                      : Theme.of(context).colorScheme.error,
                ),
              ),
              const SizedBox(height: 16),
            ],
            SecuritySection(
              title: '修改密码',
              description: '修改成功后，所有已登录设备需要重新登录。',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: password,
                    enabled: !busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(labelText: '当前密码'),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: next,
                    enabled: !busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: '新密码',
                      helperText:
                          '${widget.api.session?.passwordMinLength ?? 7}–128 个字符',
                    ),
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed: busy ? null : changePassword,
                      child: const Text('修改密码并撤销所有会话'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SecuritySection(
              title: '登录设备与会话',
              description: '查看登录记录，撤销不再使用的会话。',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: busy ? null : loadSessions,
                      child: const Text('查看登录会话'),
                    ),
                  ),
                  if (sessionsLoaded) ...[
                    const SizedBox(height: 16),
                    if (sessions.isEmpty) const Text('暂无登录会话'),
                    for (final session in sessions)
                      SecurityRecord(
                        title: Text('${session['started']}'),
                        subtitle: Text('最近访问：${session['last']}'),
                        trailing: SecurityDangerButton(
                          onPressed: busy
                              ? null
                              : () => run(() async {
                                  await widget.api.request(
                                    'POST',
                                    '/api/v1/security/sessions/revoke',
                                    body: {
                                      'user_id': session['user_id'],
                                      'session_id': session['id'],
                                    },
                                  );
                                  sessions.remove(session);
                                  message = '会话已撤销';
                                  await widget.api.readSession();
                                }),
                          child: const Text('撤销'),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            if (widget.api.session?.canAudit == true) ...[
              const SizedBox(height: 24),
              SecuritySection(
                title: '安全审计',
                description: '查询账号及权限操作的记录。',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => run(() async {
                                final data = await widget.api.request(
                                  'GET',
                                  '/api/v1/security/audit',
                                );
                                audit = objects(data['items']);
                                auditLoaded = true;
                              }),
                        child: const Text('查看安全审计'),
                      ),
                    ),
                    if (auditLoaded) ...[
                      const SizedBox(height: 16),
                      if (audit.isEmpty) const Text('暂无审计记录'),
                      for (final event in audit)
                        SecurityRecord(
                          title: Text(
                            '${event['action']} · ${event['result']}',
                          ),
                          subtitle: Text(
                            '${event['at']}\n${event['actor']} · ${event['target']}',
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      if (!SecurityPageScope.isRoot(context))
        TextButton(
          onPressed: busy ? null : () => Navigator.maybePop(context),
          child: const Text('关闭'),
        ),
    ],
  );
}
