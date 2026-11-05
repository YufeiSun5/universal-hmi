import 'package:http/http.dart' as http;

bool get supported =>
    Uri.base.queryParameters['client'] == 'android' &&
    Uri.base.scheme == 'http' &&
    Uri.base.host == '127.0.0.1';
Future<String?> request(String user, String action, [String price = '']) async {
  final response = await http
      .post(
        Uri.base.resolve('/mobile/settlement-price'),
        headers: {'X-HMI-Native': 'credentials'},
        body: {'username': user, 'action': action, 'price': price},
      )
      .timeout(const Duration(seconds: 5));
  if (response.statusCode != 200) throw StateError('本机单价存储不可用');
  return response.body.isEmpty ? null : response.body;
}

Future<String?> load(String user) => request(user, 'load');
Future<void> save(String user, String price) async {
  await request(user, 'save', price);
}
