import 'dart:async';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'client_navigation_test.dart' show ClientApi;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/workspace.dart';
import 'package:universal_hmi/features/trend.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/table.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'external_data_test.dart' show ExternalApi, screen;

class TrendLayoutApi extends ExternalApi {
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    final result = await super.request(method, path, body: body, query: query);
    if (!path.endsWith('/query')) return result;
    return {
      ...result,
      'points': [
        {'code': 't1', 'name': '供水温度', 'unit': '℃'},
        {'code': 't2', 'name': '回水温度', 'unit': '℃'},
      ],
      'rows': List.generate(
        24,
        (i) => {
          'sample_time':
              '2026-10-27T${i.toString().padLeft(2, '0')}:00:00+08:00',
          'quality': i == 3 ? null : 1,
          'values': i == 3 ? [null, null] : ['$i.25', '$i.50'],
        },
      ),
      'has_more': (body! as Json)['offset'] == 0,
    };
  }
}

class TrendClientApi extends ClientApi {
  final data = TrendLayoutApi();
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) {
    if (path == '/api/v1/external/screens') {
      return Future.value({
        'items': [
          {...screen, 'kind': 'trend', 'name': '北区总站供回水温度历史趋势（长名称）'},
        ],
      });
    }
    if (path.startsWith('/api/v1/external/screens/daily/')) {
      return data.request(method, path, body: body, query: query);
    }
    return super.request(method, path, body: body, query: query);
  }
}

