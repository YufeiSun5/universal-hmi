// Run explicitly with flutter test --platform chrome. No disk-save claim on Web.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:universal_hmi/features/process/transfer.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_transfer_pending_result_test.dart'
    show PendingTransferApi, SyntheticTransferPicker;

void main() {
  for (final remaining in [false, true]) {
    testWidgets(
      'Web export remaining=$remaining only confirms download initiation',
      (tester) async {
        final original = FileSelectorPlatform.instance;
        FileSelectorPlatform.instance = SyntheticTransferPicker();
        addTearDown(() => FileSelectorPlatform.instance = original);
        final api = PendingTransferApi();
        tester.view.physicalSize = const Size(640, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: workspaceTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showProcessTransfer(context, api),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        Future<void> tap(String label) async {
          final target = find.text(label).last;
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          expect(target.hitTestable(), findsOneWidget);
          await tester.tap(target);
          await tester.pumpAndSettle();
        }

        await tap('打开');
        if (remaining) {
          await tap('选择文件');
          await tap('预览');
          await tap('确认保存');
          await tap('导出剩余清单');
          expect(api.commitBodies, hasLength(1));
        } else {
          await tester.tap(find.widgetWithText(ChoiceChip, '导出'));
          await tester.pumpAndSettle();
          await tap('导出');
          expect(api.commitBodies, isEmpty);
        }
        expect(find.text('已发起浏览器下载，请在下载列表确认。'), findsOneWidget);
        expect(find.textContaining('已保存文件：'), findsNothing);
        expect(find.textContaining('已取消保存'), findsNothing);
        // save_web schedules revocation of the synthetic object URL after 10s.
        await tester.pump(const Duration(seconds: 11));
        expect(tester.takeException(), isNull);
      },
      skip: !kIsWeb,
    );
  }
}
