// Synthetic account operations only; no live service or credentials.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:universal_hmi/features/account_security.dart';
import 'package:universal_hmi/features/security_page.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'auth_api_test.dart' show jsonResponse, sessionData;

void main() {
  for (final size in [const Size(420, 360), const Size(640, 480)]) {
    testWidgets('password error retry keeps usable account form $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var reject = true, writes = 0, reads = 0;
      final paths = <String>[];
      final api = PlatformClient(
        Uri.parse('https://fixture.invalid'),
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/auth/session')) {
            reads++;
            return jsonResponse({
              ...sessionData(),
              'security_model': 'identity-v1',
            });
          }
          if (request.url.path.endsWith('/security/password')) {
            writes++;
            return reject
                ? jsonResponse({
                    'error': {'message': '测试密码错误'},
                  }, 422)
                : jsonResponse({});
          }
          return jsonResponse({'items': []});
        }),
      );
      try {
        await api.readSession();
        await tester.pumpWidget(
          MaterialApp(
            theme: workspaceTheme(),
            home: Scaffold(
              body: SecurityPageScope(
                root: true,
                child: AccountSecurity(api: api),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final current = find.widgetWithText(TextField, '当前密码');
        final next = find.widgetWithText(TextField, '新密码');
        Future<void> submit() async {
          await tester.ensureVisible(current);
          await tester.enterText(current, 'synthetic-current');
          await tester.ensureVisible(next);
          await tester.enterText(next, 'synthetic-new-password');
          final button = find.widgetWithText(FilledButton, '修改密码并撤销所有会话');
          await tester.ensureVisible(button);
          await tester.pumpAndSettle();
          await tester.tap(button);
          await tester.pumpAndSettle();
        }

        await submit();
        expect(writes, 1);
        expect(reads, 1);
        expect(find.textContaining('测试密码错误'), findsOneWidget);
        reject = false;
        await submit();
        expect(writes, 2);
        expect(reads, 2);
        expect(tester.widget<TextField>(current).controller!.text, isEmpty);
        expect(tester.widget<TextField>(next).controller!.text, isEmpty);
        expect(paths.where((p) => p.contains('/mfa/')), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        api.close();
        await tester.pumpAndSettle();
      }
    });
  }
}
