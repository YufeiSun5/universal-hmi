import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/features/trend.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/table.dart';

class FakeApi implements PlatformApi {
  final rows = <Json>[];
  final writes = <Json>[];
  final qualityByID = <String, String>{};
  final requests = <String>[];
  bool fail = false, denyWrite = false, writeTimeout = false;
  String runtimeVersion = 'v1';
  int applied = 0;
  int? writeStatus;
  String commandState = 'sent';
  Json point(
    String id,
    String station, {
    String type = 'FLOAT',
    bool writable = false,
  }) => {
    'id': id,
    'station': station,
    'name': 'Variable $id',
    'data_type': type,
    'source_type': 'manual',
    'unit': type == 'FLOAT' ? '°C' : '',
    'scale_factor': 1,
    'offset': 0,
    'writable': writable,
    'rw_mode': writable ? 'RW' : 'R',
    'min': 0,
    'max': 100,
  };
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    requests.add('$method $path ${query ?? {}}');
    if (fail) throw Exception('connection unavailable');
    if (path == '/api/v1/points' && method == 'GET') return {'items': rows};
    if (path == '/api/v1/points' && method == 'POST') {
      final row = Map<String, dynamic>.from(body as Map)
        ..['id'] = 'p${rows.length}';
      rows.add(row);
      return row;
    }
    if (path == '/api/v1/apply') {
      applied++;
      return {'version': runtimeVersion};
    }
    if (path == '/api/v1/jobs') return {'items': []};
    if (path == '/api/v1/history/catalog') return {'items': []};
    if (path == '/api/v1/history') {
      return {
        'items': [],
        'stats': {'count': 0},
        'boundary': 1,
      };
    }
    if (path.endsWith('/write-capability')) {
      final id = path.split('/')[4], p = rows.firstWhere((p) => p['id'] == id);
      final allowed =
          p['writable'] == true && p['data_type'] != 'STRING' && !denyWrite;
      return {
        'point_id': id,
        'writable': allowed,
        'data_type': p['data_type'],
        'min': 0,
        'max': 100,
        'version': runtimeVersion,
        'reason': allowed
            ? ''
            : p['data_type'] == 'STRING'
            ? 'string_write_unsupported'
            : 'point_read_only',
      };
    }
    if (path == '/api/v1/write') {
      writes.add(Map<String, dynamic>.from(body as Map));
      if (writeStatus != null) {
        throw PlatformRequestException(writeStatus!, 'version changed');
      }
      if (writeTimeout) throw Exception('timeout');
      return {...writes.last, 'state': 'accepted'};
    }
    if (path.startsWith('/api/v1/commands/')) {
      return {...writes.last, 'state': commandState};
    }
    if (path == '/api/v1/storage') {
      return {
        'enabled': false,
        'interval_ms': 1000,
        'retention_days': 30,
        'point_ids': [],
        'station': query?['station'] ?? '',
      };
    }
    if (path == '/api/v1/runtime') {
      final now = DateTime.now().toUtc().toIso8601String();
      return {
        'version': runtimeVersion,
        'values': [
          for (final p in rows)
            {
              'point_id': p['id'],
              'value': p['data_type'] == 'STRING' ? 'Ready' : 21.5,
              'raw': 21.5,
              'quality': qualityByID[p['id']] ?? 'good',
              'source_time': now,
              'received_time': now,
            },
        ],
        'sources': [],
        'rules': [],
        'policy': {
          'enabled': false,
          'interval_ms': 1000,
          'retention_days': 30,
          'changed_only': false,
          'point_ids': [],
        },
        'demo': false,
        'dropped': 0,
      };
    }
    return {};
  }

  @override
  Future<Json> upload(String name, Uint8List bytes) async => {};
  @override
  Future<Uint8List> download(String id) async => Uint8List(0);
  @override
  void close() {}
}

Future<void> launch(
  WidgetTester tester,
  FakeApi api, {
  Size size = const Size(1440, 900),
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(UniversalHmiApp(api: api));
  await tester.pumpAndSettle();
  if (api.rows.isNotEmpty) {
    await tester.tap(find.byKey(const Key('nav-8')));
    await tester.pumpAndSettle();
  }
}

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav-0')));
  await tester.pumpAndSettle();
}

