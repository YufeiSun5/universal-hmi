import 'dart:js_interop';

import 'package:http/http.dart' as http;

@JS('hmiWebWorkspace')
external JSString? get _webWorkspace;

// Use the same entry selected by hmi_start.js for sign-in, ordinary requests
// and long-lived subscriptions. Android and KP use their own transports.
http.Client newTransport() => _WebTransport();
void configureRemoteTrust(String? pem, {String? origin}) {}

class _WebTransport extends http.BaseClient {
  final _client = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final workspace = _webWorkspace?.toDart;
    if (workspace != null && request.url.origin == Uri.base.origin) {
      request.headers['X-HMI-Workspace'] = workspace;
    }
    return _client.send(request);
  }

  @override
  void close() => _client.close();
}
