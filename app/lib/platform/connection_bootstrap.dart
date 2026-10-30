import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../shared/theme.dart';
import 'backend.dart';
import 'backend_endpoint.dart';
import 'transport.dart';

class ConnectionBootstrap extends StatefulWidget {
  const ConnectionBootstrap({
    super.key,
    required this.initialView,
    required this.child,
    this.settingsOnly = false,
    this.frameDeferred = false,
    this.remoteOnly = false,
    this.localOnly = false,
    this.startBackend,
  });
  final String? initialView;
  final Widget child;
  final bool settingsOnly;
  final bool frameDeferred;
  final bool remoteOnly;
  final bool localOnly;
  final Future<bool> Function({String? initialView, Uri? remote})? startBackend;
  @override
  State<ConnectionBootstrap> createState() => _ConnectionBootstrapState();
}

class _ConnectionBootstrapState extends State<ConnectionBootstrap> {
  final address = TextEditingController();
  SharedPreferences? prefs;
  String? pem, boundOrigin, fingerprint, error;
  bool remote = false, busy = false, started = false, identityClaimed = false;
  bool loading = true;
  bool duplicate = false;
  @override
  void initState() {
    super.initState();
    load().catchError((Object e) {
      if (mounted) {
        setState(() {
          error = '无法读取连接设置：$e';
          loading = false;
        });
      }
      if (widget.frameDeferred) WidgetsBinding.instance.allowFirstFrame();
    });
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    prefs = p;
    address.text = p.getString('connection.address') ?? '';
    remote = p.getBool('connection.remote') ?? false;
    if (widget.remoteOnly) remote = true;
    if (widget.localOnly) remote = false;
    boundOrigin = p.getString('connection.certOrigin');
    pem = p.getString('connection.certPem');
    if (pem != null) {
      try {
        fingerprint = certFingerprint(pem!);
      } catch (_) {
        pem = null;
      }
    }
    setState(() {});
    if (!widget.settingsOnly) await connect();
    if (mounted) setState(() => loading = false);
    if (widget.frameDeferred && !duplicate) {
      WidgetsBinding.instance.allowFirstFrame();
    }
  }

  String certFingerprint(String value) {
    final match = RegExp(
      r'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----',
    ).firstMatch(value);
    if (match == null ||
        RegExp(r'-----BEGIN CERTIFICATE-----').allMatches(value).length != 1) {
      throw const FormatException('请选择单张 PEM 证书');
    }
    final der = base64Decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
    if (der.isEmpty) throw const FormatException('证书为空');
    return sha256
        .convert(der)
        .toString()
        .toUpperCase()
        .replaceAllMapped(RegExp(r'.{2}(?!$)'), (m) => '${m[0]}:');
  }

  Future<void> importCert() async {
    final uri = parseRemoteBackendEndpoint(address.text);
    if (uri == null) {
      setState(() => error = '请先填写有效的 HTTPS 地址');
      return;
    }
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'PEM 证书', extensions: ['pem', 'crt', 'cer']),
        ],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > 65536) throw const FormatException('证书文件过大');
      final value = utf8.decode(bytes);
      final hash = certFingerprint(value);
      setState(() {
        pem = value;
        boundOrigin = uri.origin;
        fingerprint = hash;
        error = null;
      });
    } catch (e) {
      setState(() => error = '证书导入失败：$e');
    }
  }

  Future<void> connect() async {
    final uri = remote ? parseRemoteBackendEndpoint(address.text) : null;
    if (remote &&
        address.text.isEmpty &&
        (widget.settingsOnly || identityClaimed)) {
      await prefs?.setBool('connection.remote', true);
      await prefs?.setString('connection.address', '');
      await prefs?.remove('connection.certOrigin');
      await prefs?.remove('connection.certPem');
      if (mounted) setState(() => error = '空地址草稿已保存；连接前请填写地址并导入证书。');
      return;
    }
    if (remote && uri == null) {
      setState(() => error = '请输入 HTTPS 地址，可包含端口，不能包含路径或凭据');
      return;
    }
    if (remote && (pem == null || boundOrigin != uri!.origin)) {
      setState(() => error = '请为此地址导入并核对证书');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!widget.localOnly) await prefs?.setBool('connection.remote', remote);
      await prefs?.setString('connection.address', address.text);
      if (remote) {
        await prefs?.setString('connection.certOrigin', boundOrigin!);
        await prefs?.setString('connection.certPem', pem!);
      }
      configureRemoteTrust(remote ? pem : null, origin: uri?.origin);
      if (widget.settingsOnly || identityClaimed) {
        setState(() => error = '设置已保存。请退出并重新打开程序以连接所选工程。');
        return;
      }
      identityClaimed = true;
      if (!await (widget.startBackend ?? startLocalBackend)(
        initialView: widget.initialView,
        remote: uri,
      )) {
        duplicate = true;
        return;
      }
      if (uri != null &&
          !await ready(
            healthUrl: uri.resolve('health'),
            timeout: const Duration(seconds: 8),
          )) {
        throw StateError('无法验证或连接远程服务，请检查地址和证书');
      }
      if (mounted) setState(() => started = true);
    } catch (e) {
      if (mounted) setState(() => error = '连接初始化失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (started) return widget.child;
    if (loading) {
      return MaterialApp(
        theme: workspaceTheme(false),
        home: const Scaffold(body: SizedBox.shrink()),
      );
    }
    return MaterialApp(
      theme: workspaceTheme(false),
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '连接设置',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (!widget.remoteOnly && !widget.localOnly)
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('本机工程')),
                          ButtonSegment(value: true, label: Text('远程工程')),
                        ],
                        selected: {remote},
                        onSelectionChanged: busy
                            ? null
                            : (v) => setState(() => remote = v.first),
                      ),
                    if (widget.remoteOnly) const Text('远程工程'),
                    if (widget.localOnly) const Text('本机工程'),
                    if (remote) ...[
                      TextField(
                        controller: address,
                        enabled: !busy,
                        decoration: const InputDecoration(
                          labelText: 'HTTPS 地址',
                          hintText: 'https://公网 IP:端口',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: busy ? null : importCert,
                        child: const Text('导入此工程的 PEM 证书'),
                      ),
                      if (fingerprint != null)
                        SelectableText(
                          '证书 SHA-256：$fingerprint\n绑定地址：$boundOrigin',
                        ),
                      const Text('请与服务端证书指纹核对；证书更新后需要重新导入。'),
                    ],
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: busy || prefs == null ? null : connect,
                      child: Text(
                        busy
                            ? '正在启动…'
                            : widget.settingsOnly || identityClaimed
                            ? '保存设置'
                            : '连接',
                      ),
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
}
