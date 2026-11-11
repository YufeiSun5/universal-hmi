// Run from app/: flutter test ../tools/process_update_1110/verify_full_1111_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:universal_hmi/features/live_overview/layout.dart';
import 'package:universal_hmi/features/live_overview/transfer.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'package:universal_hmi/shared/api.dart';

import '../../app/test/gis_station_transfer_test.dart' show StationSelector;
import 'verify_pumps_1111_test.dart' show definitions, PumpImportApi;

const output = '../outputs/庄河1111总览完整46项同步';
const file = '$output/03-数据总览配置-完整交付46项同步.json';
const split = ['zh-m16', 'zh-m17', 'zh-m18', 'zh-m19'];

OverviewImport loadOverview(Map<String, Json> defs, [String path = file]) =>
    OverviewImport.decode(File(path).readAsBytesSync(), defs);

void main() {
  test(
    'complete delivery resolves FE202 and exactly three primary corrections',
    () {
      final defs = definitions(), before = jsonEncode(definitions());
      final next = loadOverview(defs);
      final old = loadOverview(defs, '$output/回退-仅泵点更新版.json');
      expect(next.missing, isEmpty);
      expect(next.rows, hasLength(31));
      expect(next.columns, old.columns);
      expect(next.columns, hasLength(34));
      expect(next.control, isNull);
      expect(next.outdoor, old.outdoor);
      final expected =
          jsonDecode(File('$output/解析后的预期绑定.json').readAsStringSync()) as Json;
      var primary = 0, additional = 0, changes = 0;
      for (final row in next.rows) {
        final refs = row['bindings'] as Map;
        final original = old.rows.singleWhere((r) => r['id'] == row['id']);
        expect(refs, expected[row['id']]['bindings']);
        primary += refs.length;
        for (final column in next.columns) {
          if (refs[column['id']] != (original['bindings'] as Map)[column['id']])
            changes++;
        }
        if (row['additional'] case final Map extra) {
          expect(row['station'], '中心站东南区');
          expect(extra['columns'], split);
          expect(extra['bindings'], expected[row['id']]['additional']);
          additional += (extra['bindings'] as Map).length;
        }
        for (final id in [
          'zh-makeup2-current',
          'zh-makeup2-frequency',
          'zh-m29',
          'zh-m30',
        ]) {
          expect(refs[id], (original['bindings'] as Map)[id]);
        }
      }
      expect(primary, 894);
      expect(additional, 4);
      expect(changes, 3);
      final low = next.rows.singleWhere((r) => r['station'] == '华府怡景低区');
      final yang = next.rows.singleWhere((r) => r['station'] == '华府怡景原阳光壹佰');
      expect(
        (low['bindings'] as Map)['zh-m8'],
        (yang['bindings'] as Map)['zh-m8'],
      );
      expect(
        defs[(low['bindings'] as Map)['zh-m8']]!['source_path'],
        '中节能_华府怡景站_回水_压力',
      );
      expect(
        (low['bindings'] as Map)['zh-m20'],
        (yang['bindings'] as Map)['zh-m20'],
      );
      expect(
        defs[(yang['bindings'] as Map)['zh-m20']]!['source_path'],
        '华府怡景一区水箱水位',
      );
      final zhang = next.rows.singleWhere((r) => r['station'] == '张屯换热站');
      expect((zhang['bindings'] as Map).containsKey('zh-m15'), isFalse);
      final eastSouth = next.rows.singleWhere((r) => r['station'] == '中心站东南区');
      final second = (eastSouth['additional'] as Map)['bindings'] as Map;
      final suffixes = ['瞬时流量', '瞬时热流量', '热量总累积值', '流量累积数值整数'];
      for (var i = 0; i < split.length; i++) {
        expect(
          defs[second[split[i]]]!['source_path'],
          '中心站一区FE202${suffixes[i]}',
        );
        expect(
          defs[(eastSouth['bindings'] as Map)[split[i]]]!['source_path'],
          '中心站一区FE201${suffixes[i]}',
        );
      }
      expect(
        next.columns.singleWhere((c) => c['id'] == 'zh-m16')['unit'],
        't/h',
      );
      expect(next.columns.singleWhere((c) => c['id'] == 'zh-m19')['unit'], 't');
      expect(jsonEncode(defs), before);
    },
  );

  test(
    'only four metrics split; shared cells merge; fake point is not subscribed',
    () {
      final defs = definitions();
      final next = loadOverview(defs);
      final expanded = overviewDisplayRows(next.rows, next.columns);
      expect(expanded, hasLength(32));
      expect(overviewDisplayCellCount(next.rows, next.columns), 1088);
      expect(expanded[0]['_overview_part'], 1);
      expect(expanded[1]['_overview_part'], 2);
      for (final column in next.columns) {
        final key = column['id'];
        expect(overviewIsSplit(expanded[0], key), split.contains(key));
        if (split.contains(key)) {
          expect(
            (expanded[0]['bindings'] as Map)[key],
            isNot((expanded[1]['bindings'] as Map)[key]),
          );
        } else {
          expect(
            (expanded[0]['bindings'] as Map)[key],
            (expanded[1]['bindings'] as Map)[key],
          );
        }
      }
      final spans = overviewMeasurementSpans(expanded, next.columns);
      for (final key in split) {
        final index = next.columns.indexWhere((c) => c['id'] == key);
        expect(spans.where((s) => s.column == index && s.start == 0), isEmpty);
      }
      final pressure = next.columns.indexWhere((c) => c['id'] == 'zh-m15');
      expect(spans, contains((start: 0, end: 2, column: pressure)));
      final subscribed = overviewPointIDs(next.rows, next.columns).toSet();
      final fake = defs.entries
          .singleWhere((e) => e.value['source_path'] == '张屯站一区泵出口压力')
          .key;
      expect(subscribed, isNot(contains(fake)));
      final extra = (next.rows.first['additional'] as Map)['bindings'] as Map;
      expect(subscribed, containsAll(extra.values));
    },
  );

  test(
    'roundtrip and repeat retain additional bindings; missing FE202 never borrows FE201',
    () {
      final defs = definitions();
      final next = loadOverview(defs);
      final repeat = next.merge(next.columns, next.rows, next.rows);
      expect(repeat.rows, next.rows);
      expect(repeat.columns, next.columns);
      final roundtrip = OverviewImport.decode(
        encodeOverview(next.columns, next.rows, next.outdoor),
        defs,
      );
      expect(roundtrip.rows, next.rows);
      final second = (next.rows.first['additional'] as Map)['bindings'] as Map;
      final missing = loadOverview({...defs}..remove(second['zh-m16']));
      expect(missing.missing, hasLength(1));
      expect(
        ((missing.rows.first['additional'] as Map)['bindings'] as Map)
            .containsKey('zh-m16'),
        isFalse,
      );
      expect(
        (missing.rows.first['bindings'] as Map).containsKey('zh-m16'),
        isTrue,
      );
      final rollback = loadOverview(defs, '$output/回退-仅泵点更新版.json');
      expect(rollback.rows.any((r) => r.containsKey('additional')), isFalse);
      expect(rollback.rows, hasLength(31));
    },
  );

  testWidgets(
    'actual replacement saves both groups, shared status, and valid zero',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final defs = definitions();
      final old = loadOverview(defs, '$output/回退-仅泵点更新版.json');
      final next = loadOverview(defs);
      final first = next.rows.first['bindings'] as Map;
      final second = (next.rows.first['additional'] as Map)['bindings'] as Map;
      final api = PumpImportApi()
        ..config = {
          'revision': 1,
          'columns': old.columns,
          'rows': old.rows,
          'outdoor': old.outdoor,
          'control': {'enabled': true, 'base_url': 'http://127.0.0.1:8004'},
        };
      final before = jsonEncode(api.config);
      final selector = StationSelector()..bytes = File(file).readAsBytesSync();
      final platform = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = selector;
      addTearDown(() => FileSelectorPlatform.instance = platform);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOverview(
              api: api,
              definitions: defs,
              online: true,
              canEdit: true,
              live: {
                first['zh-m16'] as String: {'value': 123.4, 'quality': 'good'},
                second['zh-m16'] as String: {'value': 0, 'quality': 'good'},
              },
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
      expect(jsonEncode(api.config), before);
      await tester.tap(find.text('保存总览'));
      await tester.pumpAndSettle();
      expect(api.saveCount, 1);
      expect(objects(api.config['rows']), next.rows);
      expect(api.config['control'], {
        'enabled': true,
        'base_url': 'http://127.0.0.1:8004',
      });
      expect(find.text('123.4'), findsOneWidget);
      expect(find.text('0.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
