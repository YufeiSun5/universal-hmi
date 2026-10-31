import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/workspace.dart';
import 'package:universal_hmi/features/external_data/sources.dart';
import 'package:universal_hmi/shared/api.dart';

const screen = {
  'id': 'daily',
  'name': '日报测试',
  'source_id': 'source',
  'kind': 'hourly',
  'revision': 1,
};

class ExternalApi implements PlatformApi {
  final calls = <String>[];
  final bodies = <Json>[];
  Completer<Json>? pending;
  bool fail = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    calls.add('$method $path');
    if (body is Map) bodies.add(Map<String, dynamic>.from(body));
    if (path.endsWith('/stations')) {
      return {
        'items': [
          {'code': 'A', 'name': '外部A区'},
        ],
      };
    }
    if (path.endsWith('/query')) {
      if (pending != null) return pending!.future;
      if (fail) throw const PlatformRequestException(422, '测试查询失败');
      return {
        'points': [
          {'code': 't1', 'name': '供水温度', 'unit': '℃'},
        ],
        'rows': [
          {
            'target_time': '2026-10-27T00:00:00+08:00',
            'sample_time': '2026-10-27T00:00:00+08:00',
            'match': 'exact',
            'quality': 1,
            'values': ['0.00000000'],
          },
          {
            'target_time': '2026-10-27T01:00:00+08:00',
            'sample_time': null,
            'match': 'missing',
            'quality': null,
            'values': [null],
          },
        ],
        'offset': 0,
        'has_more': false,
        'utc_offset_minutes': 480,
      };
    }
    if (path.endsWith('/screens')) {
      return method == 'GET'
          ? {
              'items': [screen],
            }
          : {...body as Json, 'id': 'new', 'revision': 1};
    }
    if (path.endsWith('/sources')) {
      return method == 'GET'
          ? {'items': <Json>[]}
          : {
              ...body as Json,
              'id': 'source',
              'revision': 1,
              'has_password': true,
            };
    }
    throw StateError('Unexpected $method $path');
  }

  @override
  void close() {}
  @override
  Future<Uint8List> download(String id) => throw UnimplementedError();
  @override
  Future<Json> upload(String name, Uint8List bytes) =>
      throw UnimplementedError();
}

Future<void> mount(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(1366, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'external sidebar loads configuration without opening SQL or changing station',
    (t) async {
      final api = ExternalApi();
      final c = ExternalCatalog(api, canDevelop: true);
      Json? opened;
      await mount(
        t,
        SizedBox(
          width: 230,
          child: ExternalDataPanel(
            catalog: c,
            development: true,
            onOpen: (s) => opened = s,
          ),
        ),
      );
      expect(
        api.calls.where((v) => v.contains('/stations') || v.contains('/query')),
        isEmpty,
      );
      await t.tap(find.text('日报测试'));
      await t.pump();
      expect(opened?['id'], 'daily');
      await t.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
  testWidgets(
    'hourly query preserves true zero and missing and clears stale result on failure',
    (t) async {
      final api = ExternalApi();
      await mount(t, ExternalQuery(api: api, screen: screen));
      expect(api.calls.where((v) => v.endsWith('/query')), isEmpty);
      await t.tap(find.text('查询'));
      await t.pumpAndSettle();
      expect(find.text('0.00000000'), findsOneWidget);
      expect(find.text('缺测'), findsWidgets);
      expect(find.text('—'), findsWidgets);
      expect(api.bodies.last['station'], 'A');
      api.fail = true;
      await t.tap(find.text('查询'));
      await t.pumpAndSettle();
      expect(find.text('测试查询失败'), findsOneWidget);
      expect(find.text('0.00000000'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('cancelled query cannot overwrite a later empty selection', (
    t,
  ) async {
    final api = ExternalApi();
    await mount(t, ExternalQuery(api: api, screen: screen));
    api.pending = Completer<Json>();
    await t.tap(find.text('查询'));
    await t.pump();
    await t.tap(find.text('取消等待'));
    await t.pump();
    api.pending!.complete({
      'points': [],
      'rows': [],
      'utc_offset_minutes': 480,
    });
    await t.pumpAndSettle();
    expect(find.textContaining('第 1 页'), findsNothing);
    expect(find.text('选择站区与日期后查询'), findsOneWidget);
  });
  testWidgets(
    'source save preserves TLS and never tests connection automatically',
    (t) async {
      final api = ExternalApi();
      final catalog = ExternalCatalog(api, canDevelop: true)..loaded = true;
      await mount(t, ExternalSources(catalog: catalog, onOpen: (_) {}));
      await t.tap(find.text('添加 SQL Server'));
      await t.pumpAndSettle();
      Future<void> fill(String label, String value) async {
        await t.enterText(find.widgetWithText(TextField, label), value);
      }

      await fill('服务器', '127.0.0.1');
      await fill('SQL Server 登录账号', 'reader');
      await fill('登录密码', 'synthetic-pass');
      await t.tap(find.widgetWithText(FilledButton, '保存连接'));
      await t.pumpAndSettle();
      expect(
        api.calls.any((v) => v.contains('/test') || v.contains('/stations')),
        isFalse,
      );
      expect(api.bodies.single['password'], 'synthetic-pass');
      expect(api.bodies.single['encrypt'], true);
      expect(find.text('添加外部 SQL Server'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      catalog.dispose();
    },
  );
  testWidgets(
    'runtime independent module contains no source or edit controls',
    (t) async {
      final api = ExternalApi();
      final catalog = ExternalCatalog(api, canDevelop: false);
      await mount(
        t,
        ExternalWorkspace(
          catalog: catalog,
          screen: screen,
          onOpen: (_) {},
          showPanel: true,
        ),
      );
      expect(find.text('数据源管理'), findsNothing);
      expect(find.byTooltip('编辑画面名称'), findsNothing);
      expect(api.calls.any((v) => v.contains('/sources')), isFalse);
      expect(find.text('外部站区'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      catalog.dispose();
    },
  );
}
