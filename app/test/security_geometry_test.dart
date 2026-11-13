import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/security.dart';
import 'package:universal_hmi/features/security_layout.dart';
import 'package:universal_hmi/features/security_page.dart';
import 'package:universal_hmi/features/device_certificates.dart';
import 'package:universal_hmi/features/device_registrations.dart';
import 'package:universal_hmi/features/public_access.dart';
import 'package:universal_hmi/features/public_access_events.dart';
import 'package:universal_hmi/features/public_bans.dart';
import 'package:universal_hmi/features/network_access.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'role_management_test.dart' show RoleApi;
import 'security_management_test.dart' show SecurityApi;
import 'device_registrations_test.dart' show RegistrationsApi, registration;
import 'public_access_test.dart' show PublicPolicyApi, rule;
import 'public_access_events_test.dart' show EventsApi;
import 'network_access_test.dart' show NetworkApi;
import 'support/ui_lint.dart';

void main() {
  for (final size in [
    const Size(390, 800),
    const Size(900, 650),
    const Size(1440, 900),
  ]) {
    for (final name in [
      'users',
      'roles',
      'devices',
      'certificates',
      'whitelist',
      'bans',
      'records',
      'network',
    ]) {
      testWidgets('populated security $name at $size has usable geometry', (
        t,
      ) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = size;
        addTearDown(t.view.reset);
        final policy = PublicPolicyApi()..snapshot['rules'] = [rule()];
        final devices = RegistrationsApi()..items = [registration()];
        final page = switch (name) {
          'users' => SecurityPanel(api: RoleApi()),
          'roles' => SecurityPanel(api: RoleApi(), initialTab: 3),
          'devices' => DeviceRegistrationsPanel(api: devices),
          'certificates' => DeviceCertificatesPanel(api: SecurityApi()),
          'whitelist' => PublicAccessPanel(api: policy),
          'bans' => PublicBansPanel(api: SecurityApi()),
          'records' => PublicAccessEventsPanel(api: EventsApi()),
          _ => NetworkAccessPage(api: NetworkApi()),
        };
        await t.pumpWidget(
          MaterialApp(
            theme: workspaceTheme(),
            home: Scaffold(
              body: SecurityTheme(
                child: SecurityPageScope(root: true, child: page),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expectCleanUI(t, '$name $size initial');
        final scrolls = find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .hitTestable();
        if (scrolls.evaluate().isNotEmpty) {
          await t.drag(scrolls.first, const Offset(0, -460));
          await t.pumpAndSettle();
          expectCleanUI(t, '$name $size scrolled');
        }
      });
    }
  }
}
