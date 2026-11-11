// Run from app/: flutter test ../tools/process_update_1110/verify_pumps_1111_test.dart
// Reads only the generated offline files and the established isolated point fixture.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:universal_hmi/features/live_overview/makeup.dart';
import 'package:universal_hmi/features/live_overview/transfer.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:universal_hmi/shared/api.dart';

import '../../app/test/gis_station_transfer_test.dart' show StationSelector;
import '../../app/test/live_overview_test.dart' show OverviewApi;

const output = '../outputs/庄河1111总览泵点位更新';
const filename = '$output/03-数据总览配置-补水双泵与北站三泵.json';

Map<String, Json> definitions() {
  final points = objects(
    jsonDecode(
      File(
        '../.local/process-update-v66/import-check-2603383149/points.json',
      ).readAsStringSync(),
    ),
  );
  // Match the already-confirmed field conversion; the import must not alter it.
  final outdoor = points.singleWhere((p) => p['source_path'] == '室外温度');
  outdoor['data_type'] = 'FLOAT';
  outdoor['scale_factor'] = 0.1;
  points.removeWhere(
    (p) => p['source_type'] == 'virtual' && p['name'] == '总览室外温度（原值÷10）',
  );
  return {for (final p in points) p['id'] as String: p};
}

OverviewImport incoming(Map<String, Json> defs) =>
    OverviewImport.decode(File(filename).readAsBytesSync(), defs);

OverviewImport prior(Map<String, Json> defs) => OverviewImport.decode(
  File('$output/回退-上次标准31区总览.json').readAsBytesSync(),
  defs,
);

