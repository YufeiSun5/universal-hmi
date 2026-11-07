import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/online_maintenance.dart';
import 'package:universal_hmi/features/maintenance_permissions.dart';
import 'package:universal_hmi/features/external_data/catalog.dart';
import 'package:universal_hmi/features/external_data/statistics.dart';
import 'package:universal_hmi/shared/table.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'device_registrations_test.dart' show RegistrationsApi;
import 'energy_statistics_test.dart' show EnergyApi;

void main() {
  test('delegation controls match granted capability and resource ceiling', () {
    const policy = GrantEditorPolicy({
      'roles': ['viewer'],
      'user_management': true,
      'device_approval': true,
      'station_ids': ['A'],
      'screen_ids': ['one'],
      'external_screen_ids': ['daily'],
    });
    expect(policy.capability('user_management'), isTrue);
    expect(policy.capability('device_approval'), isTrue);
    expect(policy.capability('certificate_management'), isFalse);
    expect(policy.capability('equipment_edit'), isFalse);
    expect(policy.role('admin'), isFalse);
    expect(policy.screen('one'), isTrue);
    expect(policy.screen('two'), isFalse);
    expect(policy.externalScreen('daily'), isTrue);
    expect(policy.externalScreen('other'), isFalse);
  });
  for (final width in [1440.0, 390.0]) {
    testWidgets('online device approval shows only granted pages at $width', (
      t,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(width, 850);
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: OnlineMaintenancePage(
            api: RegistrationsApi(),
            username: '审批员',
            canManageUsers: false,
            canApproveDevices: true,
            canManageCertificates: false,
            canEditEquipment: false,
            canEditEquipmentNavigation: false,
          ),
        ),
      );
      await t.pumpAndSettle();
      if (width < 850) {
        await t.tap(find.byKey(const Key('maintenance-menu')));
        await t.pumpAndSettle();
      }
      expect(find.text('用户管理'), findsNothing);
      expect(find.text('角色管理'), findsNothing);
      expect(find.text('设备证书'), findsNothing);
      expect(find.text('内网访问'), findsNothing);
      expect(find.text('KP 接入'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
    for (final kind in ['monthly', 'season']) {
      testWidgets(
        '$kind uses daily permission identity and energy-only table at $width',
        (t) async {
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = Size(width, 850);
          addTearDown(t.view.reset);
          final api = EnergyApi()
            ..savedScreen = {'id': 'daily', 'kind': 'daily', 'revision': 1};
          final catalog = ExternalCatalog(api, canDevelop: false)
            ..screens = [api.savedScreen];
          final screen = catalog.historyScreens.firstWhere(
            (s) => s['kind'] == kind,
          );
          expect(screen['query_id'], 'daily');
          await t.pumpWidget(
            MaterialApp(
              theme: workspaceTheme(),
              home: Scaffold(
                body: StatisticsQuery(api: api, screen: screen),
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(api.last?['mode'], kind);
          final table = t.widget<DenseTable>(find.byType(DenseTable));
          expect(table.headers, ['统计周期', '站点', '用量', '用量', '用量']);
          expect(table.rowBuilder!(0), contains('0.00'));
          expect(table.rowBuilder!(0), contains('—'));
          expect(find.text('口径待确认'), findsNothing);
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
