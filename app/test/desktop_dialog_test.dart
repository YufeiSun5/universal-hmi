import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/equipment/editor.dart';
import 'package:universal_hmi/features/security.dart';
import 'package:universal_hmi/shared/desktop_dialog.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'equipment_test.dart' show LedgerApi;
import 'role_management_test.dart' show RoleApi;

void main() {
  for (final size in [
    const Size(1280, 800),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    for (final kind in ['account', 'role', 'equipment']) {
      testWidgets('$kind desktop form keeps actions visible at $size', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final ledger = LedgerApi();
        await tester.pumpWidget(
          MaterialApp(
            theme: workspaceTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  child: const Text('打开'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => switch (kind) {
                      'account' || 'role' => SecurityPanel(api: RoleApi()),
                      _ => EquipmentEditor(
                        api: ledger,
                        stations: const ['城北站区'],
                        device: ledger.device,
                      ),
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        if (kind == 'account') {
          await tester.tap(find.text('新建账号'));
        }
        if (kind == 'role') {
          await tester.tap(find.text('角色管理'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('编辑角色'));
        }
        await tester.pumpAndSettle();
        final action = kind == 'equipment'
            ? find.byKey(const Key('equipment-save'))
            : find.text(kind == 'account' ? '保存权限' : '保存角色');
        expect(action.hitTestable(), findsOneWidget);
        expect(find.text('取消').hitTestable(), findsOneWidget);
        final dialog = kind == 'equipment'
            ? tester.widget<Dialog>(
                find.descendant(
                  of: find.byType(EquipmentEditor),
                  matching: find.byType(Dialog),
                ),
              )
            : tester.widget<AlertDialog>(find.byType(AlertDialog).last);
        if (dialog is Dialog) {
          expect(dialog.shape, DesktopDialogStyle.shape);
        } else if (dialog is AlertDialog) {
          expect(dialog.shape, DesktopDialogStyle.shape);
          expect(dialog.contentPadding, DesktopDialogStyle.contentPadding);
          expect(dialog.actionsPadding, DesktopDialogStyle.actionsPadding);
        }
        if (kind != 'equipment') {
          final scrollbar = tester.widget<Scrollbar>(
            find.descendant(
              of: find.byType(AlertDialog).last,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollbar && widget.thumbVisibility == true,
              ),
            ),
          );
          expect(scrollbar.controller, isNotNull);
          expect(scrollbar.controller!.hasClients, isTrue);
        }
        final savePosition = tester.getCenter(action);
        final scroll = find.byType(SingleChildScrollView).last;
        await tester.drag(scroll, const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(action.hitTestable(), findsOneWidget);
        expect(tester.getCenter(action), savePosition);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(ledger.saved, isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
