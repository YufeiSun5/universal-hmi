import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/point_ownership.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'point_ownership_test.dart' show OwnershipApi;

void main() {
  for (final size in [
    const Size(1280, 800),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    testWidgets('ownership real dialog remains usable at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = OwnershipApi();
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (_) => PointOwnershipDialog(
                      api: api,
                      stations: const ['采集站', '一站', '共享站'],
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      Future<void> tap(String label) async {
        final finder = find.text(label);
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        expect(finder.hitTestable(), findsOneWidget);
        await tester.tap(finder);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await tap('选择筛选内单站建议');
      // The result list must remain reachable, not merely have no overflow.
      final resultRow = find.textContaining('压力 · 采集站');
      await tester.scrollUntilVisible(
        resultRow,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(resultRow.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      api.blocked = true;
      await tap('预览变更');
      expect(api.calls.last['targets'], [
        {'id': 'a', 'revision': 'ra', 'station': '一站'},
      ]);
      expect(find.text('存在冲突，整批不能保存；请返回调整。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认保存归属'))
            .onPressed,
        isNull,
      );
      await tap('返回修改');
      api.blocked = false;
      await tap('预览变更');
      await tap('确认保存归属');
      expect(api.calls.last['preview_token'], 'token');
      expect(api.calls.last['path'], endsWith('ownership-commit'));
    });
  }
  testWidgets(
    'ownership large list stays lazy and filtering preserves selection',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = OwnershipApi();
      api.rows.addAll(
        List.generate(
          80,
          (i) => {
            'id': 'extra-$i',
            'name': '压力补充变量-$i',
            'revision': 'rev-$i',
            'station': '采集站',
            'classification': 'unreferenced',
            'references': [],
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (_) => PointOwnershipDialog(
                      api: api,
                      stations: const ['采集站', '一站'],
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile).evaluate().length, lessThan(83));
      final select = find.text('选择筛选内单站建议');
      await tester.ensureVisible(select);
      await tester.pumpAndSettle();
      expect(select.hitTestable(), findsOneWidget);
      await tester.tap(select);
      await tester.pumpAndSettle();
      final search = find.byType(TextField);
      await tester.ensureVisible(search);
      await tester.pumpAndSettle();
      await tester.enterText(search, '压力补充变量-79');
      await tester.pumpAndSettle();
      final row = find.textContaining('压力补充变量-79 ·');
      await tester.scrollUntilVisible(
        row,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(row.hitTestable(), findsOneWidget);
      expect(find.textContaining('压力补充变量-78 ·'), findsNothing);
      await tester.ensureVisible(search);
      await tester.pumpAndSettle();
      await tester.enterText(search, '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览变更'));
      await tester.pumpAndSettle();
      expect(api.calls.last['targets'], [
        {'id': 'a', 'revision': 'ra', 'station': '一站'},
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}
