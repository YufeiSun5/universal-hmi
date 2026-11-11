import 'package:http/http.dart' as http;
import 'overview_preferences_types.dart';

OverviewPreferenceStore? createOverviewPreferenceStore() {
  if (Uri.base.queryParameters['client'] != 'android' ||
      Uri.base.scheme != 'http' ||
      Uri.base.host != '127.0.0.1') {
    return null;
  }
  return _AndroidOverviewPreferences();
}

class _AndroidOverviewPreferences implements OverviewPreferenceStore {
  final endpoint = Uri.base.resolve('/mobile/overview-preferences');
  Future<Map<String, String>> request(Map<String, String> body) async {
    final response = await http
        .post(endpoint, headers: {'X-HMI-Native': 'overview'}, body: body)
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) throw StateError('本机总览偏好不可用');
    return Uri.splitQueryString(response.body);
  }

  @override
  Future<OverviewPosition> load(String username) async {
    final value = await request({'action': 'load', 'username': username});
    return OverviewPosition(
      row: value['row'] ?? '',
      group: value['group'] ?? '',
      table: value['table'] == 'true',
    );
  }

  @override
  Future<void> save(String username, OverviewPosition position) async {
    await request({
      'action': 'save',
      'username': username,
      'row': position.row,
      'group': position.group,
      'table': '${position.table}',
    });
  }
}
