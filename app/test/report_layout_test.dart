import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:universal_hmi/shared/table.dart';

void main() {
  testWidgets('short reports fill the page and center grouped columns', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(1440, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DenseTable(
            reportStyle: true,
            headers: const ['统计周期', '站点', '用量', '用量', '用量'],
            headerGroups: const ['', '', '热 (GJ)', '电 (kWh)', '水 (t)'],
            initialWidths: const [120, 190, 120, 120, 120],
            numericColumns: const {2, 3, 4},
            rows: const [
              ['2026–2027采暖季', '中心站东南区', '3037.00', '0.00', '667.00'],
              ['合计', '', '3037.00', '0.00', '667.00'],
            ],
            emphasizedRows: const {1},
            cellKey: (row, col) => ValueKey('report-$row-$col'),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final first = t.getCenter(find.byKey(const ValueKey('report-0-0')));
    final last = t.getCenter(find.byKey(const ValueKey('report-0-4')));
    expect(last.dx, greaterThan(1250));
    expect(first.dx, greaterThan(100));
    for (final entry in {2: '热 (GJ)', 3: '电 (kWh)', 4: '水 (t)'}.entries) {
      expect(
        t.getCenter(find.text(entry.value)).dx,
        closeTo(
          t.getCenter(find.byKey(ValueKey('report-0-${entry.key}'))).dx,
          1,
        ),
      );
    }
    expect(
      t
          .widget<Text>(find.byKey(const ValueKey('report-1-2')))
          .style!
          .fontWeight,
      FontWeight.w600,
    );
    expect(
      t.getCenter(find.byKey(const ValueKey('report-1-0'))).dy - first.dy,
      36,
    );
    expect(t.takeException(), isNull);
  });

  for (final width in [393.0, 1366.0, 1920.0, 2560.0]) {
    testWidgets(
      'all overview readings fit without horizontal scroll at $width',
      (t) async {
        await t.binding.setSurfaceSize(Size(width, 600));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final columns = [
          for (var i = 0; i < overviewReferenceColumns.length; i++)
            {...overviewReferenceColumns[i], 'id': 'c$i'},
        ];
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: OverviewTable(
                columns: columns,
                rows: const [
                  {'id': 'r0', 'site': '一所', 'name': '中心站', 'area': '东南区'},
                  {'id': 'r1', 'site': '一所', 'name': '中心站', 'area': '西北区'},
                ],
                reading: (row, col) => Text(
                  col['id'] == 'c0' ? '—' : '1234567.89',
                  key: ValueKey('${row['id']}-${col['id']}'),
                  maxLines: 1,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        for (var i = 0; i < columns.length; i++) {
          final rect = t.getRect(find.byKey(ValueKey('r0-c$i')));
          expect(rect.right, lessThanOrEqualTo(width + .01));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.width, greaterThan(0));
        }
        for (final state in t.stateList<ScrollableState>(
          find.byType(Scrollable),
        )) {
          if (axisDirectionToAxis(state.position.axisDirection) ==
              Axis.horizontal) {
            expect(state.position.maxScrollExtent, closeTo(0, .01));
          }
        }
        expect(
          find.text('1234567.89'),
          findsNWidgets((columns.length - 1) * 2),
        );
        expect(t.takeException(), isNull);
      },
    );
  }
}
