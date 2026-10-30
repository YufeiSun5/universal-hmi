import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'transport_native.dart';

class GisResourceProxy {
  GisResourceProxy._(this.server, this.client, this.base);
  final HttpServer server;
  final HttpClient client;
  final Uri base;
  static Future<GisResourceProxy> start(Uri upstream) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = newHttpTransport()
      ..connectionTimeout = const Duration(seconds: 12);
    final random = Random.secure();
    final token = List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final base = Uri.parse('http://127.0.0.1:${server.port}/$token/gis/');
    final proxy = GisResourceProxy._(server, client, base);
    server.listen((req) async {
      try {
        final raw = req.uri.toString();
        final path = req.uri.path;
        if ((req.method != 'GET' && req.method != 'HEAD') ||
            !path.startsWith('/$token/gis/') ||
            raw.contains('%') ||
            path.split('/').any((part) => part == '.' || part == '..') ||
            path.contains('\\')) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        final relative = path.substring('/$token/gis/'.length);
        if (relative.isEmpty ||
            !RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(relative)) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        final target = upstream.resolve('gis/$relative');
        final outbound = await client
            .openUrl(req.method, target)
            .timeout(const Duration(seconds: 12));
        outbound.followRedirects = false;
        final response = await outbound.close().timeout(
          const Duration(seconds: 12),
        );
        if (response.statusCode != 200 || response.contentLength > 67108864) {
          req.response.statusCode = 502;
          await req.response.close();
          return;
        }
        if (response.headers.contentType != null) {
          req.response.headers.contentType = response.headers.contentType;
        }
        req.response.headers.set(
          'Content-Security-Policy',
          "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self'; object-src 'none'; form-action 'none'; base-uri 'none'",
        );
        req.response.headers.set('X-Content-Type-Options', 'nosniff');
        var size = 0;
        await for (final chunk in response.timeout(
          const Duration(seconds: 20),
        )) {
          size += chunk.length;
          if (size > 67108864) throw StateError('GIS resource too large');
          req.response.add(chunk);
        }
        await req.response.close();
      } catch (_) {
        try {
          req.response.statusCode = 502;
          await req.response.close();
        } catch (_) {}
      }
    });
    return proxy;
  }

  Future<void> close() async {
    client.close(force: true);
    await server.close(force: true);
  }
}
