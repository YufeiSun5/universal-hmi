import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/theme.dart';

/// The login route owns only transient form input, never workspace data.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api, this.expired = false});
  final SessionApi api;
  final bool expired;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final username = TextEditingController();
  final password = TextEditingController();
  final passwordFocus = FocusNode();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    username.dispose();
    password.clear();
    password.dispose();
    passwordFocus.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy) return;
    if (username.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => error = '请输入用户名和密码');
      return;
    }
    final value = password.text;
    password.clear();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.login(username.text.trim(), value);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        error = e is PlatformRequestException && e.statusCode == 401
            ? '用户名或密码不正确'
            : e is PlatformRequestException && e.statusCode == 429
            ? '登录尝试过于频繁，请稍后重试'
            : '无法登录，请检查服务连接后重试';
      });
      passwordFocus.requestFocus();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: WorkbenchColors.chrome,
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: WorkbenchColors.paper,
              border: Border.all(color: WorkbenchColors.line),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.hub_outlined,
                        color: WorkbenchColors.accent,
                        size: 22,
                      ),
                      SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Universal HMI',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '登录工作空间',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.expired
                        ? '会话已过期或已变更，请重新登录。未完成的操作不会自动重试。'
                        : '使用管理员配置的账户登录',
                    style: const TextStyle(color: WorkbenchColors.muted),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    key: const Key('login-username'),
                    controller: username,
                    autofocus: true,
                    enabled: !busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: '用户名'),
                    onSubmitted: (_) => passwordFocus.requestFocus(),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    key: const Key('login-password'),
                    controller: password,
                    focusNode: passwordFocus,
                    enabled: !busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(labelText: '密码'),
                    onSubmitted: (_) => submit(),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton(
                    key: const Key('login-submit'),
                    onPressed: busy ? null : submit,
                    child: Text(busy ? '正在登录…' : '登录'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class SessionLoadingScreen extends StatelessWidget {
  const SessionLoadingScreen({super.key, this.error, required this.onRetry});
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.hub_outlined,
              color: WorkbenchColors.accent,
              size: 28,
            ),
            const SizedBox(height: 16),
            Text(error == null ? '正在检查登录状态…' : '无法检查登录状态，请确认服务可用后重试'),
            if (error != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    ),
  );
}