Future<void> open(
  WidgetTester t,
  TrendLayoutApi api,
  Size size, {
  List<Widget> actions = const [],
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);
  await t.pumpWidget(
    MaterialApp(
      theme: workspaceTheme(),
      home: Scaffold(
        body: ExternalQuery(
          api: api,
          screen: {...screen, 'kind': 'trend'},
          actions: actions,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> range(WidgetTester t) async {
  await t.tap(find.byKey(const Key('external-trend-range')));
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'compact pending query keeps both development actions reachable',
    (t) async {
      final api = TrendLayoutApi()..pending = Completer<Json>();
      await open(
        t,
        api,
        const Size(420, 360),
        actions: [
          IconButton(
            tooltip: '编辑画面名称',
            onPressed: () {},
            icon: const Icon(Icons.edit_outlined),
          ),
          IconButton(
            tooltip: '删除外数据画面',
            onPressed: () {},
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      );
      await t.tap(find.text('查询'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byTooltip('编辑画面名称').hitTestable(), findsOneWidget);
      expect(find.byTooltip('删除外数据画面').hitTestable(), findsOneWidget);
      expect(find.text('取消等待').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.text('取消等待'));
      await t.pumpAndSettle();
      api.pending!.complete({});
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    },
  );

  for (final clientSize in [const Size(640, 480), const Size(420, 360)]) {
    testWidgets(
      'client history shell leaves a usable trend workspace at $clientSize',
      (t) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = const Size(1280, 800);
        addTearDown(t.view.resetDevicePixelRatio);
        addTearDown(t.view.resetPhysicalSize);
        await t.pumpWidget(
          MaterialApp(
            theme: workspaceTheme(),
            home: Workspace(
              api: TrendClientApi(),
              canDevelop: false,
              initialView: 'history',
            ),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(
          find.descendant(
            of: find.byType(ExternalDataPanel),
            matching: find.text('北区总站供回水温度历史趋势（长名称）'),
          ),
        );
        await t.pumpAndSettle();
        t.view.physicalSize = clientSize;
        await t.pumpAndSettle();
        await t.tap(find.text('查询'));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        expect(t.getSize(find.byType(Trend)).height, greaterThanOrEqualTo(140));
        await t.ensureVisible(find.byType(Trend));
        await t.pumpAndSettle();
        expect(find.byType(Trend).hitTestable(), findsOneWidget);
        await t.ensureVisible(find.widgetWithText(ChoiceChip, '数据'));
        await t.pumpAndSettle();
        await t.tap(find.widgetWithText(ChoiceChip, '数据'));
        await t.pumpAndSettle();
        expect(find.text('0.25'), findsOneWidget);
        await t.ensureVisible(find.text('下一页'));
        await t.pumpAndSettle();
        expect(find.text('下一页').hitTestable(), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
      },
    );
  }

  for (final size in [const Size(420, 360), const Size(640, 480)]) {
    testWidgets('trend has a usable chart and table at $size', (t) async {
      await open(t, TrendLayoutApi(), size);
      await t.tap(find.text('查询'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(t.getSize(find.byType(Trend)).height, greaterThanOrEqualTo(140));
      expect(find.textContaining('UTC+8'), findsOneWidget);
      expect(find.textContaining('仅当前页'), findsOneWidget);
      final chartState = t.state(find.byType(Trend));
      await t.tap(find.widgetWithText(ChoiceChip, '数据'));
      await t.pumpAndSettle();
      expect(
        t.getSize(find.byType(DenseTable)).height,
        greaterThanOrEqualTo(140),
      );
      expect(find.text('0.25'), findsOneWidget);
      await t.tap(find.widgetWithText(ChoiceChip, '曲线'));
      await t.pumpAndSettle();
      expect(t.state(find.byType(Trend)), same(chartState));
      expect(find.text('下一页').hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets(
    'draft cancel preserves range and repeated callbacks cannot pop parent',
    (t) async {
      final api = TrendLayoutApi();
      await open(t, api, const Size(420, 360));
      final button = t.widget<OutlinedButton>(
        find.byKey(const Key('external-trend-range')),
      );
      button.onPressed!();
      button.onPressed!();
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final field = t.widget<TextField>(
        find.byKey(const Key('external-range-from')),
      );
      final original = field.controller!.value;
      field.controller!.value = const TextEditingValue(
        text: '草稿时间',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      );
      final cancel = t.widget<TextButton>(
        find.widgetWithText(TextButton, '取消'),
      );
      cancel.onPressed!();
      cancel.onPressed!();
      await t.pumpAndSettle();
      expect(find.byType(ExternalQuery), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await range(t);
      expect(
        t
            .widget<TextField>(find.byKey(const Key('external-range-from')))
            .controller!
            .value,
        original,
      );
      await t.enterText(
        find.byKey(const Key('external-range-from')),
        '2026-10-20T00:00',
      );
      final apply = t.widget<FilledButton>(
        find.widgetWithText(FilledButton, '应用并查询'),
      );
      apply.onPressed!();
      apply.onPressed!();
      await t.pumpAndSettle();
      expect(api.bodies, hasLength(1));
      expect(api.bodies.single['from'], '2026-10-20T00:00');
      expect(api.bodies.single['offset'], 0);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'pagination and selected trend point survive width and height changes',
    (t) async {
      final api = TrendLayoutApi();
      await open(t, api, const Size(640, 480));
      await t.tap(find.text('查询'));
      await t.pumpAndSettle();
      await t.tap(find.text('下一页'));
      await t.pumpAndSettle();
      expect(api.bodies.last['offset'], 500);
      final dropdown = t.widget<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>),
      );
      dropdown.onChanged!(1);
      await t.pumpAndSettle();
      t.view.physicalSize = const Size(1366, 900);
      await t.pumpAndSettle();
      expect(
        t
            .widget<DropdownButtonFormField<int>>(
              find.byType(DropdownButtonFormField<int>),
            )
            .initialValue,
        1,
      );
      expect(api.bodies, hasLength(2));
      t.view.physicalSize = const Size(420, 360);
      await t.pumpAndSettle();
      expect(
        t
            .widget<DropdownButtonFormField<int>>(
              find.byType(DropdownButtonFormField<int>),
            )
            .initialValue,
        1,
      );
      expect(find.textContaining('第 2 页'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'cancel pending applied query permits another range dialog and ignores old result',
    (t) async {
      final api = TrendLayoutApi()..pending = Completer<Json>();
      await open(t, api, const Size(420, 360));
      await range(t);
      await t.tap(find.text('应用并查询'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('取消等待').hitTestable(), findsOneWidget);
      await t.tap(find.text('取消等待'));
      await t.pumpAndSettle();
      await range(t);
      expect(find.byType(AlertDialog), findsOneWidget);
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      api.pending!.complete({});
      await t.pumpAndSettle();
      expect(find.byType(Trend), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
}
