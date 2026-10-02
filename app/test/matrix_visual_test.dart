import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';

import 'workbench_visual_test.dart' show VisualApi;

class MatrixVisualApi extends VisualApi {
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    final data = await super.request(method, path, body: body, query: query);
    if (path == '/api/v1/runtime') {
      final values = data['values'] as List;
      for (final entry in {
        1: -123.456,
        2: 1234567.89,
        3: 0.004,
        4: 72.35,
      }.entries) {
        (values[entry.key] as Json)['value'] = entry.value;
      }
    }
    return data;
  }
}

void main() {
  testWidgets(
    'Full station matrix visual evidence and visible cell accounting',
    (tester) async {
      final dir = Platform.environment['HMI_WIDGET_SCREENSHOTS'];
      if (dir == null) return;
      SharedPreferences.setMockInitialValues({});
      for (final entry in {
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        'HmiCJK': 'assets/fonts/NotoSansCJKsc-Regular.otf',
        'Roboto': 'assets/fonts/Roboto-Regular.ttf',
      }.entries) {
        await (FontLoader(
          entry.key,
        )..addFont(rootBundle.load(entry.value))).load();
      }
      tester.view.physicalSize = const Size(1180, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = MatrixVisualApi();
      for (var station = 1; station <= 30; station++) {
        for (var i = 0; i < 500; i++) {
          api.rows.add({
            ...api.point(
              's$station-p$i',
              'IO-${station.toString().padLeft(2, '0')}',
              writable: i % 7 == 0,
            ),
            'name': i == 3
                ? '模拟变量_长中文名称完整显示测试'
                : '模拟变量 ${(i + 1).toString().padLeft(3, '0')}',
            'unit': ['kPa', '°C', 'rpm', 'mm', 'm³/h'][i % 5],
            'source_type': 'simulator',
          });
        }
      }
      api.qualityByID.addAll({
        's1-p4': 'bad',
        's1-p10': 'stale',
        's1-p17': 'missing',
        's1-p25': 'bad',
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: UniversalHmiApp(api: api),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('station-IO-01')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-8')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 18; i++) {
        await tester.pump(const Duration(milliseconds: 710));
      }
      final measurements = <String, Object>{};
      Future<void> shot(String name) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final grid = tester.getRect(find.byKey(const Key('point-grid-scroll')));
        final cells = find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith('point-row-'),
        );
        var full = 0, partial = 0;
        final tops = <double>{}, lefts = <double>{};
        Size? cellSize;
        for (final element in cells.evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          if (rect.overlaps(grid)) {
            if (grid.contains(rect.topLeft) &&
                grid.contains(rect.bottomRight - const Offset(.01, .01))) {
              full++;
              tops.add(rect.top);
              lefts.add(rect.left);
            } else {
              partial++;
            }
            cellSize = rect.size;
          }
        }
        measurements[name] = {
          'grid': [grid.left, grid.top, grid.width, grid.height],
          'cell': [cellSize?.width, cellSize?.height],
          'fully_visible': full,
          'partly_visible': partial,
          'full_columns': lefts.length,
          'full_rows': tops.length,
          'mounted': cells.evaluate().length,
        };
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                .toImage(pixelRatio: tester.view.devicePixelRatio);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(dir).create(recursive: true);
          await File(
            '$dir/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await shot('matrix-500-compact-1180');
      await tester.tap(find.byTooltip('展开实时曲线'));
      await tester.pumpAndSettle();
      await shot('matrix-500-trend-1180');
      await tester.tap(find.byTooltip('收起实时曲线'));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<GridView>(find.byKey(const Key('point-grid-scroll')))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('point-row-s1-p499')), findsOneWidget);
      await shot('matrix-500-last-1180');
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('point-row-s1-p4')));
      await tester.pumpAndSettle();
      await shot('matrix-500-inspector-1180');
      await tester.tap(find.byKey(const Key('station-global')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-8')));
      await tester.pumpAndSettle();
      await shot('matrix-15000-global-1180');
      await tester.tap(find.byKey(const Key('matrix-density-control')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('matrix-density-comfortable')));
      await tester.pumpAndSettle();
    await shot('matrix-15000-comfortable-1180');
    tester.view.devicePixelRatio = 1.25;
    await tester.pumpAndSettle();
    await shot('matrix-15000-scale125-1180');
      await tester.runAsync(
        () => File('$dir/matrix-visible-counts.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert(measurements),
        ),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
