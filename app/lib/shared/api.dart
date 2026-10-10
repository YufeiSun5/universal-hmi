import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'
    show ChangeNotifier, Listenable, compute, kIsWeb;
import 'package:http/http.dart' as http;
import '../platform/kp.dart';

typedef Json = Map<String, dynamic>;
List<Json> objects(dynamic value) => (value as List? ?? [])
    .map((v) => Map<String, dynamic>.from(v as Map))
    .toList();

/// Immutable runtime views avoid cloning each of the 15,000 snapshot maps.
/// Editable configurations continue to use objects() for defensive copies.
List<Json> snapshotObjects(dynamic value) => (value as List? ?? const [])
    .map((v) => v is Json ? v : Map<String, dynamic>.from(v as Map))
    .toList(growable: false);
Json _decodeObject(Uint8List bytes) =>
    Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
Future<Json> decodeResponseObject(Uint8List bytes) async {
  if (!kIsWeb && bytes.length >= 256 * 1024) {
    return compute(_decodeObject, bytes, debugLabel: 'HMI JSON response');
  }
  return _decodeObject(bytes);
}

class PlatformRequestException implements Exception {
  const PlatformRequestException(this.statusCode, this.message, {this.code});
  final int statusCode;
  final String message;
  final String? code;
  @override
  String toString() => message;
}

abstract interface class PlatformApi {
  Future<Json> request(String method, String path, {Object? body, Json? query});
  Future<Json> upload(String name, Uint8List bytes);
  Future<Uint8List> download(String id);
  void close();
}

/// Standalone Web sessions use HttpOnly cookies. The KP entry instead keeps its
/// per-window bearer in sessionStorage, preventing shared-cookie user mixing.
class AuthSession {
  const AuthSession({
    required this.enabled,
    required this.authenticated,
    this.username = '',
    this.canWrite = false,
    this.csrfToken = '',
    this.expiresAt,
    this.expired = false,
    this.kpState = '',
  });

  factory AuthSession.fromJson(Json data, {bool requireCsrf = true}) {
    if (data['enabled'] is! bool ||
        (data['enabled'] == true && data['authenticated'] is! bool)) {
      throw const FormatException('服务器返回了无效的会话信息');
    }
    final enabled = data['enabled'] == true;
    final authenticated = data['authenticated'] == true;
    final csrf = data['csrf_token']?.toString() ?? '';
    final expires = DateTime.tryParse(data['expires_at']?.toString() ?? '');
    if (enabled &&
        authenticated &&
        ((requireCsrf && csrf.isEmpty) || expires == null)) {
      throw const FormatException('服务器返回了不完整的会话信息');
    }
    return AuthSession(
      enabled: enabled,
      authenticated: authenticated,
      username: data['username']?.toString() ?? '',
      canWrite: !enabled || data['can_write'] == true,
      csrfToken: csrf,
      expiresAt: expires,
      kpState: data['state']?.toString() ?? '',
    );
  }

  final bool enabled, authenticated, canWrite, expired;
  final String username, csrfToken;
  final String kpState;
  final DateTime? expiresAt;
  bool get allowsWorkspace => !enabled || authenticated;
}

abstract interface class SessionApi implements PlatformApi, Listenable {
  AuthSession? get session;
  int get sessionGeneration;
  bool get kpEmbedded;
  String? get kpError;
  Future<void> readSession();
  Future<void> login(String username, String password);
  Future<void> logout();

  /// A retired workspace cannot make requests using a later user's session.
  PlatformApi scoped();
}

class PlatformClient extends ChangeNotifier implements SessionApi {
  PlatformClient(this.base, {http.Client? client, KpEnvironment? kpEnvironment})
    : _client = client ?? http.Client(),
      _kp = kpEnvironment ?? createKpEnvironment();
  final Uri base;
  final http.Client _client;
  AuthSession? _session;
  String? _bearerToken;
  int _generation = 0;
  bool _closed = false, _authBusy = false;
  Timer? _expiry;
  final KpEnvironment _kp;
  Timer? _kpStatusTimer;
  bool _kpStatusBusy = false, _kpLogoutRequested = false;
  String? _kpError;
  @override
  bool get kpEmbedded => _kp.embedded;
  @override
  String? get kpError => _kpError;

