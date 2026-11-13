import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/features/materials/workspace.dart';
import 'package:universal_hmi/features/live_overview/workspace.dart';
import 'client_navigation_test.dart' show ClientApi;

void main() {
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets('mobile materials deep link returns overview at $size', (
      t,
    ) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final api = ClientApi();
      await t.pumpWidget(
        MaterialApp(
          home: Workspace(
            api: api,
            canDevelop: false,
            canMaterials: true,
            androidClient: true,
            initialView: 'materials',
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.byType(MaterialsWorkspace), findsNothing);
      expect(find.byType(LiveOverview), findsOneWidget);
      expect(find.text('物料管理'), findsNothing);
      expect(
        api.requests.where((r) => r.contains('/api/v1/materials')),
        isEmpty,
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}
