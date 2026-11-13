import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'live_overview_test.dart' show OverviewApi;

void main() {
  testWidgets(
    'android overview fits compact aligned metrics and retains full table',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 720);
      addTearDown(tester.view.reset);
      final dir = Platform.environment['HMI_OVERVIEW_PREVIEW'];
      if (dir != null) {
        await (FontLoader('HmiCJK')..addFont(
              rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
            ))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      }
      final cols = [
        for (final (i, c) in overviewReferenceColumns.indexed)
          {...c, 'id': 'm$i'},
      ];
      final boundCols = cols.where((c) => c['group'] != '补水泵2').toList();
      final points = <String, Json>{
        'outside': {'name': '室外温度', 'unit': '℃'},
        for (final c in boundCols)
          c['id'] as String: {'name': c['name'], 'unit': c['unit']},
      };
      final live = <String, Json>{
        'outside': {'value': 7.2, 'quality': 'good'},
        for (final (i, c) in boundCols.indexed)
          c['id'] as String: {
            'value': [
              16.9,
              3152.1,
              303.0,
              15324.6,
              46.8,
              33.2,
              0.67,
              0.45,
              0.64,
              47.8,
              39.5,
              33.2,
              0.46,
              0.28,
              0.51,
              212,
              5.6,
              937.2,
              6130.8,
              1700,
              2.4,
              182.9,
              6.3,
              30,
              61.4,
              48,
              30.2,
              46,
              29.9,
              45.5,
              41325.4,
            ][i],
            'source_time': '2026-11-03T13:07:10+08:00',
            'quality': 'good',
          },
      };
      final api = OverviewApi()
        ..config = {
          'columns': cols,
          'outdoor': {'point_id': 'outside'},
          'rows': [
            {
              'id': 'r',
              'name': '中心换热站',
              'site': '中心所',
              'area': '东南区',
              'station': '中心站东南区',
              'bindings': {for (final c in boundCols) c['id']: c['id']},
            },
          ],
        };
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: LiveOverview(
                api: api,
                definitions: points,
                live: live,
                online: true,
                androidClient: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('13:07:10'), findsOneWidget);
      expect(
        tester.getCenter(find.text('一次网累计热量')).dy -
            tester.getCenter(find.text('一次网瞬时热量')).dy,
        lessThanOrEqualTo(34),
      );
      expect(
        tester.getCenter(find.text('16.9 GJ/h').first).dx,
        greaterThan(tester.getCenter(find.text('一次网瞬时热量')).dx),
      );
      if (dir != null) {
        await tester.runAsync(() async {
          final img =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 2);
          final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
          await Directory(dir).create(recursive: true);
          await File(
            '$dir/手机总览示例.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          img.dispose();
        });
      }
      await tester.tap(find.byTooltip('切换完整表格'));
      await tester.pumpAndSettle();
      expect(find.byType(OverviewTable), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
