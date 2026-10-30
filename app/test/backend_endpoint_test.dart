import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/main.dart' show defaultApi;
import 'package:universal_hmi/platform/backend_endpoint.dart';

void main() {
  test('remote endpoint accepts only an HTTPS origin', () {
    expect(
      parseRemoteBackendEndpoint('https://example.com:443').toString(),
      'https://example.com/',
    );
    expect(
      parseRemoteBackendEndpoint('https://192.0.2.1:18153').toString(),
      'https://192.0.2.1:18153/',
    );
    for (final value in [
      '',
      'http://example.com',
      'https://user@example.com',
      'https://example.com/api',
      'https://example.com/a/..',
      'https://example.com/?x=1',
      'https://example.com/#x',
      'https://example.com:0',
      'https://example.com:65536',
      ' https://example.com',
    ]) {
      expect(parseRemoteBackendEndpoint(value), isNull, reason: value);
    }
  });
  test('shared launcher endpoint is strict and keeps one project URL', () {
    expect(
      parseSharedBackendEndpoint('http://127.0.0.1:18153').toString(),
      'http://127.0.0.1:18153/',
    );
    for (final value in [
      'http://example.com:18153/',
      'http://127.0.0.1/',
      'http://secret@127.0.0.1:18153/',
      'http://127.0.0.1:18153/api',
      'http://127.0.0.1:18153/?view=developer',
      'invalid',
    ]) {
      expect(parseSharedBackendEndpoint(value), isNull, reason: value);
    }
  });
  test('selected desktop endpoint is shared by API and GIS', () {
    final previous = localBackendUri;
    addTearDown(() => localBackendUri = previous);
    localBackendUri = parseDesktopEndpoint(
      jsonEncode({'pid': 1234, 'url': 'http://127.0.0.1:49123/'}),
      1234,
    )!;
    expect(defaultApi().port, 49123);
    expect(
      backendApiUri().resolve('gis/map.html').toString(),
      'http://127.0.0.1:49123/gis/map.html',
    );
  });

  test('discovery rejects stale, malformed and non-local endpoints', () {
    expect(parseDesktopEndpoint('{', 1234), isNull);
    expect(parseDesktopEndpoint(' ' * 4097, 1234), isNull);
    expect(
      parseDesktopEndpoint(
        jsonEncode({'pid': 99, 'url': 'http://127.0.0.1:18080/'}),
        1234,
      ),
      isNull,
    );
    for (final url in [
      'http://example.com:18080/',
      'http://localhost:18080/',
      'https://127.0.0.1:18080/',
      'http://127.0.0.1/',
      'http://127.0.0.1:0/',
      'http://127.0.0.1:65536/',
      'http://x@127.0.0.1:18080/',
      'http://127.0.0.1:18080/api',
      'http://127.0.0.1:18080/?x=1',
      'http://127.0.0.1:18080/#x',
    ]) {
      expect(
        parseDesktopEndpoint(jsonEncode({'pid': 1234, 'url': url}), 1234),
        isNull,
        reason: url,
      );
    }
  });
}
