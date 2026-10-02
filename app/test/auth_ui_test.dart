import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';
import 'auth_api_test.dart' show jsonResponse, sessionData;
import 'workspace_test.dart' show FakeApi;

class AuthFixture {
  final fake = FakeApi();
  bool expired = false, local = false, badSession = false;
  int loginCount = 0, logoutCount = 0;
  String? mutationRejection;
  Completer<http.Response>? loginResponse, logoutResponse;
  late final api = PlatformClient(
    Uri.parse('https://example.invalid'),
    client: MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/auth/session')) {
        if (badSession) return jsonResponse({}, 503);
        return jsonResponse(
          local
              ? {'enabled': false, 'authenticated': false, 'can_write': true}
              : sessionData(authenticated: false),
        );
      }
      if (path.endsWith('/auth/login')) {
        loginCount++;
        if (loginResponse != null) return loginResponse!.future;
        if ((jsonDecode(request.body) as Json)['password'] != 'fixture-only') {
          return jsonResponse({}, 401);
        }
        expired = false;
        return jsonResponse(sessionData());
      }
      if (path.endsWith('/auth/logout')) {
        logoutCount++;
        return logoutResponse?.future ?? Future.value(jsonResponse({}));
      }
      if (expired) return jsonResponse({}, 401);
      if (request.method != 'GET' && mutationRejection != null) {
        return jsonResponse({
          'error': {'code': mutationRejection, 'message': 'Rejected'},
        }, 403);
      }
      return jsonResponse(
        await fake.request(
          request.method,
          path,
          body: request.body.isEmpty ? null : jsonDecode(request.body),
          query: request.url.queryParameters,
        ),
      );
    }),
  );
}

