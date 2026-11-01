import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/public_access.dart';
import 'package:universal_hmi/features/device_registrations.dart';
import 'package:universal_hmi/shared/desktop_dialog.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'public_access_test.dart' show PublicPolicyApi;
import 'device_registrations_test.dart' show RegistrationsApi, registration;

void main() {
  for (final size in [
    const Size(1280, 800),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    for (final kind in ['rule', 'registration', 'approval']) {
      testWidgets(
        '$kind desktop form has fixed actions and visible scroll at $size',
        (t) async {
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = size;
          addTearDown(t.view.resetDevicePixelRatio);
          addTearDown(t.view.resetPhysicalSize);
          final policy = PublicPolicyApi();
          final devices = RegistrationsApi()
            ..items = kind == 'approval' ? [registration()] : [];
          await t.pumpWidget(
            MaterialApp(
              theme: workspaceTheme(),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => kind == 'rule'
                          ? PublicAccessPanel(api: policy)
                          : DeviceRegistrationsPanel(api: devices),
                    ),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          );
          await t.tap(find.text('打开'));
          await t.pumpAndSettle();
          await t.tap(
            find.text(switch (kind) {
              'rule' => '添加规则',
              'approval' => '审批登记',
              _ => '新建设备登记',
            }),
          );
          await t.pumpAndSettle();
          final dialog = find.byType(AlertDialog).last;
          final form = t.widget<AlertDialog>(dialog);
          expect(form.shape, DesktopDialogStyle.shape);
          expect(form.contentPadding, DesktopDialogStyle.contentPadding);
          final action = find.descendant(
            of: dialog,
            matching: find.text(kind == 'rule' ? '应用到草稿' : '提交登记'),
          );
          expect(action.hitTestable(), findsOneWidget);
          final position = t.getCenter(action);
          final title = find.descendant(
            of: dialog,
            matching: find.byType(DesktopDialogTitle),
          );
          final titlePosition = t.getTopLeft(title);
          final scroll = find.descendant(
            of: dialog,
            matching: find.byType(SingleChildScrollView),
          );
          final scrollbar = find.descendant(
            of: dialog,
            matching: find.byWidgetPredicate(
              (w) => w is Scrollbar && w.thumbVisibility == true,
            ),
          );
          expect(scrollbar, findsOneWidget);
          expect(t.widget<Scrollbar>(scrollbar).controller!.hasClients, isTrue);
          if (kind == 'approval') {
            final note = find.text('默认到期为当前时间后 90 天，可编辑；审批不会签发证书或开通访问。');
            final field = find.byKey(const Key('registration-UTC 到期时间'));
            // The floating label needs separation from the multi-line notice.
            expect(field, findsOneWidget);
            expect(
              t.getTopLeft(field).dy - t.getBottomLeft(note).dy,
              greaterThanOrEqualTo(12),
            );
          }
          await t.drag(scroll, const Offset(0, -800));
          await t.pumpAndSettle();
          expect(action.hitTestable(), findsOneWidget);
          expect(t.getCenter(action), position);
          expect(t.getTopLeft(title), titlePosition);
          expect(t.takeException(), isNull);
          await t.tap(find.descendant(of: dialog, matching: find.text('取消')));
          await t.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(policy.policyWrites, isEmpty);
          expect(devices.mutations, isEmpty);
          expect(
            kind == 'rule'
                ? find.byType(PublicAccessPanel)
                : find.byType(DeviceRegistrationsPanel),
            findsOneWidget,
          );
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
