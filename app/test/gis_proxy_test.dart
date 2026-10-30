import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/platform/gis_proxy_native.dart';
import 'package:universal_hmi/platform/transport_native.dart';

void main() {
  test('GIS proxy restricts methods, paths and redirects', () async {
    configureRemoteTrust(null);
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = <String>[];
    upstream.listen((r) async {
      seen.add(r.uri.path);
      if (r.uri.path.endsWith('redirect')) {
        r.response.statusCode = 302;
        r.response.headers.set('location', '/api/v1/secret');
      } else {
        r.response.write('ok');
      }
      await r.response.close();
    });
    final proxy = await GisResourceProxy.start(
      Uri.parse('http://127.0.0.1:${upstream.port}/'),
    );
    final client = HttpClient();
    Future<int> request(String method, Uri url) async {
      final req = await client.openUrl(method, url);
      req.followRedirects = false;
      final response = await req.close();
      await response.drain<void>();
      return response.statusCode;
    }

    try {
      expect(await request('GET', proxy.base.resolve('map.html')), 200);
      expect(await request('POST', proxy.base.resolve('map.html')), 404);
      expect(await request('GET', proxy.base.resolve('redirect')), 502);
      expect(await request('GET', proxy.base.resolve('/api/v1/secret')), 404);
      expect(seen, ['/gis/map.html', '/gis/redirect']);
    } finally {
      client.close(force: true);
      await proxy.close();
      await upstream.close(force: true);
    }
  });
}
