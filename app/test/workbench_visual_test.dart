import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi;

class VisualApi extends FakeApi {
  int tick = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    final data = await super.request(method, path, body: body, query: query);
    if (path == '/api/v1/history') {
      final selected = rows
          .where(
            (p) =>
                query?['station'] == null || p['station'] == query!['station'],
          )
          .take(3)
          .toList();
      final history = <Json>[];
      final start = DateTime.now().toUtc().subtract(const Duration(minutes: 2));
      for (var i = 0; i < 30; i++) {
        for (var curve = 0; curve < selected.length; curve++) {
          final p = selected[curve];
          history.add({
            'point_id': p['id'],
            'name': p['name'],
            'station': p['station'],
            'unit': p['unit'],
            'version': 'v1',
            'value': 25 + curve * 3 + math.sin(i / 5 + curve) * 4,
            'quality': 'good',
            'source_time': start
                .add(Duration(seconds: i * 4))
                .toIso8601String(),
          });
        }
      }
      final values = history
          .map((r) => (r['value'] as num).toDouble())
          .toList();
      return {
        'items': history,
        'stats': {
          'count': history.length,
          'min': values.reduce(math.min),
          'max': values.reduce(math.max),
          'mean': values.reduce((a, b) => a + b) / values.length,
        },
        'boundary': 90,
      };
    }
    if (path == '/api/v1/runtime') {
      tick++;
      for (int i = 0; i < (data['values'] as List).length; i++) {
        final r = data['values'][i] as Json;
        r['value'] = 25 + (i % 8) * 3 + math.sin(tick / 5 + i / 3) * 4;
        r['raw'] = r['value'];
      }
      data['demo'] = true;
    }
    return data;
  }
}

void main() {
  testWidgets('Light workbench typography and layout visual evidence', (
    tester,
  ) async {
    final dir = Platform.environment['HMI_WIDGET_SCREENSHOTS'];
    if (dir == null) return;
    SharedPreferences.setMockInitialValues({});
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final font = FontLoader('HmiCJK')
      ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
    await font.load();
    final roboto = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    await roboto.load();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = VisualApi();
    final names = List.generate(
      8,
      (i) => '模拟变量 ${(i + 1).toString().padLeft(3, '0')}',
    );
    for (int station = 1; station <= 30; station++) {
      for (int i = 0; i < names.length; i++) {
        api.rows.add({
          ...api.point(
            's$station-p$i',
            'IO-${station.toString().padLeft(2, '0')}',
            writable: i == 2,
          ),
          'name': names[i],
          'unit': 'u',
          'source_type': 'simulator',
        });
      }
    }
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: UniversalHmiApp(api: api),
      ),
    );
    await tester.pumpAndSettle();
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 710));
    }
    Future<void> shot(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(dir).create(recursive: true);
        await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await shot('widget-dispatch-1440');
    tester.view.physicalSize = const Size(1180, 812);
    await tester.pumpAndSettle();
    await shot('reference-dispatch-1180');
    await tester.tap(find.byKey(const Key('station-IO-01')));
    await tester.pumpAndSettle();
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 710));
    }
    await tester.tap(find.byKey(const Key('choose-watched')));
    await tester.pumpAndSettle();
    for (final id in ['s1-p0', 's1-p1', 's1-p2']) {
      await tester.tap(find.byKey(Key('watch-choice-$id')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('watch-save')));
    await tester.pumpAndSettle();
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 710));
    }
    await shot('reference-overview-1180');
    await tester.tap(find.byKey(const Key('nav-8')));
    await tester.pumpAndSettle();
    await shot('reference-monitor-1180');
    await tester.tap(find.byKey(const Key('nav-7')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    await shot('reference-history-1180');
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pumpAndSettle();
    await shot('reference-report-1180');
    await tester.tap(find.byKey(const Key('nav-8')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('point-row-s1-p2')));
    await tester.pumpAndSettle();
    await shot('reference-write-1180');
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pumpAndSettle();
    await shot('widget-write-1440');
    tester.view.physicalSize = const Size(960, 600);
    await tester.pumpAndSettle();
    await shot('widget-write-960');
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pumpAndSettle();
    await shot('widget-report-960');
    await tester.pumpWidget(const SizedBox());
  });
}
