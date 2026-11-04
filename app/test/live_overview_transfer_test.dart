import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'gis_station_transfer_test.dart' show StationSelector;
import 'live_overview_test.dart' show OverviewApi;

import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/live_overview/transfer.dart';
import 'package:universal_hmi/shared/api.dart';

void main() {
  testWidgets(
    'overview imports selected rows after preview and writes only on save',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 800);
      addTearDown(tester.view.reset);
      final api = OverviewApi();
      final selector = StationSelector();
      final initial = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = selector;
      addTearDown(() => FileSelectorPlatform.instance = initial);
      final pointDefs = {
        for (final id in ['a', 'b', 'c']) id: <String, dynamic>{'name': id},
      };
      selector.bytes = encodeOverview(objects(api.config['columns']), [
        {...objects(api.config['rows']).first, 'name': '更新后'},
        {...objects(api.config['rows']).last, 'id': 'third', 'name': '第三站'},
      ], {});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOverview(
              api: api,
              definitions: pointDefs,
              live: const {},
              online: true,
              canEdit: true,
              stations: const ['A', 'B'],
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
      await tester.tap(find.text('合并所选行'));
      await tester.pumpAndSettle();
      expect(api.saveCount, 0);
      await tester.tap(find.text('保存总览'));
      await tester.pumpAndSettle();
      expect(api.saveCount, 1);
      expect(objects(api.config['rows']).map((r) => r['name']), [
        '更新后',
        '第二站',
        '第三站',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
  final columns = <Json>[
    {'id': 't', 'name': '温度', 'group': '一次网', 'decimals': 2},
  ];
  Json row(Object ref) => {
    'id': 'row',
    'site': '中心所',
    'station': 'S',
    'name': '中心站',
    'area': '一区',
    'bindings': {'t': ref},
  };
  final reference = {'source_id': 'kingio', 'source_path': 'T'};
  final definitions = {
    'p': {...reference, 'station': 'IO-01'},
    'other': {...reference, 'source_id': 'another'},
  };

  test(
    'overview import resolves exact acquisition identity and round trips stable IDs',
    () {
      final draft = OverviewImport.decode(
        encodeOverview(columns, [row(reference)], {'point_id': reference}),
        definitions,
      );
      expect(draft.rows.single['bindings'], {'t': 'p'});
      expect(draft.rows.single['station'], 'S');
      expect(draft.outdoor, {'point_id': 'p'});
      final bytes = encodeOverview(draft.columns, draft.rows, draft.outdoor);
      expect(jsonDecode(utf8.decode(bytes)), isNot(contains('revision')));
      expect(OverviewImport.decode(bytes, definitions).rows, draft.rows);
    },
  );
  test(
    'ambiguous template references stay empty and stale snapshot references fail',
    () {
      final draft = OverviewImport.decode(
        encodeOverview(columns, [row(reference)], {}),
        {...definitions, 'duplicate': reference},
      );
      expect(draft.missing, hasLength(1));
      expect(draft.rows.single['bindings'], isEmpty);
      expect(
        () => OverviewImport.decode(
          encodeOverview(columns, [row('stale')], {}),
          definitions,
        ),
        throwsFormatException,
      );
    },
  );
  test('rejects duplicated columns and malformed rows before applying', () {
    expect(
      () => OverviewImport.decode(
        encodeOverview([...columns, ...columns], [], {}),
        {},
      ),
      throwsFormatException,
    );
    final raw = jsonDecode(utf8.decode(encodeOverview(columns, [], {})));
    raw['rows'] = [1];
    expect(
      () => OverviewImport.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(raw))),
        {},
      ),
      throwsFormatException,
    );
  });
}
