import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workspace_test.dart' show FakeApi, launch;

Finder field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

TextEditingController controller(WidgetTester tester, String label) =>
    tester.widget<TextField>(field(label)).controller!;

void main() {
  testWidgets('Directory refresh preserves unchanged filter editing values', (
    tester,
  ) async {
    final api = FakeApi();
    await launch(tester, api);
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pumpAndSettle();
    final values = <String, TextEditingValue>{
      '最小值': const TextEditingValue(
        text: '30',
        selection: TextSelection(baseOffset: 0, extentOffset: 1),
        composing: TextRange(start: 0, end: 1),
      ),
      '最大值': const TextEditingValue(
        text: '70',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 2),
      ),
      '开始时间 ISO（可选）': const TextEditingValue(
        text: '2026-10-01T00:00:00Z',
        selection: TextSelection(baseOffset: 5, extentOffset: 7),
      ),
      '结束时间 ISO（可选）': const TextEditingValue(
        text: '2026-10-02T00:00:00Z',
        selection: TextSelection.collapsed(offset: 10),
      ),
    };
    // A real directory reload is triggered by a changed runtime version, not
    // every runtime sample. Unfocused controllers also retain IME state.
    for (final entry in values.entries) {
      controller(tester, entry.key).value = entry.value;
    }
    await tester.pump();
    final loads = api.requests
        .where((r) => r.startsWith('GET /api/v1/points '))
        .length;
    api.runtimeVersion = 'v2';
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pumpAndSettle();
    expect(
      api.requests.where((r) => r.startsWith('GET /api/v1/points ')).length,
      greaterThan(loads),
    );
    for (final entry in values.entries) {
      expect(
        controller(tester, entry.key).value,
        entry.value,
        reason: entry.key,
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Changing station still restores different saved filter text', (
    tester,
  ) async {
    final api = FakeApi();
    api.rows.addAll([api.point('one', 'IO-01'), api.point('two', 'IO-02')]);
    await launch(tester, api);
    await tester.tap(find.byKey(const Key('station-IO-01')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pumpAndSettle();
    await tester.enterText(field('最小值'), '30');
    await tester.enterText(field('最大值'), '70');
    await tester.tap(find.byKey(const Key('station-IO-02')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pumpAndSettle();
    expect(controller(tester, '最小值').text, isEmpty);
    expect(controller(tester, '最大值').text, isEmpty);
    await tester.enterText(field('最小值'), '10');
    await tester.enterText(field('最大值'), '90');
    await tester.tap(find.byKey(const Key('station-IO-01')));
    await tester.pumpAndSettle();
    expect(controller(tester, '最小值').text, '30');
    expect(controller(tester, '最大值').text, '70');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
