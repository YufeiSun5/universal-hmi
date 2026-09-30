import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';

class FakeApi implements PlatformApi {
  final List<PointDefinition> points = [];

  @override
  Future<void> checkHealth() async {}

  @override
  Future<List<PointDefinition>> listPoints() async => [...points];

  @override
  Future<PointDefinition> addPoint(Map<String, dynamic> input) async {
    final point = PointDefinition(
      id: 'point-${points.length}',
      station: input['station'] as String,
      name: input['name'] as String,
      dataType: input['data_type'] as String,
      sourceType: input['source_type'] as String,
      unit: input['unit'] as String,
      scaleFactor: input['scale_factor'] as double,
      offset: input['offset'] as double,
    );
    points.add(point);
    return point;
  }

  @override
  void close() {}
}

void main() {
  testWidgets('point configuration saves and appears after refresh', (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeApi();
    await tester.pumpWidget(UniversalHmiApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加点位'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('point-station')), 'S01');
    await tester.enterText(find.byKey(const Key('point-name')), 'Temperature');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(api.points, hasLength(1));
    expect(find.text('Temperature'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('Temperature'), findsOneWidget);
    expect(find.text('实时采集未启用'), findsOneWidget);
  });

  testWidgets('empty required input does not save a point', (tester) async {
    final api = FakeApi();
    await tester.pumpWidget(UniversalHmiApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加点位'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(api.points, isEmpty);
    expect(find.text('请填写此项'), findsNWidgets(2));
  });
}