  @override
  AuthSession? get session => _session;
  @override
  int get sessionGeneration => _generation;
  @override
  PlatformApi scoped() => _SessionScope(this, _generation);

  Uri uri(String path, Json? query) => base
      .resolve(path)
      .replace(queryParameters: query?.map((k, v) => MapEntry(k, '$v')));

  void _ensureCurrent(int generation, {bool authentication = false}) {
    if (_closed || generation != _generation) {
      throw const PlatformRequestException(401, '会话已变更，请重新登录');
    }
    if (!authentication &&
        (_session?.allowsWorkspace == false ||
            (kpEmbedded && _session?.authenticated != true))) {
      throw const PlatformRequestException(401, '请先登录');
    }
    if (!authentication && _authBusy) {
      throw const PlatformRequestException(409, '正在更新会话，请稍候');
    }
  }

  void _setSession(AuthSession next) {
    if (_closed) return;
    _expiry?.cancel();
    _generation++;
    _session = next;
    if (next.enabled && next.authenticated && next.expiresAt != null) {
      final remaining = next.expiresAt!.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        _expire();
        return;
      }
      _expiry = Timer(remaining, _expire);
    }
    notifyListeners();
  }

  void _expire() {
    if (_closed || _session?.expired == true) return;
    if (kpEmbedded) {
      _terminalKp('expired');
      return;
    }
    _bearerToken = null;
    _setSession(
      const AuthSession(enabled: true, authenticated: false, expired: true),
    );
  }

  Future<http.Response> _send(
    http.BaseRequest request,
    int generation, {
    bool authentication = false,
  }) async {
    _ensureCurrent(generation, authentication: authentication);
    // Never follow a server redirect with credentials or mutation payloads.
    request.followRedirects = false;
    if ((!kIsWeb || kpEmbedded) && _bearerToken != null) {
      request.headers['Authorization'] = 'Bearer $_bearerToken';
    }
    if (!['GET', 'HEAD', 'OPTIONS'].contains(request.method.toUpperCase()) &&
        _session?.csrfToken.isNotEmpty == true) {
      request.headers['X-CSRF-Token'] = _session!.csrfToken;
    }
    final response = await _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 35));
    _ensureCurrent(generation, authentication: authentication);
    if (response.statusCode >= 300) {
      String message = '请求失败 (${response.statusCode})';
      String? code;
      try {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Json;
        final error = data['error'] as Json?;
        message = (error?['message'] ?? message).toString();
        code = error?['code']?.toString();
      } catch (_) {}
      // Another browser tab can rotate the shared cookie while this tab still
      // holds the previous CSRF token. Retire it, but never replay the mutation.
      if ((response.statusCode == 401 && !authentication) ||
          (response.statusCode == 403 && code == 'csrf_rejected')) {
        _expire();
      }
      throw PlatformRequestException(response.statusCode, message, code: code);
    }
    return response;
  }

  Future<Json> _request(
    String method,
    String path,
    int generation, {
    Object? body,
    Json? query,
    bool authentication = false,
  }) async {
    final request = http.Request(method, uri(path, query));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await _send(
      request,
      generation,
      authentication: authentication,
    );
    final result = await decodeResponseObject(response.bodyBytes);
    _ensureCurrent(generation, authentication: authentication);
    return result;
  }

  Future<void> _authenticate(Future<void> Function(int) work) async {
    if (_authBusy) {
      throw const PlatformRequestException(409, '正在更新会话，请稍候');
    }
    if (_closed) throw const PlatformRequestException(401, '客户端已关闭');
    _authBusy = true;
    try {
      await work(_generation);
    } finally {
      _authBusy = false;
    }
  }

  @override
  Future<void> readSession() => kpEmbedded
      ? _readKpSession()
      : _authenticate((generation) async {
          final data = await _request(
            'GET',
            '/api/v1/auth/session',
            generation,
            authentication: true,
          );
          _setSession(AuthSession.fromJson(data, requireCsrf: kIsWeb));
        });

  @override
  Future<void> login(String username, String password) =>
      _authenticate((generation) async {
        if (kpEmbedded) throw const PlatformRequestException(401, '请从 KP 登录');
        final data = await _request(
          'POST',
          '/api/v1/auth/login',
          generation,
          body: {
            'username': username,
            'password': password,
            if (!kIsWeb) 'issue_token': true,
          },
          authentication: true,
        );
        final next = AuthSession.fromJson(data, requireCsrf: kIsWeb);
        if (!next.allowsWorkspace) {
          throw const PlatformRequestException(401, '登录未成功，请重试');
        }
        if (!kIsWeb && next.enabled) {
          final token = data['bearer_token'];
          if (token is! String || token.isEmpty) {
            throw const FormatException('服务器未返回桌面会话凭证');
          }
          _bearerToken = token;
        }
        _setSession(next);
      });

  @override
  Future<void> logout() => kpEmbedded
      ? _logoutKp()
      : _authenticate((generation) async {
          try {
            await _request(
              'POST',
              '/api/v1/auth/logout',
              generation,
              authentication: true,
            );
          } on PlatformRequestException catch (e) {
            if (e.statusCode != 401) rethrow;
          }
          _bearerToken = null;
          _setSession(const AuthSession(enabled: true, authenticated: false));
        });

  void _hideKp(String state) {
    _setSession(
      AuthSession(
        enabled: true,
        authenticated: false,
        expired: state == 'expired',
        kpState: state,
      ),
    );
  }

  void _terminalKp(String state) {
    _kpStatusTimer?.cancel();
    _kpStatusTimer = null;
    _bearerToken = null;
    _kp.writeToken(null);
    _kp.writeLogoutRequested(false);
    _kpLogoutRequested = false;
    _hideKp(state);
  }

  void _acceptKp(Json data) {
    final state = data['state']?.toString();
    if (!const [
      'active',
      'logout_requested',
      'closed',
      'expired',
    ].contains(state)) {
      throw const FormatException('服务器返回了无效的 KP 会话状态');
    }
    _kpError = null;
    if (state == 'active' &&
        (data['enabled'] != true || data['authenticated'] != true)) {
      throw const FormatException('服务器返回了不完整的 KP 会话信息');
    }
    if (state == 'closed' || state == 'expired') {
      _terminalKp(state!);
    } else if (state == 'logout_requested') {
      _kpLogoutRequested = true;
      _kp.writeLogoutRequested(true);
      if (_session?.kpState != state) {
        _hideKp(state!);
      }
    } else if (_kpLogoutRequested) {
      if (_session?.kpState != 'logout_unconfirmed') {
        _hideKp('logout_unconfirmed');
      }
    } else if (_session?.authenticated != true) {
      _setSession(AuthSession.fromJson(data, requireCsrf: false));
    }
  }

  Future<void> _readKpSession() async {
    if (_closed || _authBusy) return;
    _authBusy = true;
    try {
      final ticket = _kp.takeTicket();
      if (ticket != null) {
        _kpLogoutRequested = false;
        _kp.writeLogoutRequested(false);
        _bearerToken = null;
        _kp.writeToken(null);
        _hideKp('connecting');
        final data = await _request(
          'POST',
          '/api/v1/web/redeem',
          _generation,
          body: {'ticket': ticket},
          authentication: true,
        );
        final token = data['webToken'];
        if (token is! String || token.length != 43) {
          throw const FormatException('服务器未返回 KP 会话凭证');
        }
        _bearerToken = token;
        _kp.writeToken(token);
        _acceptKp(data);
      } else {
        _kpLogoutRequested = _kpLogoutRequested || _kp.readLogoutRequested();
        _bearerToken ??= _kp.readToken();
        if (_bearerToken == null) {
          if (!const ['closed', 'expired'].contains(_session?.kpState)) {
            _hideKp('requires_entry');
          }
          return;
        }
        final data = await _request(
          'GET',
          '/api/v1/web/status',
          _generation,
          authentication: true,
        );
        _acceptKp(data);
      }
      if (_bearerToken != null) {
        _kpStatusTimer ??= Timer.periodic(
          const Duration(seconds: 2),
          (_) => pollKpStatus(),
        );
      }
    } catch (e) {
      _kpError = e.toString();
      if (e is PlatformRequestException &&
          [401, 403, 410].contains(e.statusCode)) {
        _terminalKp('expired');
      } else {
        _hideKp('unavailable');
      }
    } finally {
      _authBusy = false;
    }
  }

  /// Status never renews the KP lease. Only the host's authenticated poll does.
  Future<void> pollKpStatus() async {
    if (_closed ||
        !kpEmbedded ||
        _bearerToken == null ||
        _kpStatusBusy ||
        _authBusy) {
      return;
    }
    _kpStatusBusy = true;
    final generation = _generation;
    try {
      final data = await _request(
        'GET',
        '/api/v1/web/status',
        generation,
        authentication: true,
      );
      _acceptKp(data);
    } catch (e) {
      if (_closed || generation != _generation) return;
      _kpError = e.toString();
      if (e is PlatformRequestException && [401, 410].contains(e.statusCode)) {
        _terminalKp('expired');
      } else {
        _hideKp(_kpLogoutRequested ? 'logout_unconfirmed' : 'unavailable');
      }
    } finally {
      _kpStatusBusy = false;
    }
  }

  Future<void> _logoutKp() async {
    if (_closed || _authBusy || _bearerToken == null) return;
    _authBusy = true;
    _kpLogoutRequested = true;
    _kp.writeLogoutRequested(true);
    _hideKp('logout_submitting');
    try {
      final data = await _request(
        'POST',
        '/api/v1/web/logout',
        _generation,
        body: {},
        authentication: true,
      );
      _acceptKp(data);
    } catch (e) {
      _kpError = e.toString();
      _hideKp('logout_unconfirmed');
    } finally {
      _authBusy = false;
    }
  }

  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) => _request(method, path, _generation, body: body, query: query);

  Future<Json> _upload(String name, Uint8List bytes, int generation) async {
    final request = http.MultipartRequest(
      'POST',
      uri('/api/v1/import/upload', null),
    );
    request.files.add(
      http.MultipartFile.fromBytes('file', bytes, filename: name),
    );
    final response = await _send(request, generation);
    final result = await decodeResponseObject(response.bodyBytes);
    _ensureCurrent(generation);
    return result;
  }

  @override
  Future<Json> upload(String name, Uint8List bytes) =>
      _upload(name, bytes, _generation);

  Future<Uint8List> _download(String id, int generation) async {
    final response = await _send(
      http.Request('GET', uri('/api/v1/jobs/$id/file', null)),
      generation,
    );
    _ensureCurrent(generation);
    return response.bodyBytes;
  }

  @override
  Future<Uint8List> download(String id) => _download(id, _generation);

  @override
  void close() {
    _kpStatusTimer?.cancel();
    _kp.close();
    if (_closed) return;
    _closed = true;
    _generation++;
    _expiry?.cancel();
    _session = null;
    _bearerToken = null;
    _client.close();
    super.dispose();
  }
}

class _SessionScope implements PlatformApi {
  const _SessionScope(this.client, this.generation);
  final PlatformClient client;
  final int generation;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) => client._request(method, path, generation, body: body, query: query);
  @override
  Future<Json> upload(String name, Uint8List bytes) =>
      client._upload(name, bytes, generation);
  @override
  Future<Uint8List> download(String id) => client._download(id, generation);
  @override
  void close() {} // The app owns the shared transport, not a workspace lease.
}

String number(dynamic value) {
  if (value == null) return '—';
  if (value is num) {
    return value.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
  }
  return '$value';
}

String clock(dynamic value) {
  final date = DateTime.tryParse('$value');
  if (date == null || date.year < 2000) return '—';
  return date
      .toLocal()
      .toIso8601String()
      .replaceFirst('T', ' ')
      .substring(0, 19);
}
