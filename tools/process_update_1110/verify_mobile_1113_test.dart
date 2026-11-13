// Offline rendering of the already-delivered 46-slot overview configuration.
// Values are distinct synthetic fixtures, never readings from field equipment.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/layout.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:universal_hmi/features/live_overview/visibility.dart';
import 'package:universal_hmi/platform/overview_preferences.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import '../../app/test/mobile_report_test.dart' show MemoryOverviewPreferences;
import 'verify_full_1111_test.dart' show loadOverview;
import 'verify_pumps_1111_test.dart' show definitions, PumpImportApi;

void main() {
  final defs = definitions();
  final imported = loadOverview(defs);
  final cases = <(Json, String)>[
    (imported.rows.singleWhere((r) => r['station'] == '中心站东南区'), '二次网'),
    for (final row in imported.rows)
      if ((row['bindings'] as Map).containsKey('zh-makeup2-current'))
        (row, '补水泵2'),
    (imported.rows.singleWhere((r) => r['station'] == '新北站南线'), '循环泵'),
  ];
  for (final android in [false, true]) {
    for (final size in [
      const Size(360, 800),
      const Size(390, 844),
      const Size(430, 900),
      const Size(844, 390),
    ]) {
      testWidgets('delivered pumps and FE201 FE202 at $size android=$android', (
        t,
      ) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = size;
        addTearDown(t.view.reset);
        final preview = Platform.environment['HMI_OVERVIEW_PREVIEW'];
        if (preview != null) {
          await (FontLoader('HmiCJK')..addFont(
                rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
              ))
              .load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        }
        var caseIndex = 0;
        for (final (row, group) in cases) {
          final phone = android || size.width < 640;
          final cols = overviewClientColumns(
            imported.columns,
            phone: phone,
          ).where((c) => c['group'] == group).toList();
          final ids = overviewPointIDs([row], cols).toSet().toList();
          final live = <String, Json>{
            for (final (i, id) in ids.indexed)
              id: {
                'value': 201 + i,
                'quality': 'good',
                'source_time': '2026-11-13T16:00:00+08:00',
              },
          };
          final second = (row['additional'] as Map?)?['bindings'] as Map?;
          if (second != null)
            live[second['zh-m16'] as String] = {
              'value': 0,
              'quality': 'good',
              'source_time': '2026-11-13T16:00:00+08:00',
            };
          final api = PumpImportApi()
            ..config = {
              'revision': 1,
              'columns': imported.columns,
              'rows': [row],
            };
          final prefs = MemoryOverviewPreferences()
            ..position = OverviewPosition(
              row: row['id'] as String,
              group: group,
            );
          Set<String> subscribed = {};
          final key = GlobalKey();
          await t.pumpWidget(
            MaterialApp(
              theme: workspaceTheme(),
              home: RepaintBoundary(
                key: key,
                child: Scaffold(
                  body: LiveOverview(
                    api: api,
                    definitions: defs,
                    live: live,
                    online: true,
                    androidClient: android,
                    preferenceStore: prefs,
                    onSubscriptionChanged: (v) => subscribed = v,
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          if (phone) {
            expect(
              subscribed,
              overviewPointIDs([row], imported.columns).toSet(),
            );
            await t.tap(
              android
                  ? find.byTooltip('筛选指标分组')
                  : find.byType(DropdownButton<String>).first,
            );
            await t.pumpAndSettle();
            await t.tap(find.text(group).last);
            await t.pumpAndSettle();
          }
          expect(
            subscribed,
            ids.toSet(),
            reason: '${row['station']} / $group subscriptions',
          );
          for (final column in cols) {
            for (final part in overviewDisplayRows([row], [column])) {
              final id = (part['bindings'] as Map)[column['id']];
              if (id == null) continue;
              final raw = live[id]!['value'] as num;
              final digits = column['decimals'] as int? ?? 2;
              final number = raw.toStringAsFixed(digits);
              expect(
                find.textContaining(number),
                findsWidgets,
                reason: '${row['station']} ${column['name']} $id',
              );
            }
          }
          if (second != null && group == '二次网') {
            expect(find.text('②'), findsWidgets);
            expect(subscribed, containsAll(second.values));
          }
          expect(
            t.takeException(),
            isNull,
            reason: '${row['station']} / $group',
          );
          if (preview != null &&
              android &&
              size.width == 390 &&
              (caseIndex == 0 ||
                  caseIndex == 1 ||
                  caseIndex == cases.length - 1)) {
            await t.runAsync(() async {
              final img =
                  await (key.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 2);
              final bytes = await img.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(preview).create(recursive: true);
              await File(
                '$preview/mobile-overview-$caseIndex.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              img.dispose();
            });
          }
          await t.pumpWidget(const SizedBox.shrink());
          caseIndex++;
        }
      });
    }
  }
}
