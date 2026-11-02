import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:universal_hmi/features/account_security.dart';
import 'package:universal_hmi/features/network_access.dart';
import 'package:universal_hmi/features/security.dart';
import 'package:universal_hmi/features/public_access.dart';
import 'package:universal_hmi/features/security_page.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'auth_api_test.dart' show jsonResponse, sessionData;
import 'network_access_test.dart' show NetworkApi;
import 'public_access_test.dart' show PublicPolicyApi;
import 'workspace_test.dart' show FakeApi;
import 'support/ui_lint.dart';

class LintSecurityApi extends FakeApi {
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async => {'items': []};
}

void main() {
  testWidgets('UI linter detects cramped and overlapping controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 10,
                top: 10,
                child: SizedBox(
                  width: 30,
                  height: 25,
                  child: TextButton(onPressed: () {}, child: const Text('A')),
                ),
              ),
              Positioned(
                left: 20,
                top: 15,
                child: SizedBox(
                  width: 30,
                  height: 25,
                  child: TextButton(onPressed: () {}, child: const Text('B')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // The upper control occludes the lower centre; target-size still catches it.
    expect(lintUI(tester).map((i) => i['rule']), contains('target-size'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 10,
                top: 10,
                child: SizedBox(
                  width: 100,
                  height: 50,
                  child: TextButton(onPressed: () {}, child: const Text('A')),
                ),
              ),
              Positioned(
                left: 100,
                top: 10,
                child: SizedBox(
                  width: 100,
                  height: 50,
                  child: TextButton(onPressed: () {}, child: const Text('B')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(lintUI(tester).map((i) => i['rule']), contains('control-overlap'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(decoration: const InputDecoration(labelText: '第一项')),
              TextField(decoration: const InputDecoration(labelText: '第二项')),
            ],
          ),
        ),
      ),
    );
    expect(lintUI(tester).map((i) => i['rule']), contains('control-gap'));
  });
  for (final size in [
    const Size(420, 720),
    const Size(900, 650),
    const Size(1440, 900),
  ]) {
    for (final scale in [1.0, 1.25]) {
      for (final page in ['account', 'network', 'users', 'whitelist']) {
        testWidgets('UI lint $page $size text $scale', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final api = PlatformClient(
            Uri.parse('https://fixture.invalid'),
            client: MockClient(
              (r) async => jsonResponse(
                r.url.path.endsWith('/auth/session')
                    ? {...sessionData(), 'can_audit': true}
                    : {'items': []},
              ),
            ),
          );
          addTearDown(api.close);
          await api.readSession();
          await tester.pumpWidget(
            MaterialApp(
              theme: workspaceTheme(),
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: SecurityPageScope(
                    root: true,
                    child: switch (page) {
                      'account' => AccountSecurity(api: api),
                      'network' => NetworkAccessPage(api: NetworkApi()),
                      'users' => SecurityPanel(api: LintSecurityApi()),
                      _ => PublicAccessPanel(api: PublicPolicyApi()),
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (page == 'users' || page == 'whitelist') {
            await tester.tap(find.text(page == 'users' ? '新建账号' : '添加规则'));
            await tester.pumpAndSettle();
          }
          expectCleanUI(tester, '$page top');
          final scroll = find.byType(SingleChildScrollView).first;
          for (var i = 0; i < 4; i++) {
            await tester.drag(scroll, const Offset(0, -250));
            await tester.pumpAndSettle();
            expectCleanUI(tester, '$page scroll $i');
          }
          expect(find.textContaining('验证器'), findsNothing);
          expect(find.textContaining('恢复码'), findsNothing);
          await tester.pumpWidget(const SizedBox());
          api.close();
        });
      }
    }
  }
}
