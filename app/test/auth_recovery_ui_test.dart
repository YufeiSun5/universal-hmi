// All session, MFA and recovery values are synthetic. No live service is used.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/features/account_security.dart';
import 'auth_api_test.dart' show jsonResponse, sessionData;
import 'auth_ui_test.dart' show AuthFixture, FixtureStreamClient;

void main() {
  for (final size in [const Size(420, 360), const Size(640, 480)]) {
    testWidgets(
      'MFA error retry and recovery continue return to real workspace $size',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = AuthFixture();
        var enrolled = false;
        var sessionReads = 0, beginWrites = 0, confirmWrites = 0;
        final bodies = <Json>[];
        final api = PlatformClient(
          Uri.parse('https://fixture.invalid'),
          streamClientFactory: () => FixtureStreamClient(fixture),
          client: MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('/auth/session')) {
              sessionReads++;
              return jsonResponse({
                ...sessionData(),
                'security_model': 'identity-v1',
                'can_develop': false,
                'mfa_required': !enrolled,
              });
            }
            if (path.endsWith('/security/mfa/begin')) {
              beginWrites++;
              bodies.add(jsonDecode(request.body) as Json);
              return jsonResponse({'secret': 'SYNTHETIC-NONFUNCTIONAL-SECRET'});
            }
            if (path.endsWith('/security/mfa/confirm')) {
              confirmWrites++;
              bodies.add(jsonDecode(request.body) as Json);
              if (confirmWrites == 1) {
                return jsonResponse({
                  'error': {
                    'code': 'invalid_code',
                    'message': '合成测试验证码不正确，请重试',
                  },
                }, 400);
              }
              enrolled = true;
              return jsonResponse({
                'recovery_codes': List.generate(
                  8,
                  (i) => 'DEMO-NOT-VALID-RECOVERY-$i',
                ),
              });
            }
            return jsonResponse(
              await fixture.fake.request(
                request.method,
                path,
                body: request.body.isEmpty ? null : jsonDecode(request.body),
                query: request.url.queryParameters,
              ),
            );
          }),
        );
        Future<void> tapLabel(String label) async {
          final target = find.text(label);
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          expect(target.hitTestable(), findsOneWidget);
          await tester.tap(target);
          await tester.pumpAndSettle();
        }

        Finder field(String label) => find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == label,
        );
        try {
          await tester.pumpWidget(UniversalHmiApp(api: api));
          await tester.pumpAndSettle();
          expect(find.byType(AccountSecurity), findsOneWidget);
          expect(find.byType(Workspace), findsNothing);
          expect(fixture.fake.requests, isEmpty);
          await tester.enterText(field('当前密码'), 'fixture-only');
          await tapLabel('绑定验证器');
          expect(beginWrites, 1);
          expect(bodies.first['password'], 'fixture-only');
          await tester.ensureVisible(field('验证器显示的6位验证码'));
          await tester.enterText(field('验证器显示的6位验证码'), '000000');
          await tapLabel('确认绑定');
          expect(confirmWrites, 1);
          expect(find.textContaining('合成测试验证码不正确'), findsOneWidget);
          expect(find.byType(Workspace), findsNothing);
          expect(fixture.fake.requests, isEmpty);
          await tester.ensureVisible(field('验证器显示的6位验证码'));
          await tester.enterText(field('验证器显示的6位验证码'), '123456');
          await tapLabel('确认绑定');
          expect(confirmWrites, 2);
          expect(bodies.last['code'], '123456');
          expect(find.byType(Workspace), findsNothing);
          expect(find.textContaining('合成测试验证码不正确'), findsNothing);
          final recovery = tester
              .widgetList<SelectableText>(find.byType(SelectableText))
              .single
              .data!;
          expect(recovery.split('\n'), hasLength(8));
          expect(sessionReads, 1);
          expect(fixture.fake.requests, isEmpty);
          await tapLabel('已保存恢复码，继续');
          expect(sessionReads, 2);
          expect(find.byType(Workspace), findsOneWidget);
          expect(find.byType(AccountSecurity), findsNothing);
          expect(find.textContaining('DEMO-NOT-VALID-RECOVERY-'), findsNothing);
          expect(beginWrites, 1);
          expect(
            confirmWrites,
            2,
          ); // Continue refreshes session, never writes MFA again.
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          api.close(); // Also closes fixture SSE timers before test termination.
          await tester.pumpAndSettle();
        }
      },
    );
  }
}
