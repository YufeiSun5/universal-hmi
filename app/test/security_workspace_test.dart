import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/security_workspace.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'public_access_test.dart' show PublicPolicyApi;

void main() {
  testWidgets(
    'security pages and forms stay inline; switching preserves drafts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 850);
      addTearDown(tester.view.reset);
      final api = PublicPolicyApi();
      var section = 4;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(false),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return SecurityWorkspace(
                  api: api,
                  section: section,
                  canManageUsers: true,
                  accountBuilder: (_) => const Text('测试账号页'),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byTooltip('关闭白名单'), findsNothing);
      await tester.tap(find.text('添加规则'));
      await tester.pumpAndSettle();
      expect(find.text('白名单规则'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.enterText(find.byType(TextField).first, '192.168.20.0/24');
      update(() => section = 0);
      await tester.pumpAndSettle();
      expect(find.text('测试账号页'), findsOneWidget);
      update(() => section = 4);
      await tester.pumpAndSettle();
      expect(find.text('192.168.20.0/24'), findsOneWidget);
      await tester.tap(find.text('应用到草稿'));
      await tester.pumpAndSettle();
      expect(find.text('未保存修改'), findsOneWidget);
      expect(api.policyWrites, isEmpty);
      await tester.tap(find.text('保存策略'));
      await tester.pumpAndSettle();
      // Confirmation is another content page, not a modal dialog.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