Future<void> start(
  WidgetTester tester,
  AuthFixture fixture, {
  Size size = const Size(1440, 900),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(UniversalHmiApp(api: fixture.api));
  await tester.pumpAndSettle();
}

Future<void> login(
  WidgetTester tester, [
  String password = 'fixture-only',
]) async {
  await tester.enterText(find.byKey(const Key('login-username')), 'operator');
  await tester.enterText(find.byKey(const Key('login-password')), password);
  await tester.tap(find.byKey(const Key('login-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'wrong/correct login, password clearing and duplicate logout are safe',
    (tester) async {
      final fixture = AuthFixture();
      await start(tester, fixture);
      expect(find.byType(Workspace), findsNothing);
      expect(fixture.fake.requests, isEmpty);
      await login(tester, 'wrong-fixture');
      expect(find.text('用户名或密码不正确'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('login-password')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.byType(Workspace), findsNothing);
      await login(tester);
      expect(find.byType(Workspace), findsOneWidget);
      expect(find.text('operator'), findsOneWidget);
      fixture.logoutResponse = Completer<http.Response>();
      await tester.tap(find.byKey(const Key('logout')));
      await tester.tap(find.byKey(const Key('logout')));
      await tester.pump();
      expect(fixture.logoutCount, 1);
      fixture.logoutResponse!.complete(jsonResponse({}));
      await tester.pumpAndSettle();
      expect(find.byType(Workspace), findsNothing);
      expect(find.byKey(const Key('login-username')), findsOneWidget);
      final count = fixture.fake.requests.length;
      await tester.pump(const Duration(seconds: 3));
      expect(fixture.fake.requests.length, count);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('pending login blocks duplicate click and keyboard submission', (
    tester,
  ) async {
    final fixture = AuthFixture()..loginResponse = Completer<http.Response>();
    await start(tester, fixture);
    await tester.enterText(find.byKey(const Key('login-username')), 'operator');
    await tester.enterText(
      find.byKey(const Key('login-password')),
      'fixture-only',
    );
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.tap(find.byKey(const Key('login-submit')));
    tester
        .widget<TextField>(find.byKey(const Key('login-password')))
        .onSubmitted!('fixture-only');
    await tester.pump();
    expect(fixture.loginCount, 1);
    expect(find.byType(Workspace), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('login-submit')))
          .onPressed,
      isNull,
    );
    fixture.loginResponse!.complete(jsonResponse(sessionData()));
    await tester.pumpAndSettle();
    expect(find.byType(Workspace), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'closing during pending login discards its response and credentials',
    (tester) async {
      final fixture = AuthFixture()..loginResponse = Completer<http.Response>();
      await start(tester, fixture);
      await tester.enterText(
        find.byKey(const Key('login-username')),
        'operator',
      );
      await tester.enterText(
        find.byKey(const Key('login-password')),
        'fixture-only',
      );
      await tester.tap(find.byKey(const Key('login-submit')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      fixture.loginResponse!.complete(jsonResponse(sessionData()));
      await tester.pumpAndSettle();
      expect(fixture.api.session, isNull);
      expect(find.byType(Workspace), findsNothing);
      expect(fixture.fake.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'expired polling removes private dialogs, workspace and navigation history',
    (tester) async {
      final fixture = AuthFixture();
      fixture.fake.rows.add(fixture.fake.point('secret', 'Private station'));
      await start(tester, fixture);
      await login(tester);
      final context = tester.element(find.byType(Workspace));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Private task result'),
          duration: Duration(minutes: 1),
        ),
      );
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) =>
              const AlertDialog(title: Text('Private draft contents')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private draft contents'), findsOneWidget);
      fixture.expired = true;
      await tester.pump(const Duration(milliseconds: 701));
      await tester.pumpAndSettle();
      expect(find.byType(Workspace), findsNothing);
      expect(find.text('Private draft contents'), findsNothing);
      expect(find.text('Private task result'), findsNothing);
      expect(find.textContaining('会话已过期'), findsOneWidget);
      final count = fixture.fake.requests.length;
      await tester.pump(const Duration(seconds: 3));
      expect(fixture.fake.requests.length, count);
      final loginContext = tester.element(
        find.byKey(const Key('login-submit')),
      );
      expect(await Navigator.of(loginContext).maybePop(), false);
      fixture.fake.rows.clear();
      await login(tester);
      expect(find.byType(Workspace), findsOneWidget);
      expect(find.text('Private station'), findsNothing);
      expect(find.text('Private draft contents'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('CSRF rotation retires the workspace after a successful read', (
    tester,
  ) async {
    final fixture = AuthFixture();
    await start(tester, fixture);
    await login(tester);
    expect(find.byType(Workspace), findsOneWidget);
    await fixture.api.request('GET', '/api/v1/runtime');
    fixture.mutationRejection = 'csrf_rejected';
    await expectLater(
      fixture.api.request('POST', '/api/v1/write', body: {'value': 1}),
      throwsA(
        isA<PlatformRequestException>().having(
          (e) => e.code,
          'code',
          'csrf_rejected',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Workspace), findsNothing);
    expect(find.textContaining('会话已过期或已变更'), findsOneWidget);
    final count = fixture.fake.requests.length;
    await tester.pump(const Duration(seconds: 3));
    expect(fixture.fake.requests.length, count);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offline bootstrap offers retry without leaking the workspace', (
    tester,
  ) async {
    final fixture = AuthFixture()..badSession = true;
    await start(tester, fixture);
    expect(find.byType(Workspace), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    expect(fixture.fake.requests, isEmpty);
    fixture.badSession = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('login-submit')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('local disabled auth preserves workspace and shows no logout', (
    tester,
  ) async {
    final fixture = AuthFixture()..local = true;
    await start(tester, fixture);
    expect(find.byType(Workspace), findsOneWidget);
    expect(find.byKey(const Key('logout')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('narrow login has no overflow and password stays obscured', (
    tester,
  ) async {
    await start(tester, AuthFixture(), size: const Size(320, 480));
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('login-password')))
          .obscureText,
      true,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
