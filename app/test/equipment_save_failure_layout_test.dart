import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/equipment/editor.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'equipment_test.dart' show LedgerApi;

class SaveAttemptApi extends LedgerApi {
  final attempts = <Json>[];

  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) {
    if (method == 'POST' && path == '/api/v1/equipment') {
      attempts.add(Map<String, dynamic>.from(body as Map));
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets(
    'short equipment dialog exposes save failure and permits one retry',
    (tester) async {
      tester.view.physicalSize = const Size(420, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = SaveAttemptApi()..failSave = true;
      Json? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<Json>(
                    context: context,
                    builder: (_) => EquipmentEditor(
                      api: api,
                      stations: const ['城北站区'],
                      device: api.device,
                    ),
                  );
                },
                child: const Text('打开设备'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开设备'));
      await tester.pumpAndSettle();
      final name = find.byKey(const Key('equipment-field-name'));
      await tester.ensureVisible(name);
      await tester.pumpAndSettle();
      await tester.enterText(name, '冲突后保留的合成设备名称');
      final save = find.byKey(const Key('equipment-save'));
      expect(save.hitTestable(), findsOneWidget);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('档案版本冲突').hitTestable(), findsOneWidget);
      expect(save.hitTestable(), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(
        tester.widget<TextFormField>(name).controller!.text,
        '冲突后保留的合成设备名称',
      );
      expect(api.attempts, hasLength(1));
      expect(api.attempts.single['revision'], 1);
      expect(result, isNull);
      expect(tester.takeException(), isNull);

      api.failSave = false;
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(api.attempts, hasLength(2));
      expect(api.attempts.last, api.attempts.first);
      expect(result?['name'], '冲突后保留的合成设备名称');
      expect(result?['revision'], 2);
      expect(find.byType(EquipmentEditor), findsNothing);
      expect(find.text('打开设备').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