class PumpImportApi extends OverviewApi {
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '$overviewPath/control-status') {
      return {'revision': config['revision'], 'rows': <String, dynamic>{}};
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  test(
    'delivered 31-zone file resolves existing points and only adds 12 bindings',
    () {
      final defs = definitions();
      final beforeDefinitions = jsonEncode(defs);
      final next = incoming(defs), old = prior(defs);
      expect(next.missing, isEmpty);
      expect(next.columns, hasLength(34));
      expect(next.rows, hasLength(31));
      expect(next.control, isNull);
      expect(next.outdoor, old.outdoor);
      expect(
        next.rows.fold<int>(0, (n, r) => n + (r['bindings'] as Map).length),
        895,
      );
      final expected =
          jsonDecode(File('$output/解析后的预期绑定.json').readAsStringSync()) as Json;
      for (final row in next.rows) {
        expect(row['bindings'], expected[row['id']]);
        final original = old.rows.singleWhere((r) => r['id'] == row['id']);
        for (final e in (original['bindings'] as Map).entries) {
          expect((row['bindings'] as Map)[e.key], e.value);
        }
        expect(row.containsKey('additional'), isFalse);
        expect(row['control'], original['control']);
      }
      final pump2Rows = next.rows.where(
        (r) => (r['bindings'] as Map).containsKey('zh-makeup2-current'),
      );
      expect(pump2Rows.map((r) => r['station']).toSet(), {
        '中心站东南区',
        '中心站西北区',
        '阳光壹佰高区',
        '阳光壹佰低区',
        '张屯换热站',
      });
      const newPaths = {
        '中心站东南区': '中心站一区补水2',
        '中心站西北区': '中心站二区补水2',
        '阳光壹佰高区': '阳光壹佰一区#2补水泵',
        '阳光壹佰低区': '阳光壹佰二区#2补水泵',
        '张屯换热站': '张屯站一区#2补水泵',
      };
      for (final row in pump2Rows) {
        final refs = row['bindings'] as Map;
        expect(
          defs[refs['zh-makeup2-current']]!['source_path'],
          '${newPaths[row['station']]}电流',
        );
        expect(
          defs[refs['zh-makeup2-frequency']]!['source_path'],
          '${newPaths[row['station']]}频率',
        );
      }
      final north = next.rows.singleWhere((r) => r['station'] == '新北站南线');
      expect(
        defs[(north['bindings'] as Map)['zh-m29']]!['source_path'],
        '新北站二区循环泵3电流',
      );
      expect(
        defs[(north['bindings'] as Map)['zh-m30']]!['source_path'],
        '新北站二区循环泵3频率',
      );
      for (final row in next.rows.where(
        (r) => r['station'] == '中心站东南区' || r['station'] == '中心站西北区',
      )) {
        expect(
          defs[(row['bindings'] as Map)['zh-m25']]!['source_path'],
          endsWith('主循环泵电流'),
        );
        expect(
          defs[(row['bindings'] as Map)['zh-m29']]!['source_path'],
          endsWith('辅助循2电流'),
        );
      }
      expect(jsonEncode(defs), beforeDefinitions);
    },
  );

  test(
    'repeat import and JSON round trip retain IDs; supplied rollback restores standard table',
    () {
      final defs = definitions();
      final next = incoming(defs), old = prior(defs);
      final repeat = next.merge(next.columns, next.rows, next.rows);
      expect(repeat.columns, next.columns);
      expect(repeat.rows, next.rows);
      final decoded = OverviewImport.decode(
        encodeOverview(next.columns, next.rows, next.outdoor),
        defs,
      );
      expect(decoded.columns, next.columns);
      expect(decoded.rows, next.rows);
      expect(decoded.outdoor, next.outdoor);
      expect(old.columns, hasLength(32));
      expect(
        old.rows.fold<int>(0, (n, r) => n + (r['bindings'] as Map).length),
        883,
      );
      expect(
        old.columns.any((c) => '${c['id']}'.startsWith('zh-makeup2')),
        isFalse,
      );
      expect(
        (old.rows.singleWhere((r) => r['station'] == '新北站南线')['bindings']
                as Map)
            .containsKey('zh-m29'),
        isFalse,
      );
    },
  );

  test(
    'missing or ambiguous pump source is reported and never borrows another pump',
    () {
      final defs = definitions();
      final id = defs.entries
          .singleWhere((e) => e.value['source_path'] == '中心站一区补水2电流')
          .key;
      final duplicated = incoming({...defs, 'duplicate-pump': defs[id]!});
      expect(duplicated.missing, hasLength(1));
      final removed = incoming({...defs}..remove(id));
      expect(removed.missing, hasLength(1));
      for (final draft in [duplicated, removed]) {
        final row = draft.rows.singleWhere((r) => r['station'] == '中心站东南区');
        expect(
          (row['bindings'] as Map).containsKey('zh-makeup2-current'),
          isFalse,
        );
        expect((row['bindings'] as Map).containsKey('zh-m23'), isTrue);
      }
    },
  );

  testWidgets(
    'standard replacement removes old generated pump columns and preserves service settings until save',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final defs = definitions();
      final old = prior(defs);
      var counter = 0;
      final api = PumpImportApi()
        ..config = {
          'revision': 1,
          'columns': overviewMakeupLayout(
            old.columns,
            newID: () => 'old-pump-${counter++}',
          ),
          'rows': old.rows,
          'outdoor': old.outdoor,
          'control': {'enabled': true, 'base_url': 'http://127.0.0.1:8004'},
        };
      final original = jsonEncode(api.config);
      final selector = StationSelector()
        ..bytes = File(filename).readAsBytesSync();
      final initial = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = selector;
      addTearDown(() => FileSelectorPlatform.instance = initial);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOverview(
              api: api,
              definitions: defs,
              live: const {},
              online: true,
              canEdit: true,
              stations: old.rows.map((r) => r['station'] as String).toList(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('配置总览'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('导入总览配置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('整表替换'));
      await tester.pumpAndSettle();
      expect(api.saveCount, 0);
      expect(jsonEncode(api.config), original);
      await tester.tap(find.text('保存总览'));
      await tester.pumpAndSettle();
      expect(api.saveCount, 1);
      expect(objects(api.config['columns']), hasLength(34));
      expect(
        objects(api.config['columns']).where((c) => c['name'] == '补水泵2电流'),
        hasLength(1),
      );
      expect(objects(api.config['rows']), incoming(defs).rows);
      expect(api.config['control'], {
        'enabled': true,
        'base_url': 'http://127.0.0.1:8004',
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
