import 'dart:async';
import 'dart:convert';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';
import 'auth_api_test.dart' show jsonResponse;
import 'kp_api_test.dart' show KpFixtureEnvironment, kpSession;
import 'workspace_test.dart' show FakeApi;

void main() {
  testWidgets('KP entry without ticket has no standalone login or workspace', (
    tester,
  ) async {
    var calls = 0;
    final api = PlatformClient(
      Uri.parse('https://hmi.invalid'),
      kpEnvironment: KpFixtureEnvironment(),
      client: MockClient((_) async {
        calls++;
        return jsonResponse({});
      }),
    );
    await tester.pumpWidget(UniversalHmiApp(api: api));
    await tester.pumpAndSettle();
    expect(find.byType(Workspace), findsNothing);
    expect(find.byKey(const Key('login-submit')), findsNothing);
    expect(find.text('请从 KP 登录后进入本页面'), findsOneWidget);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'KP logout removes dialogs before server response and shows host wait',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fake = FakeApi();
      final pending = Completer<http.Response>();
      var kpState = 'active';
      final env = KpFixtureEnvironment()..ticket = 'entry';
      final api = PlatformClient(
        Uri.parse('https://hmi.invalid'),
        kpEnvironment: env,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/redeem') ||
              r.url.path.endsWith('/status')) {
            return jsonResponse(kpSession(state: kpState, canWrite: true));
          }
          if (r.url.path.endsWith('/logout')) return pending.future;
          return jsonResponse(
            await fake.request(
              r.method,
              r.url.path,
              body: r.body.isEmpty ? null : jsonDecode(r.body),
              query: r.url.queryParameters,
            ),
          );
        }),
      );
      await tester.pumpWidget(UniversalHmiApp(api: api));
      await tester.pumpAndSettle();
      expect(find.byType(Workspace), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(Workspace)),
          builder: (_) => const AlertDialog(title: Text('Private KP draft')),
        ),
      );
      await tester.pumpAndSettle();
      final exit = api.logout();
      await tester.pumpAndSettle();
      expect(find.byType(Workspace), findsNothing);
      expect(find.text('Private KP draft'), findsNothing);
      expect(find.text('已停止业务访问，正在提交退出请求……'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(tester.takeException(), isNull);
      pending.complete(jsonResponse(kpSession(state: 'logout_requested')));
      await exit;
      await tester.pumpAndSettle();
      expect(find.text('已退出业务，正在等待 KP 返回登录页'), findsOneWidget);
      // The KP host may hold keyboard focus while its LogOff callback arrives.
      tester.binding.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ViewFocusState.unfocused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      await tester.pump();
      kpState = 'closed';
      await api.pollKpStatus();
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus,
        FocusManager.instance.rootScope,
      );
      tester.binding.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ViewFocusState.focused,
          direction: ViewFocusDirection.forward,
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('已退出，请返回 KP 登录'), findsOneWidget);
      final count = fake.requests.length;
      await tester.pump(const Duration(seconds: 3));
      expect(fake.requests.length, count);
      expect(find.byKey(const Key('login-submit')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
