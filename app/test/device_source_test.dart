import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/security_layout.dart';
import 'device_registrations_test.dart';

void main() {
  testWidgets(
    'sources, first request IP, details and filters distinguish devices',
    (t) async {
      final api = RegistrationsApi()
        ..items = [
          {
            ...registration(),
            'id': 'windows',
            'client_kind': 'windows_browser',
            'login_leaf_pem': 'synthetic',
            'state': 'approved',
            'request_ip': '192.0.2.20',
            'created_at': '2026-11-05T02:00:00Z',
          },
          {
            ...registration(),
            'id': 'phone',
            'client_kind': 'android',
            'login_leaf_pem': 'synthetic',
            'request_ip': '192.0.2.10',
            'created_at': '2026-11-04T00:00:00Z',
          },
          {
            ...registration(),
            'id': 'old',
            'client_kind': 'unknown',
            'login_leaf_pem': 'synthetic',
            'created_at': '2026-11-03T00:00:00Z',
          },
        ];
      await openRegistrations(t, api, size: const Size(1280, 1000));
      expect(
        t.widget<SecurityDetails>(find.byType(SecurityDetails).first).key,
        const ValueKey('device-record-phone'),
      );
      await t.enterText(find.byKey(const Key('device-search')), '192.0.2.10');
      await t.pumpAndSettle();
      expect(find.text('安卓 App · 设备 01234567'), findsOneWidget);
      expect(find.text('申请时间：2026-11-04 08:00'), findsOneWidget);
      expect(find.byKey(const ValueKey('device-record-windows')), findsNothing);
      expect(find.text('安装登记 ID：phone'), findsNothing);
      await t.ensureVisible(find.text('设备详情'));
      await t.tap(find.text('设备详情'));
      await t.pumpAndSettle();
      expect(find.text('安装登记 ID：phone'), findsOneWidget);
      expect(find.textContaining('首次申请账号 ID：u1'), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('device-search')));
      await t.enterText(find.byKey(const Key('device-search')), 'old');
      await t.pumpAndSettle();
      expect(find.text('来源未识别 · 设备 01234567'), findsOneWidget);
      expect(find.text('申请 IP：未记录（旧记录或手工登记）'), findsOneWidget);
      await t.enterText(find.byKey(const Key('device-search')), '');
      await t.tap(find.byKey(const Key('device-source-filter')));
      await t.pumpAndSettle();
      await t.tap(find.text('Windows 浏览器').last);
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('device-record-windows')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('device-record-phone')), findsNothing);
      await t.tap(find.byKey(const Key('device-status-filter')));
      await t.pumpAndSettle();
      await t.tap(find.text('待审批').last);
      await t.pumpAndSettle();
      expect(find.text('没有匹配的设备，请调整搜索或筛选。'), findsOneWidget);
      expect(api.mutations, isEmpty);
      expect(t.takeException(), isNull);
    },
  );
}
