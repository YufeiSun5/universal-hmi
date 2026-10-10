import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:universal_hmi/platform/kp_environment.dart';
import 'package:universal_hmi/shared/api.dart';
import 'auth_api_test.dart' show jsonResponse, unauthorized;

class KpFixtureEnvironment implements KpEnvironment {
  String? ticket, token;
  bool pendingLogout = false;
  @override
  bool get embedded => true;
  @override
  String? takeTicket() {
    final value = ticket;
    ticket = null;
    return value;
  }

  @override
  String? readToken() => token;
  @override
  void writeToken(String? value) {
    token = value;
  }

  @override
  bool readLogoutRequested() => pendingLogout;
  @override
  void writeLogoutRequested(bool value) {
    pendingLogout = value;
  }

  @override
  void close() {}
}

final kpToken = List.filled(43, 'K').join();
Json kpSession({String state = 'active', bool canWrite = false}) => {
  'enabled': true,
  'authenticated': state == 'active',
  'can_write': state == 'active' && canWrite,
  'username': 'shared-account',
  'state': state,
  'expires_at': DateTime.now()
      .add(const Duration(hours: 1))
      .toUtc()
      .toIso8601String(),
  'webToken': kpToken,
};

void main() {
  test(
    'KP requires its own entry, never uses standalone login or local access',
    () async {
      var calls = 0;
      final env = KpFixtureEnvironment();
      final api = PlatformClient(
        Uri.parse('https://hmi.invalid/kp/'),
        kpEnvironment: env,
        client: MockClient((_) async {
          calls++;
          return jsonResponse({});
        }),
      );
      addTearDown(api.close);
      await expectLater(api.request('GET', '/api/v1/runtime'), unauthorized);
      await api.readSession();
      expect(api.session!.kpState, 'requires_entry');
      await expectLater(api.login('shared-account', 'unused'), unauthorized);
      expect(calls, 0);
    },
  );

  test(
    'one-use exchange restores per-window token and uses bearer for business',
    () async {
      final env = KpFixtureEnvironment()..ticket = 'one-use';
      final sent = <http.Request>[];
      final api = PlatformClient(
        Uri.parse('https://hmi.invalid/kp/'),
        kpEnvironment: env,
        client: MockClient((r) async {
          sent.add(r);
          return jsonResponse(
            r.url.path.startsWith('/api/v1/web/') ? kpSession() : {},
          );
        }),
      );
      addTearDown(api.close);
      await api.readSession();
      expect(jsonDecode(sent.single.body), {'ticket': 'one-use'});
      expect(sent.single.headers.containsKey('Authorization'), false);
      expect(env.ticket, isNull);
      expect(env.token, kpToken);
      final generation = api.sessionGeneration;
      await api.pollKpStatus();
      expect(api.sessionGeneration, generation);
      await api.scoped().request('GET', '/api/v1/runtime');
      expect(sent.last.headers['Authorization'], 'Bearer $kpToken');
      api.close();
      final restored = PlatformClient(
        Uri.parse('https://hmi.invalid/kp/'),
        kpEnvironment: env,
        client: MockClient((r) async {
          expect(r.url.path, '/api/v1/web/status');
          expect(r.headers['Authorization'], 'Bearer $kpToken');
          return jsonResponse(kpSession());
        }),
      );
      addTearDown(restored.close);
      await restored.readSession();
      expect(restored.session!.authenticated, true);
    },
  );

  test('new ticket clears old credentials even when exchange fails', () async {
    final env = KpFixtureEnvironment()
      ..token = kpToken
      ..ticket = 'replacement';
    final api = PlatformClient(
      Uri.parse('https://hmi.invalid'),
      kpEnvironment: env,
      client: MockClient((r) async {
        expect(r.headers.containsKey('Authorization'), false);
        return jsonResponse({}, 403);
      }),
    );
    addTearDown(api.close);
    await api.readSession();
    expect(api.session!.allowsWorkspace, false);
    expect(env.token, isNull);
  });

  test(
    'logout retires workspace and late results before HTTP completes',
    () async {
      final env = KpFixtureEnvironment()..ticket = 'entry';
      final mutation = Completer<http.Response>();
      final logout = Completer<http.Response>();
      var calls = 0;
      final api = PlatformClient(
        Uri.parse('https://hmi.invalid'),
        kpEnvironment: env,
        client: MockClient((r) async {
          calls++;
          if (r.url.path.endsWith('/redeem')) return jsonResponse(kpSession());
          if (r.url.path.endsWith('/logout')) return logout.future;
          if (r.url.path.endsWith('/status')) {
            return jsonResponse(kpSession(state: 'closed'));
          }
          return mutation.future;
        }),
      );
      addTearDown(api.close);
      await api.readSession();
      final old = api.scoped();
      final pendingRead = expectLater(
        old.request('GET', '/api/v1/runtime'),
        unauthorized,
      );
      final exit = api.logout();
      expect(api.session!.kpState, 'logout_submitting');
      expect(env.pendingLogout, true);
      await expectLater(old.request('POST', '/api/v1/write'), unauthorized);
      mutation.complete(jsonResponse({'private': 'previous user'}));
      await pendingRead;
      logout.complete(jsonResponse(kpSession(state: 'logout_requested')));
      await exit;
      expect(api.session!.kpState, 'logout_requested');
      expect(env.token, kpToken); // only limited status/logout remain
      await api.pollKpStatus();
      expect(api.session!.kpState, 'closed');
      expect(env.token, isNull);
      final count = calls;
      await api.pollKpStatus();
      expect(calls, count);
    },
  );

  test(
    'failed logout stays blocked across refresh despite active server status',
    () async {
      final env = KpFixtureEnvironment()..ticket = 'entry';
      http.Client client() => MockClient((r) async {
        if (r.url.path.endsWith('/logout')) {
          throw http.ClientException('offline');
        }
        return jsonResponse(kpSession());
      });
      final api = PlatformClient(
        Uri.parse('https://hmi.invalid'),
        kpEnvironment: env,
        client: client(),
      );
      addTearDown(api.close);
      await api.readSession();
      await api.logout();
      expect(api.session!.kpState, 'logout_unconfirmed');
      await api.pollKpStatus();
      expect(api.session!.allowsWorkspace, false);
      api.close();
      final refreshed = PlatformClient(
        Uri.parse('https://hmi.invalid'),
        kpEnvironment: env,
        client: client(),
      );
      addTearDown(refreshed.close);
      await refreshed.readSession();
      expect(refreshed.session!.kpState, 'logout_unconfirmed');
      await expectLater(
        refreshed.request('GET', '/api/v1/runtime'),
        unauthorized,
      );
    },
  );

  test(
    'transport outage retires old scopes, recovery creates a new scope',
    () async {
      var offline = false;
      final env = KpFixtureEnvironment()..ticket = 'entry';
      final api = PlatformClient(
        Uri.parse('https://hmi.invalid'),
        kpEnvironment: env,
        client: MockClient((_) async {
          if (offline) throw http.ClientException('offline');
          return jsonResponse(kpSession());
        }),
      );
      addTearDown(api.close);
      await api.readSession();
      final old = api.scoped();
      offline = true;
      await api.pollKpStatus();
      expect(api.session!.kpState, 'unavailable');
      await expectLater(old.request('GET', '/api/v1/runtime'), unauthorized);
      offline = false;
      await api.pollKpStatus();
      expect(api.session!.authenticated, true);
      await expectLater(old.request('GET', '/api/v1/runtime'), unauthorized);
      await api.scoped().request('GET', '/api/v1/runtime');
    },
  );

  test(
    'same account in separate windows is unaffected by another logout',
    () async {
      final clients = <PlatformClient>[];
      for (var i = 0; i < 2; i++) {
        final env = KpFixtureEnvironment()..ticket = 'entry-$i';
        final api = PlatformClient(
          Uri.parse('https://hmi.invalid'),
          kpEnvironment: env,
          client: MockClient(
            (r) async => jsonResponse(
              kpSession(
                state: r.url.path.endsWith('/logout')
                    ? 'logout_requested'
                    : 'active',
              ),
            ),
          ),
        );
        addTearDown(api.close);
        await api.readSession();
        clients.add(api);
      }
      await clients[0].logout();
      expect(clients[0].session!.authenticated, false);
      expect(clients[1].session!.authenticated, true);
      await clients[1].request('GET', '/api/v1/runtime');
    },
  );
}
