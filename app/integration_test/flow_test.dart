import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Linux desktop: point input, history, rule and report workflow', (
    tester,
  ) async {
    final api = PlatformClient(Uri.parse('http://127.0.0.1:18080'));
    await tester.pumpWidget(UniversalHmiApp(api: api));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text('添加点位'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('point-station')),
      'Acceptance',
    );
    await tester.enterText(find.byKey(const Key('point-name')), 'DesktopInput');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(find.text('有未应用配置'), findsOneWidget);
    await tester.tap(find.text('应用配置'));
    await tester.pumpAndSettle();
    final points = objects(
      (await api.request('GET', '/api/v1/points'))['items'],
    );
    final id = points.single['id'].toString();
    await api.request(
      'POST',
      '/api/v1/points/$id/sample',
      body: {'value': 42.5},
    );
    await api.request('POST', '/api/v1/snapshot');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('42.5'), findsWidgets);
    await tester.tap(find.byKey(const Key('nav-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    expect(find.text('42.5'), findsWidgets);
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出 XLSX'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    final jobs = objects((await api.request('GET', '/api/v1/jobs'))['items']);
    expect(jobs.any((j) => j['state'] == 'completed'), isTrue);
    for (final size in [const Size(960, 600), const Size(1920, 1080)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpWidget(const SizedBox());
  });
}
