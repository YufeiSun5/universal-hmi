import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/variable_search.dart';
import 'workspace_test.dart' show FakeApi, launch, openSettings;

void main() {
  test(
    'variable search handles alternatives, repeated wildcards and literal regex characters',
    () {
      expect(
        VariableSearch('*泵*运行*,温度?，Pipe.*.Flow').matches('一号泵电机运行值'),
        isTrue,
      );
      expect(VariableSearch('*泵*运行*,温度?，Pipe.*.Flow').matches('温度🌡'), isTrue);
      expect(VariableSearch('*泵*运行*,温度?，Pipe.*.Flow').matches('温度12'), isFalse);
      expect(VariableSearch('Pipe.*.Flow').matches('pipe.A.Flow'), isTrue);
      expect(VariableSearch('Pipe.*.Flow').matches('pipeXA.Flow'), isFalse);
      expect(VariableSearch('温度').matches('供水温度值'), isTrue);
      expect(VariableSearch('温度?').matches('供水温度1'), isFalse);
      expect(VariableSearch('***a**?*b').matches('A中长B'), isTrue);
      expect(VariableSearch(' , ， ').matches('anything'), isFalse);
      expect(VariableSearch('  ').matches('anything'), isTrue);
      expect(
        VariableSearch('*Pump*').matchesPoint({'source_path': 'KIO.Pump1.I'}),
        isTrue,
      );
    },
  );

  FakeApi fixture() {
    final api = FakeApi();
    api.rows.addAll(
      List.generate(
        10,
        (i) => {
          ...api.point('p$i', 'IO-01'),
          'name': i < 6 ? '泵${i + 1}运行' : '温度${i - 5}',
          'source_path': 'KIO.Zone.Point$i',
        },
      ),
    );
    api.rows.add({...api.point('other', 'IO-02'), 'name': '另一站'});
    return api;
  }

  String count(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const Key('variable-selection-count')))
      .data!;

  testWidgets('desktop resizing keeps essential variable actions visible', (
    tester,
  ) async {
    final api = fixture();
    await launch(tester, api);
    await openSettings(tester);
    await tester.enterText(find.byKey(const Key('point-search')), '泵?运行');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('variable-select-filtered')));
    for (final size in [
      const Size(850, 600),
      const Size(1100, 700),
      const Size(1920, 1080),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(count(tester), '已选 6 · 筛选 6');
      for (final finder in [
        find.byKey(const Key('point-search')),
        find.byKey(const Key('scan-variables')),
        find.text('应用配置'),
        find.byKey(const Key('variable-add-trends')),
        find.byTooltip('显示／隐藏资源树'),
      ]) {
        final rect = tester.getRect(finder.first);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.bottom, lessThan(size.height));
      }
      if (size.width == 850) {
        await tester.tap(find.byTooltip('显示／隐藏资源树'));
        await tester.pumpAndSettle();
        expect(find.byType(Drawer), findsOneWidget);
        expect(
          find.byKey(const Key('station-IO-01')).hitTestable(),
          findsOneWidget,
        );
        Navigator.of(tester.element(find.byType(Drawer))).pop();
        await tester.pumpAndSettle();
      }
    }
    expect(api.applied, 0);
    expect(api.writes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'list selection survives filtering, has no curve cap and supports Ctrl/Shift',
    (tester) async {
      final api = fixture();
      await launch(tester, api);
      await openSettings(tester);
      await tester.enterText(
        find.byKey(const Key('point-search')),
        '*泵*运行*,温度?',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('variable-select-filtered')));
      await tester.pumpAndSettle();
      expect(count(tester), '已选 10 · 筛选 10');
      await tester.tap(find.byKey(const Key('variable-add-trends')));
      await tester.pumpAndSettle();
      expect(find.textContaining('最多选择 6 条曲线'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('point-search')), '温度?');
      await tester.pumpAndSettle();
      expect(count(tester), '已选 10 · 筛选 4');
      await tester.tap(find.byKey(const Key('variable-clear-selection')));
      await tester.enterText(find.byKey(const Key('point-search')), '泵?运行');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('point-row-p0')));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.byKey(const Key('point-row-p3')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(count(tester), '已选 4 · 筛选 6');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(find.byKey(const Key('point-row-p1')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(count(tester), '已选 3 · 筛选 6');
      expect(api.applied, 0);
      expect(api.writes, isEmpty);
      await tester.tap(find.byKey(const Key('station-IO-02')));
      await tester.pumpAndSettle();
      await openSettings(tester);
      expect(count(tester), startsWith('已选 0'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'matrix checkbox adds and removes independently of inspector selection',
    (tester) async {
      final api = fixture();
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('matrix-check-p0')));
      await tester.tap(find.byKey(const Key('matrix-check-p1')));
      await tester.pumpAndSettle();
      expect(count(tester), startsWith('已选 2'));
      await tester.enterText(
        find.byKey(const Key('point-search')),
        '*Point1,*Point2',
      );
      await tester.pumpAndSettle();
      expect(count(tester), '已选 2 · 筛选 2');
      await tester.tap(find.byKey(const Key('variable-select-filtered')));
      await tester.pumpAndSettle();
      expect(count(tester), '已选 3 · 筛选 2');
      await tester.tap(find.byKey(const Key('matrix-check-p1')));
      await tester.pumpAndSettle();
      expect(count(tester), '已选 2 · 筛选 2');
      expect(api.applied, 0);
      expect(api.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'watched picker merges filtered selections and reports overflow without partial selection',
    (tester) async {
      final api = fixture();
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('station-IO-01')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-6')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('choose-watched')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watch-clear-selection')));
      await tester.enterText(find.byKey(const Key('watch-search')), '温度?');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watch-select-filtered')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 4 / 6 · 筛选 4'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('watch-search')), '泵1*,泵2*');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watch-select-filtered')));
      await tester.pumpAndSettle();
      expect(find.text('已选择 6 / 6 · 筛选 2'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('watch-search')), '*');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('watch-select-filtered')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('watch-selection-error')), findsOneWidget);
      expect(find.text('已选择 6 / 6 · 筛选 10'), findsOneWidget);
      await tester.tap(find.byKey(const Key('watch-choice-p2')));
      await tester.pumpAndSettle();
      expect(find.textContaining('请先取消部分选择'), findsOneWidget);
      await tester.tap(find.byKey(const Key('watch-save')));
      await tester.pumpAndSettle();
      expect(api.applied, 0);
      expect(api.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
