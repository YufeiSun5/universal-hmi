import 'dart:convert';
import 'dart:typed_data';
import 'package:universal_hmi/platform/process_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/point_ownership.dart';
import 'package:universal_hmi/shared/api.dart';

class OwnershipApi implements PlatformApi {
  final calls = <Json>[];
  bool blocked = false;
  final rows = <Json>[
    {
      'id': 'a',
      'name': '温度',
      'revision': 'ra',
      'station': '采集站',
      'classification': 'single',
      'suggested_station': '一站',
      'references': [
        {'station': '一站', 'screen_name': '画面一', 'property': 'value'},
      ],
    },
    {
      'id': 'b',
      'name': '压力',
      'revision': 'rb',
      'station': '采集站',
      'classification': 'shared',
      'suggested_station': '',
      'references': [],
    },
    {
      'id': 'c',
      'name': '流量',
      'revision': 'rc',
      'station': '采集站',
      'classification': 'unreferenced',
      'references': [],
    },
  ];
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    final value = Map<String, dynamic>.from(body as Map);
    calls.add({'path': path, ...value});
    if (path.endsWith('commit')) return {'saved': true, 'applied': false};
    final targets = objects(value['targets']);
    return {
      'preview_token': 'token',
      'can_commit': targets.isNotEmpty && !blocked,
      'items': [
        for (final r in rows)
          {
            ...r,
            'target_station':
                targets
                    .where((t) => t['id'] == r['id'])
                    .map((t) => t['station'])
                    .firstOrNull ??
                r['station'],
            'blockers': blocked ? ['冲突'] : [],
          },
      ],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('单站建议显式选择，预览冲突阻断，保存仅发送所选版本和令牌', (tester) async {
    final api = OwnershipApi();
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PointOwnershipDialog(
            api: api,
            stations: const ['采集站', '一站', '共享站'],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.calls.first['targets'], isEmpty);
    expect(find.textContaining('多站共享 1'), findsOneWidget);
    await tester.tap(find.text('选择筛选内单站建议'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选择 1'), findsOneWidget);
    api.blocked = true;
    await tester.tap(find.text('预览变更'));
    await tester.pumpAndSettle();
    expect(api.calls.last['targets'], [
      {'id': 'a', 'revision': 'ra', 'station': '一站'},
    ]);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认保存归属'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();
    api.blocked = false;
    await tester.tap(find.text('预览变更'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存归属'));
    await tester.pumpAndSettle();
    expect(api.calls.last['preview_token'], 'token');
    expect(api.calls.last['targets'], [
      {'id': 'a', 'revision': 'ra', 'station': '一站'},
    ]);
  });
  testWidgets('回退清单保留原版本并重新预览，冲突不提交', (tester) async {
    final api = OwnershipApi()..blocked = true;
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schema': 'universal-hmi-point-ownership-recovery-v1',
          'rollback_targets': [
            {'id': 'a', 'revision': 'old-revision', 'station': '采集站'},
          ],
        }),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PointOwnershipDialog(
            api: api,
            stations: const ['采集站', '一站'],
            pickRecovery: () async => ProcessFile('rollback.json', bytes),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('载入回退清单'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '选择筛选内单站建议'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '设置筛选结果目标'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('预览变更'));
    await tester.pumpAndSettle();
    expect(api.calls.last['targets'], [
      {'id': 'a', 'revision': 'old-revision', 'station': '采集站'},
    ]);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认保存归属'))
          .onPressed,
      isNull,
    );
  });
  testWidgets('批量选择原站会撤销已有变更', (tester) async {
    final api = OwnershipApi();
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PointOwnershipDialog(api: api, stations: const ['采集站', '一站']),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择筛选内单站建议'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选择 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ownership-batch-station')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采集站').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置筛选结果目标'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选择 0'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '预览变更'))
          .onPressed,
      isNull,
    );
  });
  testWidgets('窄高窗口可选择建议并预览', (tester) async {
    final api = OwnershipApi();
    tester.view.physicalSize = const Size(800, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PointOwnershipDialog(api: api, stations: const ['采集站', '一站']),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('选择筛选内单站建议'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览变更'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('确认保存归属'), findsOneWidget);
  });
}
