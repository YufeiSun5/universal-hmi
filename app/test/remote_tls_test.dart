import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/platform/transport_native.dart';

void main() {
  Future<bool> check(String server, String trust, String host) async {
    final ctx = SecurityContext()
      ..useCertificateChain('test/fixtures/tls/$server.pem')
      ..usePrivateKey('test/fixtures/tls/$server-key.pem');
    final listener = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      ctx,
    );
    listener.listen((r) async {
      r.response.write('ok');
      await r.response.close();
    });
    configureRemoteTrust(
      await File('test/fixtures/tls/$trust.pem').readAsString(),
      origin: 'https://$host:${listener.port}',
    );
    final client = newHttpTransport()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      final request = await client.getUrl(
        Uri.parse('https://$host:${listener.port}/'),
      );
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
      await listener.close(force: true);
      configureRemoteTrust(null);
    }
  }

  test(
    'remote TLS requires trusted certificate, correct host and validity',
    () async {
      expect(await check('valid', 'valid', '127.0.0.1'), true);
      expect(await check('valid', 'other', '127.0.0.1'), false);
      expect(await check('valid', 'valid', 'localhost'), false);
      expect(await check('expired', 'expired', '127.0.0.1'), false);
      // A trusted CA can validate the TLS chain, but is not the pinned leaf.
      expect(await check('signed', 'ca', '127.0.0.1'), false);
    },
  );
}