void main() {
  test('Time-zone label preserves signs and fractional-hour offsets', () {
    expect(utcOffsetLabel(Duration.zero), 'UTC+00:00');
    expect(utcOffsetLabel(const Duration(hours: 8)), 'UTC+08:00');
    expect(utcOffsetLabel(const Duration(hours: -4)), 'UTC-04:00');
    expect(utcOffsetLabel(const Duration(hours: 5, minutes: 30)), 'UTC+05:30');
    expect(utcOffsetLabel(const Duration(minutes: -210)), 'UTC-03:30');
    expect(utcOffsetLabel(const Duration(hours: 5, minutes: 45)), 'UTC+05:45');
  });
  testWidgets(
    'Switching cached stations does not invent a restored connection',
    (tester) async {
      final api = FakeApi();
      api.rows.addAll([api.point('one', 'IO-01'), api.point('two', 'IO-02')]);
      await launch(tester, api);
      api.fail = true;
      await tester.pump(const Duration(milliseconds: 710));
      await tester.pumpAndSettle();
      expect(find.text('后端离线'), findsOneWidget);
      await tester.tap(find.byKey(const Key('station-IO-02')));
      await tester.pumpAndSettle();
      expect(find.text('后端离线'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Saving a variable remains draft until explicit activation', (
    tester,
  ) async {
    final api = FakeApi();
    await launch(tester, api);
    await openSettings(tester);
    await tester.tap(find.text('添加点位'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('point-station')), 'IO-07');
    await tester.enterText(find.byKey(const Key('point-name')), 'Temperature');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(api.rows.single['station'], 'IO-07');
    expect(api.applied, 0);
    expect(find.text('有未应用配置'), findsOneWidget);
    await tester.tap(find.text('应用配置').last);
    await tester.pumpAndSettle();
    expect(api.applied, 1);
    expect(find.text('有未应用配置'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Invalid variable stays editable without persisting', (
    tester,
  ) async {
    final api = FakeApi();
    await launch(tester, api);
    await openSettings(tester);
    await tester.tap(find.text('添加点位'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(api.rows, isEmpty);
    expect(find.text('请填写此项'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('point-name')), 'Corrected');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(api.rows.single['name'], 'Corrected');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Light-only workbench and offline narrow layout remain usable', (
    tester,
  ) async {
    await launch(tester, FakeApi()..fail = true, size: const Size(960, 600));
    expect(find.text('后端离线'), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.light,
    );
    expect(find.byIcon(Icons.dark_mode_outlined), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Station context restores filter selection page and scoped curves',
    (tester) async {
      final api = FakeApi();
      api.rows.addAll([api.point('one', 'IO-01'), api.point('two', 'IO-02')]);
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('station-IO-01')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-8')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('展开实时曲线'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Trend>(find.byType(Trend))
            .rows
            .every((r) => r['point_id'] == 'one'),
        isTrue,
      );
      await openSettings(tester);
      await tester.enterText(find.byKey(const Key('point-search')), 'one');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('point-row-one')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('station-IO-02')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('write-inspector-one')), findsNothing);
      await tester.tap(find.byKey(const Key('nav-8')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('展开实时曲线'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Trend>(find.byType(Trend))
            .rows
            .every((r) => r['point_id'] == 'two'),
        isTrue,
      );
      await tester.tap(find.byKey(const Key('station-IO-01')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('point-search')))
            .controller!
            .text,
        'one',
      );
      expect(find.byKey(const ValueKey('write-inspector-one')), findsOneWidget);
      expect(find.byKey(const Key('point-row-two')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Moved variable is pruned from prior station selection and trend',
    (tester) async {
      final api = FakeApi();
      api.rows.addAll([api.point('one', 'IO-01'), api.point('two', 'IO-02')]);
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('station-IO-01')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-8')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('展开实时曲线'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('point-row-one')));
      await tester.pumpAndSettle();
      api.rows[0] = {...api.rows[0], 'station': 'IO-02'};
      await tester.tap(find.byTooltip('刷新运行工作台'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('write-inspector-one')), findsNothing);
      expect(tester.widget<Trend>(find.byType(Trend)).rows, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('All 15000 variables are lazy, searchable and scrollable', (
    tester,
  ) async {
    final api = FakeApi();
    for (int i = 0; i < 15000; i++) {
      api.rows.add(
        api.point('p$i', 'IO-${(i ~/ 500 + 1).toString().padLeft(2, '0')}'),
      );
    }
    await launch(tester, api);
    await openSettings(tester);
    expect(tester.widget<DenseTable>(find.byType(DenseTable)).rowCount, 15000);
    expect(
      find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('point-row-'),
          )
          .evaluate()
          .length,
      lessThan(50),
    );
    final list = tester.widget<ListView>(
      find.byKey(const Key('dense-table-scroll')),
    );
    list.controller!.jumpTo(list.controller!.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('point-row-p14999')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('point-search')), 'p14999');
    await tester.pumpAndSettle();
    expect(tester.widget<DenseTable>(find.byType(DenseTable)).rowCount, 1);
    await tester.tap(find.byKey(const Key('station-IO-01')));
    await tester.pumpAndSettle();
    await openSettings(tester);
    expect(tester.widget<DenseTable>(find.byType(DenseTable)).rowCount, 500);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Capability and read-only mode block writes including unsupported strings',
    (tester) async {
      final api = FakeApi()..denyWrite = true;
      api.rows.add(api.point('one', 'IO-01', writable: true));
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('point-row-one')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('write-submit')))
            .onPressed,
        isNull,
      );
      expect(api.writes, isEmpty);
      await tester.pumpWidget(const SizedBox());
      final strings = FakeApi();
      strings.rows.add(
        strings.point('string', 'IO-01', type: 'STRING', writable: true),
      );
      await launch(tester, strings);
      await tester.tap(find.byKey(const Key('point-row-string')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('write-submit')))
            .onPressed,
        isNull,
      );
      expect(find.text('当前后端不支持字符串下设'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Numeric range validation and ACK distinguish physical readback',
    (tester) async {
      final api = FakeApi();
      api.rows.add(api.point('one', 'IO-01', writable: true));
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('point-row-one')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('write-value')), '101');
      await tester.tap(find.byKey(const Key('write-submit')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(find.textContaining('超出允许范围'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('write-value')), '42');
      await tester.tap(find.byKey(const Key('write-submit')));
      await tester.pumpAndSettle();
      expect(api.writes.single['value'], 42);
      expect(find.text('已接受 · 等待发送'), findsOneWidget);
      api.commandState = 'acknowledged';
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('设备已应答 · 等待读回'), findsOneWidget);
      expect(find.text('新鲜读回已确认'), findsNothing);
      api.commandState = 'readback_confirmed';
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('新鲜读回已确认'), findsOneWidget);
      expect(api.writes, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Uncertain POST reconciles with GET and never replays write', (
    tester,
  ) async {
    final api = FakeApi()..writeTimeout = true;
    api.rows.add(api.point('one', 'IO-01', writable: true));
    await launch(tester, api);
    await tester.tap(find.byKey(const Key('point-row-one')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('write-value')), '42');
    await tester.tap(find.byKey(const Key('write-submit')));
    await tester.pumpAndSettle();
    expect(find.text('结果未知 · 请核对'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('write-reconcile')));
    await tester.tap(find.byKey(const Key('write-reconcile')));
    await tester.pumpAndSettle();
    expect(api.writes, hasLength(1));
    expect(
      api.requests.any((r) => r.startsWith('GET /api/v1/commands/')),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Explicit HTTP rejection is failed while server error stays unknown',
    (tester) async {
      for (final status in [409, 500]) {
        final api = FakeApi()..writeStatus = status;
        api.rows.add(api.point('one', 'IO-01', writable: true));
        await launch(tester, api);
        await tester.tap(find.byKey(const Key('point-row-one')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('write-value')), '42');
        await tester.tap(find.byKey(const Key('write-submit')));
        await tester.pumpAndSettle();
        expect(
          find.text(status == 409 ? '下设失败' : '结果未知 · 请核对'),
          findsOneWidget,
        );
        expect(api.writes, hasLength(1));
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets('BOOL uses backend-supported numeric wire value', (tester) async {
    final api = FakeApi();
    api.rows.add(api.point('bool', 'IO-01', type: 'BOOL', writable: true));
    await launch(tester, api);
    await tester.tap(find.byKey(const Key('point-row-bool')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('write-value')), findsOneWidget);
    await tester.tap(find.byKey(const Key('write-value')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('write-submit')));
    await tester.pumpAndSettle();
    expect(api.writes.single['value'], 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Station reports constrain queries and clear preserves context', (
    tester,
  ) async {
    final api = FakeApi();
    api.rows.add(api.point('one', 'IO-01'));
    await launch(tester, api, size: const Size(960, 600));
    await tester.tap(find.byKey(const Key('station-IO-01')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    expect(
      api.requests.lastWhere((r) => r.startsWith('GET /api/v1/history ')),
      contains('station: IO-01'),
    );
    await tester.ensureVisible(find.text('清除'));
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('active-station'))).data,
      'IO-01',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
