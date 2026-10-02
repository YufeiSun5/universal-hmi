import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:universal_hmi/shared/api.dart';

Json sessionData({bool authenticated = true}) => {
  'enabled': true,
  'authenticated': authenticated,
  'username': authenticated ? 'operator' : '',
  'can_write': authenticated,
  if (authenticated) ...{
    'csrf_token': 'test-csrf',
    'expires_at': DateTime.now()
        .add(const Duration(hours: 1))
        .toUtc()
        .toIso8601String(),
    'bearer_token': 'test-session-token',
    'token_type': 'Bearer',
  },
};
http.Response jsonResponse(Json data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
final unauthorized = throwsA(
  isA<PlatformRequestException>().having((e) => e.statusCode, 'status', 401),
);

void main() {
  test(
    'session gate is fail-closed; rejected credentials never create a session',
    () async {
      var requests = 0;
      final api = PlatformClient(
        Uri.parse('https://example.invalid'),
        client: MockClient((request) async {
          requests++;
          if (request.url.path.endsWith('/session')) {
            return jsonResponse(sessionData(authenticated: false));
          }
          return jsonResponse({
            'error': {'message': 'Invalid credentials'},
          }, 401);
        }),
      );
      addTearDown(api.close);
      await api.readSession();
      expect(api.session!.allowsWorkspace, false);
      await expectLater(api.request('GET', '/api/v1/runtime'), unauthorized);
      expect(requests, 1);
      await expectLater(api.login('operator', 'wrong-fixture'), unauthorized);
      expect(api.session!.authenticated, false);
      expect(api.session!.csrfToken, isEmpty);
      expect(api.session!.expired, false);
    },
  );

  test(
    'native token and CSRF remain in transport across JSON/upload/download; logout clears both',
    () async {
      final sent = <http.Request>[];
      final api = PlatformClient(
        Uri.parse('https://example.invalid'),
        client: MockClient((request) async {
          sent.add(request);
          if (request.url.path.endsWith('/login')) {
            return jsonResponse(sessionData());
          }
          if (request.url.path.endsWith('/logout')) {
            return jsonResponse(sessionData(authenticated: false));
          }
          if (request.url.path.endsWith('/file')) {
            return http.Response.bytes([1, 2, 3], 200);
          }
          return jsonResponse({});
        }),
      );
      addTearDown(api.close);
      await api.login('operator', 'fixture-only');
      expect(jsonDecode(sent.first.body), {
        'username': 'operator',
        'password': 'fixture-only',
        'issue_token': true,
      });
      final lease = api.scoped();
      await lease.request('POST', '/api/v1/write', body: {'value': 1});
      await lease.request('PUT', '/api/v1/storage', body: {});
      await lease.request('DELETE', '/api/v1/jobs/job');
      await lease.upload('fixture.csv', Uint8List.fromList([1]));
      expect(await lease.download('job'), [1, 2, 3]);
      for (final request in sent.skip(1)) {
        expect(request.headers['Authorization'], 'Bearer test-session-token');
        expect(request.followRedirects, false);
        if (request.method != 'GET') {
          expect(request.headers['X-CSRF-Token'], 'test-csrf');
        }
        if (request.method == 'GET') {
          expect(request.headers.containsKey('X-CSRF-Token'), false);
        }
      }
      await api.logout();
      expect(sent.last.headers['X-CSRF-Token'], 'test-csrf');
      expect(api.session!.allowsWorkspace, false);
      expect(api.session!.csrfToken, isEmpty);
      final count = sent.length;
      await expectLater(lease.request('POST', '/api/v1/write'), unauthorized);
      await expectLater(api.upload('fixture.csv', Uint8List(0)), unauthorized);
      expect(sent.length, count);
      await api.login('operator', 'fixture-only');
      expect(sent.last.headers.containsKey('Authorization'), false);
      expect(sent.last.headers.containsKey('X-CSRF-Token'), false);
    },
  );

  for (final operation in ['request', 'upload', 'download']) {
    test(
      '$operation 401 expires session once and stops further network work',
      () async {
        var requests = 0, notifications = 0;
        final api = PlatformClient(
          Uri.parse('https://example.invalid'),
          client: MockClient((request) async {
            requests++;
            if (request.url.path.endsWith('/login')) {
              return jsonResponse(sessionData());
            }
            return jsonResponse({
              'error': {'message': 'Session expired'},
            }, 401);
          }),
        );
        addTearDown(api.close);
        await api.login('operator', 'fixture-only');
        api.addListener(() => notifications++);
        final lease = api.scoped();
        Future<Object> perform() => switch (operation) {
          'upload' => lease.upload('fixture.csv', Uint8List(0)),
          'download' => lease.download('job'),
          _ => lease.request('GET', '/api/v1/runtime'),
        };
        await expectLater(perform(), unauthorized);
        expect(api.session!.expired, true);
        expect(api.session!.csrfToken, isEmpty);
        await expectLater(perform(), unauthorized);
        expect(requests, 2);
        expect(notifications, 1);
      },
    );
  }

  for (final lateStatus in [200, 401]) {
    test(
      'late $lateStatus response cannot expose old data or expire a newer login',
      () async {
        final pending = Completer<http.Response>();
        final api = PlatformClient(
          Uri.parse('https://example.invalid'),
          client: MockClient((request) async {
            if (request.url.path.endsWith('/login')) {
              return jsonResponse(sessionData());
            }
            if (request.url.path.endsWith('/logout')) return jsonResponse({});
            return pending.future;
          }),
        );
        addTearDown(api.close);
        await api.login('operator', 'fixture-only');
        final old = api.scoped();
        final result = old.request('GET', '/api/v1/runtime');
        final rejected = expectLater(result, unauthorized);
        await api.logout();
        await api.login('operator', 'fixture-only');
        pending.complete(
          jsonResponse({'private': 'old workspace data'}, lateStatus),
        );
        await rejected;
        expect(api.session!.authenticated, true);
        expect(api.session!.expired, false);
        await expectLater(old.upload('old.csv', Uint8List(0)), unauthorized);
        await expectLater(old.download('old'), unauthorized);
        await expectLater(old.request('POST', '/api/v1/write'), unauthorized);
      },
    );
  }

  test(
    'duplicate authentication submissions are rejected without a second request',
    () async {
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      var requests = 0;
      final api = PlatformClient(
        Uri.parse('https://example.invalid'),
        client: MockClient((request) async {
          requests++;
          started.complete();
          return pending.future;
        }),
      );
      addTearDown(api.close);
      final first = api.login('operator', 'fixture-only');
      await started.future;
      await expectLater(
        api.login('operator', 'fixture-only'),
        throwsA(
          isA<PlatformRequestException>().having(
            (e) => e.statusCode,
            'status',
            409,
          ),
        ),
      );
      expect(requests, 1);
      pending.complete(jsonResponse(sessionData()));
      await first;
      expect(api.session!.authenticated, true);
    },
  );

  for (final code in ['csrf_rejected', 'write_forbidden']) {
    test(
      '$code retires only a changed session, never retries a mutation',
      () async {
        var mutations = 0;
        final api = PlatformClient(
          Uri.parse('https://example.invalid'),
          client: MockClient((request) async {
            if (request.url.path.endsWith('/login')) {
              return jsonResponse(sessionData());
            }
            if (request.method == 'GET') return jsonResponse({'values': []});
            mutations++;
            return jsonResponse({
              'error': {'code': code, 'message': 'Rejected'},
            }, 403);
          }),
        );
        addTearDown(api.close);
        await api.login('operator', 'fixture-only');
        final lease = api.scoped();
        await lease.request('GET', '/api/v1/runtime');
        await expectLater(
          lease.request('POST', '/api/v1/write', body: {'value': 1}),
          throwsA(
            isA<PlatformRequestException>().having((e) => e.code, 'code', code),
          ),
        );
        expect(mutations, 1);
        expect(api.session!.authenticated, code != 'csrf_rejected');
        expect(api.session!.expired, code == 'csrf_rejected');
        if (code == 'csrf_rejected') {
          await expectLater(
            lease.request('GET', '/api/v1/runtime'),
            unauthorized,
          );
        }
      },
    );
  }

  test(
    'session expiration deadline clears tokens even without polling',
    () async {
      final data = sessionData()
        ..['expires_at'] = DateTime.now()
            .add(const Duration(milliseconds: 60))
            .toUtc()
            .toIso8601String();
      final api = PlatformClient(
        Uri.parse('https://example.invalid'),
        client: MockClient((_) async => jsonResponse(data)),
      );
      addTearDown(api.close);
      await api.login('operator', 'fixture-only');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(api.session!.expired, true);
      expect(api.session!.csrfToken, isEmpty);
    },
  );

  test(
    'native bearer sessions need no CSRF; browser sessions require it',
    () async {
      final data = sessionData()..remove('csrf_token');
      final sent = <http.Request>[];
      final api = PlatformClient(
        Uri.parse('https://example.invalid'),
        client: MockClient((request) async {
          sent.add(request);
          return jsonResponse(request.url.path.endsWith('/login') ? data : {});
        }),
      );
      addTearDown(api.close);
      expect(() => AuthSession.fromJson(data), throwsFormatException);
      await api.login('operator', 'fixture-only');
      await api.request('POST', '/api/v1/write', body: {'value': 1});
      expect(sent.last.headers['Authorization'], 'Bearer test-session-token');
      expect(sent.last.headers.containsKey('X-CSRF-Token'), false);
      expect(api.session!.authenticated, true);
    },
  );

  test(
    'bad session contract never silently falls back to local access',
    () async {
      final api = PlatformClient(
        Uri.parse('https://example.invalid'),
        client: MockClient((_) async => jsonResponse({})),
      );
      addTearDown(api.close);
      await expectLater(api.readSession(), throwsFormatException);
      expect(api.session, isNull);
    },
  );
}
