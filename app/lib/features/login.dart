import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/theme.dart';
import '../platform/login_credentials.dart';
import 'login_style.dart';

/// The login route owns only transient form input, never workspace data.
class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.api,
    this.expired = false,
    this.onConnectionSettings,
    this.androidClient = false,
    this.credentialStore,
  });
  final SessionApi api;
  final bool expired;
  final bool androidClient;
  final LoginCredentialStore? credentialStore;
  final VoidCallback? onConnectionSettings;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final username = TextEditingController();
  final password = TextEditingController();
  final captchaAnswer = TextEditingController();
  String captchaId = "";
  Uint8List? captchaImage;
  bool captchaBusy = false;
  final passwordFocus = FocusNode();
  bool busy = false;
  bool showPassword = false;
  bool showHelp = false;
  String? error;
  bool approvalPending = false;
  late final LoginCredentialStore? credentialStore;
  List<String> rememberedAccounts = [];
  bool rememberPassword = false;
  bool credentialsBusy = false;
  String? credentialError;
  String filledAccount = '';

  @override
  void initState() {
    super.initState();
    credentialStore = widget.androidClient
        ? widget.credentialStore ?? createLoginCredentialStore()
        : null;
    if (credentialStore != null) restoreCredentials();
    if (widget.api.session?.captchaRequired == true) refreshCaptcha();
  }

  Future<void> restoreCredentials([String? account]) async {
    setState(() => credentialsBusy = true);
    try {
      final saved = account == null
          ? await credentialStore!.load()
          : await credentialStore!.select(account);
      if (!mounted) return;
      setState(() {
        rememberedAccounts = saved.accounts;
        credentialError = null;
        if (account != null ||
            (username.text.isEmpty && password.text.isEmpty)) {
          username.text = saved.username;
          password.text = saved.password;
          filledAccount = saved.username;
          rememberPassword = saved.password.isNotEmpty;
        }
      });
    } catch (_) {
      if (mounted) setState(() => credentialError = '无法读取本机密码，请手动登录或更新手机端');
    } finally {
      if (mounted) setState(() => credentialsBusy = false);
    }
  }

  Future<void> forgetCredentials({bool all = false}) async {
    setState(() => credentialsBusy = true);
    try {
      final saved = all
          ? await credentialStore!.clear()
          : await credentialStore!.remove(username.text.trim());
      if (!mounted) return;
      setState(() {
        rememberedAccounts = saved.accounts;
        rememberPassword = false;
        credentialError = null;
        filledAccount = '';
        if (all) password.clear();
      });
    } catch (_) {
      if (mounted) setState(() => credentialError = '清除失败，请重试；本机密码尚未清除');
    } finally {
      if (mounted) setState(() => credentialsBusy = false);
    }
  }

  Future<void> refreshCaptcha() async {
    if (captchaBusy) return;
    setState(() {
      captchaBusy = true;
      captchaId = '';
      captchaImage = null;
      captchaAnswer.clear();
    });
    try {
      final data = await widget.api.loginChallenge();
      final id = data['id'];
      final encoded = data['image_base64'];
      if (id is! String ||
          id.isEmpty ||
          encoded is! String ||
          encoded.length > 100000) {
        throw const FormatException('invalid challenge');
      }
      final bytes = base64Decode(encoded);
      if (mounted) {
        setState(() {
          captchaId = id;
          captchaImage = bytes;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '验证码加载失败，请点刷新重试');
    } finally {
      if (mounted) setState(() => captchaBusy = false);
    }
  }

  @override
  void dispose() {
    username.dispose();
    password.clear();
    password.dispose();
    captchaAnswer.dispose();
    passwordFocus.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || credentialsBusy) return;
    if (username.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => error = '请输入用户名和密码');
      return;
    }
    if (widget.api.session?.captchaRequired == true &&
        (captchaId.isEmpty || captchaAnswer.text.trim().isEmpty)) {
      setState(() => error = '请输入图形验证码');
      return;
    }
    final value = password.text;
    password.clear();
    final name = username.text.trim();
    final shouldRemember = rememberPassword;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (widget.api.session?.setupRequired == true) {
        await widget.api.setup(username.text.trim(), value);
      } else {
        await widget.api.login(
          username.text.trim(),
          value,
          captchaId: captchaId,
          captchaAnswer: captchaAnswer.text.trim(),
        );
      }
      if (credentialStore != null && shouldRemember) {
        try {
          await credentialStore!.save(name, value);
        } catch (_) {
          messenger?.showSnackBar(
            const SnackBar(content: Text('已登录，但密码未保存，请下次手动输入')),
          );
        }
      }
      if (mounted) password.clear();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        approvalPending =
            e is PlatformRequestException &&
            e.code == 'device_approval_pending';
        error = approvalPending
            ? null
            : e is PlatformRequestException && e.code == 'login_failed'
            ? '用户名或密码不正确'
            : e is PlatformRequestException && e.statusCode == 429
            ? '登录尝试过于频繁，请稍后重试'
            : e is PlatformRequestException
            ? e.toString()
            : '无法登录，请检查服务连接后重试';
      });
      if (widget.api.session?.captchaRequired == true) await refreshCaptcha();
      passwordFocus.requestFocus();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field({required String label, required Widget input}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: widget.androidClient ? 13 : 15,
          color: const Color(0xffd6e8f7),
        ),
      ),
      const SizedBox(height: 8),
      input,
    ],
  );

  @override
  Widget build(BuildContext context) {
    final setup = widget.api.session?.setupRequired == true;
    final mobile = widget.androidClient;
    return LoginBackdrop(
      mobile: mobile,
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        setup
                            ? '创建首个管理员'
                            : mobile
                            ? '欢迎登录'
                            : '用户登录',
                        style: TextStyle(
                          color: mobile ? Colors.white : LoginColors.title,
                          fontSize: mobile ? 28 : 22,
                          fontWeight: FontWeight.w600,
                          letterSpacing: mobile ? 0 : 1.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        setup
                            ? '设置您的管理账号'
                            : mobile
                            ? '安全连接现场 · 随时查看运行数据'
                            : '请输入您的用户名与密码',
                        style: const TextStyle(
                          color: LoginColors.muted,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!mobile) ...[
                  const SizedBox(width: 12),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: LoginColors.cyan),
                      gradient: const RadialGradient(
                        colors: [Color(0x4008b9ff), Color(0xf2102133)],
                      ),
                      boxShadow: const [
                        BoxShadow(color: Color(0x4700ffff), blurRadius: 12),
                      ],
                    ),
                    child: const Icon(
                      Icons.person_outline,
                      color: Color(0xff70d8ff),
                      size: 26,
                    ),
                  ),
                ],
              ],
            ),
            if (mobile)
              const SizedBox(height: 28)
            else
              const Padding(
                padding: EdgeInsets.only(top: 16, bottom: 26),
                child: Divider(height: 1, color: Color(0xff1f4265)),
              ),
            if (setup || widget.expired) ...[
              Text(
                setup
                    ? '设置${widget.api.session?.passwordMinLength ?? 7}–128个字符的密码。此账号同时具有管理员与工程师角色；设备控制须另行授权。'
                    : '会话已过期或已变更，请重新登录。未完成的操作不会自动重试。',
                style: const TextStyle(
                  color: LoginColors.muted,
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 18),
            ],
            field(
              label: '用户名',
              input: TextField(
                key: const Key('login-username'),
                controller: username,
                autofocus: !mobile,
                enabled: !busy,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                style: const TextStyle(fontSize: 16, color: Colors.white),
                decoration: InputDecoration(
                  hintText: '请输入用户名',
                  prefixIcon: const Icon(Icons.person_outline, size: 20),
                  suffixIcon: rememberedAccounts.isEmpty
                      ? null
                      : PopupMenuButton<String>(
                          tooltip: '选择已记住的账号',
                          enabled: !busy && !credentialsBusy,
                          icon: const Icon(Icons.manage_accounts_outlined),
                          onSelected: restoreCredentials,
                          itemBuilder: (_) => [
                            for (final account in rememberedAccounts)
                              PopupMenuItem(
                                value: account,
                                child: Text(account),
                              ),
                          ],
                        ),
                ),
                onChanged: (value) {
                  if (filledAccount.isNotEmpty && value != filledAccount) {
                    password.clear();
                    setState(() {
                      filledAccount = '';
                      rememberPassword = false;
                    });
                  }
                },
                onSubmitted: (_) => passwordFocus.requestFocus(),
              ),
            ),
            const SizedBox(height: 20),
            field(
              label: '密码',
              input: TextField(
                key: const Key('login-password'),
                controller: password,
                focusNode: passwordFocus,
                enabled: !busy,
                obscureText: !showPassword,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                autofillHints: [
                  setup ? AutofillHints.newPassword : AutofillHints.password,
                ],
                textInputAction: TextInputAction.done,
                style: const TextStyle(fontSize: 16, color: Colors.white),
                decoration: InputDecoration(
                  hintText: '请输入密码',
                  prefixIcon: const Icon(Icons.lock_outline, size: 19),
                  suffixIcon: IconButton(
                    tooltip: showPassword ? '隐藏密码' : '显示密码',
                    onPressed: busy
                        ? null
                        : () => setState(() => showPassword = !showPassword),
                    icon: Icon(
                      showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                    ),
                  ),
                ),
                onSubmitted: (_) => submit(),
              ),
            ),
            if (credentialStore != null && !setup) ...[
              const SizedBox(height: 8),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        key: const Key('login-remember-password'),
                        value: rememberPassword,
                        onChanged: busy || credentialsBusy
                            ? null
                            : (value) {
                                if (value == false) {
                                  forgetCredentials();
                                } else {
                                  setState(() => rememberPassword = true);
                                }
                              },
                      ),
                      const Text(
                        '记住密码',
                        style: TextStyle(color: LoginColors.title),
                      ),
                    ],
                  ),
                  if (rememberedAccounts.isNotEmpty)
                    TextButton(
                      onPressed: busy || credentialsBusy
                          ? null
                          : () => forgetCredentials(all: true),
                      child: const Text('清除全部已记住密码'),
                    ),
                ],
              ),
              Text(
                credentialError ?? '密码仅加密保存在本机，可选择已记住账号切换登录',
                style: TextStyle(
                  color: credentialError == null
                      ? LoginColors.muted
                      : Colors.orangeAccent,
                  fontSize: 12,
                ),
              ),
            ],
            if (widget.api.session?.captchaRequired == true && !setup) ...[
              const SizedBox(height: 20),
              field(
                label: '图形验证码',
                input: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('login-captcha'),
                        controller: captchaAnswer,
                        enabled: !busy,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.number,
                        maxLength: 5,
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white,
                        ),
                        decoration: const InputDecoration(
                          hintText: '输入图片数字',
                          counterText: '',
                        ),
                        onSubmitted: (_) => submit(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 140,
                      height: 48,
                      child: InkWell(
                        key: const Key('login-captcha-refresh'),
                        onTap: busy || captchaBusy ? null : refreshCaptcha,
                        child: Semantics(
                          button: true,
                          label: '刷新图形验证码',
                          child: captchaImage == null
                              ? Center(
                                  child: Text(
                                    captchaBusy ? '加载中…' : '点此刷新',
                                    style: const TextStyle(
                                      color: LoginColors.title,
                                    ),
                                  ),
                                )
                              : ColoredBox(
                                  color: Colors.white,
                                  child: Image.memory(
                                    captchaImage!,
                                    fit: BoxFit.contain,
                                    excludeFromSemantics: true,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '看不清？点击图片刷新 · 2分钟内有效',
                style: TextStyle(color: LoginColors.muted, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 14,
                      color: LoginColors.title,
                    ),
                    SizedBox(width: 6),
                    Text(
                      '仅限授权人员访问',
                      style: TextStyle(color: LoginColors.muted, fontSize: 12),
                    ),
                  ],
                ),
                if (!setup)
                  TextButton(
                    onPressed: () => setState(() => showHelp = !showHelp),
                    child: const Text('忘记密码？'),
                  ),
              ],
            ),
            if (showHelp && !setup)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: const BoxDecoration(
                  color: LoginColors.field,
                  border: Border(
                    left: BorderSide(color: LoginColors.cyan, width: 2),
                  ),
                ),
                child: const Text(
                  '请联系系统管理员重置密码。',
                  style: TextStyle(color: LoginColors.muted, fontSize: 13),
                ),
              ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  error!,
                  style: const TextStyle(
                    color: LoginColors.warning,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
            if (approvalPending) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: const Text(
                  '设备正在审批，请等待管理员批准。批准后重新登录即可。',
                  key: Key('device-approval-pending'),
                  style: TextStyle(color: LoginColors.cyan, fontSize: 14),
                ),
              ),
            ],
            const SizedBox(height: 24),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: mobile
                      ? const [Color(0xff348add), Color(0xff256bb5)]
                      : const [Color(0xff0b6d99), Color(0xff045174)],
                ),
                border: mobile ? null : Border.all(color: LoginColors.cyan),
                borderRadius: BorderRadius.circular(mobile ? 14 : 2),
              ),
              child: FilledButton(
                key: const Key('login-submit'),
                onPressed: busy ? null : submit,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  disabledBackgroundColor: Colors.transparent,
                  foregroundColor: Colors.white,
                  disabledForegroundColor: LoginColors.muted,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(mobile ? 14 : 2),
                  ),
                  textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: 16,
                    letterSpacing: mobile ? 0 : 3,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      busy
                          ? '正在处理…'
                          : setup
                          ? '创建并登录'
                          : '登录',
                    ),
                    const SizedBox(width: 18),
                    if (busy)
                      const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    else
                      const Icon(Icons.arrow_forward, size: 20),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 13),
            if (widget.onConnectionSettings != null)
              TextButton(
                onPressed: widget.onConnectionSettings,
                child: const Text('连接设置'),
              ),
            if (!mobile)
              const Text(
                '智慧供热集中监控系统',
                style: TextStyle(color: LoginColors.muted, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

class SessionLoadingScreen extends StatelessWidget {
  const SessionLoadingScreen({
    super.key,
    this.error,
    required this.onRetry,
    this.onConnectionSettings,
  });
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback? onConnectionSettings;

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
              if (onConnectionSettings != null)
                TextButton(
                  onPressed: onConnectionSettings,
                  child: const Text('连接设置'),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}
