import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/statistics.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/statistics_columns.dart';
import 'package:universal_hmi/features/external_data/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/table.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'external_data_test.dart' show ExternalApi;
import 'support/ui_lint.dart';

class EnergyApi extends ExternalApi {
  Json? last;
  Json savedScreen = {...energy};
  int queryCount = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/external/screens') {
      if (method == 'POST') {
        savedScreen = {
          ...body as Json,
          'revision': (savedScreen['revision'] as int) + 1,
        };
        return savedScreen;
      }
      return {
        'items': [savedScreen],
      };
    }
    if (path.endsWith('/stations')) {
      return {
        'items': [
          {'code': '01-001', 'name': '中心站'},
        ],
      };
    }
    if (path.endsWith('/query')) {
      queryCount++;
      last = body as Json;
      if (pending != null) return pending!.future;
      if (this.fail) throw const PlatformRequestException(422, '统计查询失败');
      return {
        'statistics': [
          for (final m in ['electricity', 'water', 'heat'])
            {
              'station': '01-001',
              'name': '中心站',
              'metric': m,
              'label': m == 'electricity'
                  ? '耗电量'
                  : m == 'water'
                  ? '补水量'
                  : '一次网耗热量',
              'unit': m == 'electricity'
                  ? 'kWh'
                  : m == 'water'
                  ? 't'
                  : 'GJ',
              'date': '2026-11-03',
              'hour': '2026-11-03T23:00:00+08:00',
              'hour_usage': m == 'electricity' ? '0.00000000' : null,
              'day_usage': m == 'electricity' ? '0.00000000' : null,
              'day_status': m == 'electricity' ? '截至采样有效' : '口径待确认',
              'hour_status': m == 'electricity' ? '截至采样有效' : '口径待确认',
              'current_day': false,
            },
        ],
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

const energy = {
  'id': 'energy',
  'kind': 'energy',
  'name': '能耗管理',
  'revision': 1,
};
void main() {
  for (final size in [
    const Size(1440, 900),
    const Size(390, 800),
    const Size(420, 360),
  ]) {
    testWidgets('statistics layout and query at $size', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final api = EnergyApi();
      await t.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: Scaffold(
            body: StatisticsQuery(api: api, screen: energy),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(api.last?['mode'], 'current');
      final table = t.widget<DenseTable>(find.byType(DenseTable));
      expect(table.rowCount, 1);
      expect(table.rowBuilder!(0), contains('0.00'));
      expect(table.rowBuilder!(0), contains('—'));
      expect(table.rowBuilder!(0), isNot(contains('口径待确认')));
      expect(table.headers, isNot(contains('日状态')));
      expect(table.headers, isNot(contains('参与采样最早')));
      expect(find.textContaining('日小计仅供核查'), findsNothing);
      expect(t.takeException(), isNull);
      // Check actual visible geometry; tiny table resize handles are not form controls.
      expect(
        lintUI(t, minTarget: size.width < 600 ? 44 : 34),
        isEmpty,
        reason: 'compact desktop controls; touch controls remain 44px',
      );
    });
  }
  testWidgets('mode change clears stale results and binds historical day', (
    t,
  ) async {
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final api = EnergyApi();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatisticsQuery(api: api, screen: energy),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('当前总览'));
    await t.pumpAndSettle();
    await t.tap(find.text('历史日用量').last);
    await t.pumpAndSettle();
    await t.enterText(find.widgetWithText(TextField, '开始日期（含）'), '2026-11-02');
    await t.enterText(find.widgetWithText(TextField, '结束日期（含）'), '2026-11-03');
    await t.tap(find.text('查询'));
    await t.pumpAndSettle();
    expect(api.last?['from'], '2026-11-02');
    expect(api.last?['to'], '2026-11-03');
    expect(api.last?['mode'], 'daily');
    api.fail = true;
    await t.tap(find.text('查询'));
    await t.pumpAndSettle();
    expect(t.widget<DenseTable>(find.byType(DenseTable)).rowCount, 0);
    expect(find.text('统计查询失败'), findsOneWidget);
  });
  testWidgets('history catalog never auto opens energy or alarm', (t) async {
    final c = ExternalCatalog(EnergyApi(), canDevelop: false)
      ..loaded = true
      ..screens = [
        energy,
        {'id': 'alarm', 'kind': 'alarm', 'name': '报警'},
        {'id': 'history', 'kind': 'standard', 'name': '历史查询'},
      ];
    Json? opened;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExternalDataPanel(
            catalog: c,
            onOpen: (s) => opened = s,
            autoOpenFirst: true,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(opened?['id'], 'history');
    expect(find.text('能耗管理'), findsNothing);
    await t.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets(
    'runtime applies saved column names and visibility without requery',
    (t) async {
      final api = EnergyApi();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatisticsQuery(api: api, screen: energy),
          ),
        ),
      );
      await t.pumpAndSettle();
      final before = api.queryCount;
      final columns = statisticsLayout(energy);
      for (final c in columns) {
        c['visible'] = const {
          'date',
          'day_usage',
          'day_status',
        }.contains(c['key']);
        if (c['key'] == 'day_usage') c['label'] = '当日用量';
      }
      columns.insert(
        0,
        columns.removeAt(columns.indexWhere((c) => c['key'] == 'day_usage')),
      );
      await api.request(
        'POST',
        '/api/v1/external/screens',
        body: {...energy, 'statistics_columns': columns},
      );
      await t.pump(const Duration(seconds: 5));
      await t.pump();
      final table = t.widget<DenseTable>(find.byType(DenseTable));
      expect(table.headers, [
        '日期',
        for (var i = 0; i < 3; i++) ...['当日用量', '日状态'],
      ]);
      expect(table.rowBuilder!(0), contains('口径待确认'));
      expect(api.queryCount, before);
      api.savedScreen = {
        ...energy,
      }; // A delayed old directory cannot undo the saved version.
      await t.pump(const Duration(seconds: 5));
      await t.pump();
      expect(
        t.widget<DenseTable>(find.byType(DenseTable)).headers,
        table.headers,
      );
      expect(find.text('显示列配置'), findsNothing);
      await t.tap(find.text('当前总览'));
      await t.pumpAndSettle();
      expect(find.text('站区核数'), findsNothing);
      await t.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'developer edits shared statistics column names and saves explicitly',
    (t) async {
      t.view.physicalSize = const Size(1100, 850);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final api = EnergyApi();
      final catalog = ExternalCatalog(api, canDevelop: true)
        ..loaded = true
        ..screens = [energy];
      Json? opened;
      await t.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: Scaffold(
            body: ExternalWorkspace(
              catalog: catalog,
              screen: energy,
              development: true,
              onOpen: (s) => opened = s,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('显示列配置'));
      await t.pumpAndSettle();
      final row = find.byKey(const ValueKey('0-day_usage'));
      await t.ensureVisible(row);
      await t.pumpAndSettle();
      await t.enterText(
        find.descendant(of: row, matching: find.byType(TextFormField)),
        '今日消耗',
      );
      expect(api.savedScreen.containsKey('statistics_columns'), isFalse);
      await t.tap(find.text('保存配置'));
      await t.pumpAndSettle();
      expect(
        objects(
          opened?['statistics_columns'],
        ).singleWhere((c) => c['key'] == 'day_usage')['label'],
        '今日消耗',
      );
      expect(
        objects(
          opened?['statistics_columns'],
        ).singleWhere((c) => c['key'] == 'day_status')['visible'],
        isFalse,
      );
      await t.pumpWidget(const SizedBox());
      catalog.dispose();
    },
  );
}
