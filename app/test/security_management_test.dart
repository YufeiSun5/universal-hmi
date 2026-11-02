import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/device_certificates.dart';
import 'package:universal_hmi/features/public_bans.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi;

class SecurityApi extends FakeApi {
  final mutations = <Json>[];
  bool failRead = false, conflict = false;
  @override
  Future<Json> request(
    String method,
    String uri, {
    Object? body,
    Json? query,
  }) async {
    if (method == 'POST') {
      mutations.add({'path': uri, ...Map<String, dynamic>.from(body! as Map)});
      if (conflict) throw const PlatformRequestException(409, 'conflict');
      return {'revision': 8, 'items': <Json>[]};
    }
    if (failRead) throw const PlatformRequestException(503, 'unavailable');
    if (uri.endsWith('/devices')) {
      return {
        'items': [
          {
            'id': 'd1',
            'label': '测试手机',
            'owner_user_id': 'u1',
            'state': 'approved',
          },
        ],
      };
    }
    if (uri.endsWith('/public-bans')) {
      return {
        'revision': 7,
        'items': [
          {
            'ip': '192.0.2.5',
            'reason': 'waf',
            'created_at': '2026-11-02',
            'expires_at': '2026-11-03',
          },
        ],
      };
    }
    return {
      'revision': 7,
      'items': [
        {
          'registration_id': 'd1',
          'owner_user_id': 'u1',
          'leaf_sha256': 'leaf',
          'spki_sha256': 'key',
          'expires_at': '2099-01-01T00:00:00Z',
        },
      ],
    };
  }
}

Future<void> open(WidgetTester tester, Widget panel) async {
  tester.view.physicalSize = const Size(1100, 950);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: panel)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'certificate revocation requires confirmation and sends current revision',
    (tester) async {
      final api = SecurityApi();
      await open(tester, DeviceCertificatesPanel(api: api));
      await tester.ensureVisible(find.text('撤销证书授权'));
      await tester.tap(find.text('撤销证书授权'));
      await tester.pumpAndSettle();
      expect(api.mutations, isEmpty);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(api.mutations.single, {
        'path': '/api/v1/security/device-certificates/d1/revoke',
        'revision': 7,
      });
      expect(find.text('撤销证书授权'), findsNothing);
    },
  );
  testWidgets(
    'approval conflict preserves public certificate and stops blind retry',
    (tester) async {
      final api = SecurityApi()..conflict = true;
      await open(tester, DeviceCertificatesPanel(api: api));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试手机 · u1').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'synthetic-public-certificate',
      );
      await tester.ensureVisible(find.text('核对并批准证书'));
      await tester.tap(find.text('核对并批准证书'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(api.mutations.single['revision'], 7);
      expect(api.mutations.single['use_certificate_expiry'], true);
      expect(api.mutations.single.containsKey('expires_at'), false);
      expect(find.text('synthetic-public-certificate'), findsOneWidget);
      expect(find.text('授权已改变，请保留输入并刷新后核对。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '核对并批准证书'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('manual unban is confirmed and CAS guarded', (tester) async {
    final api = SecurityApi();
    await open(tester, PublicBansPanel(api: api));
    await tester.tap(find.text('核对并解封'));
    await tester.pumpAndSettle();
    expect(api.mutations, isEmpty);
    await tester.tap(find.text('确认解封'));
    await tester.pumpAndSettle();
    expect(api.mutations.single, {
      'path': '/api/v1/security/public-bans/unban',
      'revision': 7,
      'ip': '192.0.2.5',
    });
    expect(find.text('当前没有有效封禁。'), findsOneWidget);
  });
  testWidgets('failed ban refresh cannot present stale list as current', (
    tester,
  ) async {
    final api = SecurityApi();
    await open(tester, PublicBansPanel(api: api));
    api.failRead = true;
    await tester.tap(find.text('刷新封禁'));
    await tester.pumpAndSettle();
    expect(find.text('读取封禁失败；已有显示不能代表当前状态。'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '核对并解封'))
          .onPressed,
      isNull,
    );
    expect(find.text('当前没有有效封禁。'), findsNothing);
  });
}
