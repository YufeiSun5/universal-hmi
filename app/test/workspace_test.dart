import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';

class FakeApi implements PlatformApi {
  final rows = <Json>[];
  bool fail = false;
  int applied = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
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
      return {'version': 'v1'};
    }
    if (path == '/api/v1/jobs') return {'items': []};
    if (path == '/api/v1/runtime') {
      return {
        'version': 'v1',
        'values': [],
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('Saving a point preserves draft until explicit activation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeApi();
    await tester.pumpWidget(UniversalHmiApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加点位'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('point-station')), 'IO-07');
    await tester.enterText(find.byKey(const Key('point-name')), 'Temperature');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(api.rows.single['station'], 'IO-07');
    expect(api.rows.single['name'], 'Temperature');
    expect(api.applied, 0);
    expect(find.text('有未应用配置'), findsOneWidget);
    await tester.tap(find.text('应用配置'));
    await tester.pumpAndSettle();
    expect(api.applied, 1);
    expect(find.text('有未应用配置'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Invalid point remains editable and does not persist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeApi();
    await tester.pumpWidget(UniversalHmiApp(api: api));
    await tester.pumpAndSettle();
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
  testWidgets('Offline status and narrow desktop layouts remain usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeApi()..fail = true;
    await tester.pumpWidget(UniversalHmiApp(api: api));
    await tester.pumpAndSettle();
    expect(find.text('后端离线'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('浅色主题'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Long point labels fit report filters in a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeApi();
    api.rows.add({
      'id': 'long',
      'station': 'Acceptance Station With Long Name',
      'name': 'A very long temperature channel name',
      'data_type': 'FLOAT',
      'source_type': 'manual',
      'unit': 'C',
      'scale_factor': 1,
      'offset': 0,
      'writable': false,
    });
    await tester.pumpWidget(UniversalHmiApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-4')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
