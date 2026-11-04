import 'package:http/http.dart' as http;
import 'login_credentials_types.dart';

LoginCredentialStore? createLoginCredentialStore() {
  if (Uri.base.queryParameters['client'] != 'android' ||
      Uri.base.scheme != 'http' ||
      Uri.base.host != '127.0.0.1') {
    return null;
  }
  return _AndroidCredentials();
}

class _AndroidCredentials implements LoginCredentialStore {
  final endpoint = Uri.base.resolve('/mobile/login-credentials');
  Future<RememberedLogin> request([Map<String, String>? body]) async {
    const headers = {'X-HMI-Native': 'credentials'};
    final response =
        await (body == null
                ? http.get(endpoint, headers: headers)
                : http.post(endpoint, headers: headers, body: body))
            .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) throw StateError('本机安全存储不可用');
    final values = Uri.splitQueryString(response.body);
    return RememberedLogin(
      accounts: (values['accounts'] ?? '')
          .split('\n')
          .where((s) => s.isNotEmpty)
          .toList(),
      username: values['username'] ?? '',
      password: values['password'] ?? '',
    );
  }

  @override
  Future<RememberedLogin> load() => request();
  @override
  Future<RememberedLogin> select(String username) =>
      request({'action': 'select', 'username': username});
  @override
  Future<RememberedLogin> save(String username, String password) =>
      request({'action': 'save', 'username': username, 'password': password});
  @override
  Future<RememberedLogin> remove(String username) =>
      request({'action': 'remove', 'username': username});
  @override
  Future<RememberedLogin> clear() => request({'action': 'clear'});
}
