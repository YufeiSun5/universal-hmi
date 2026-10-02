import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/platform/backend_native.dart';

void main() {
  test(
    'Health requires service identity, valid bounded JSON and status',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final replies = [
        '{"status":"ok"}',
        '{"status":"ok","service":"other"}',
        '{bad}',
        '{"status":"ok","service":"universal-hmi"}',
      ];
      server.listen((request) {
        request.response.write(replies.removeAt(0));
        request.response.close();
      });
      final url = Uri.parse('http://127.0.0.1:${server.port}/health');
      try {
        expect(await ready(healthUrl: url), false);
        expect(await ready(healthUrl: url), false);
        expect(await ready(healthUrl: url), false);
        expect(await ready(healthUrl: url), true);
      } finally {
        await server.close(force: true);
      }
    },
  );
  test('Health deadline covers a stalled body', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response.write('{');
      unawaited(request.response.flush());
    });
    try {
      expect(
        await ready(
          healthUrl: Uri.parse('http://127.0.0.1:${server.port}/health'),
          timeout: const Duration(milliseconds: 50),
        ),
        false,
      );
    } finally {
      await server.close(force: true);
    }
  });
}
