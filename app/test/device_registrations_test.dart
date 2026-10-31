import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/device_registrations.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'workspace_test.dart' show FakeApi;

const path = '/api/v1/security/devices';
Json registration() => {
  'id': 'device-a',
  'owner_user_id': 'u1',
  'owner_status': 'active',
  'label': '合成设备',
  'spki_sha256':
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  'state': 'pending',
  'created_at': '2026-10-31T00:00:00Z',
};

class RegistrationsApi extends FakeApi {
  List<Json> items = [];
  int revision = 4;
  final mutations = <Json>[];
  bool failOwners = false, failGet = false, conflict = false;
  Completer<Json>? pendingMutation;
  Json snapshot() => {
    'schema': 1,
    'revision': revision,
    'items': items,
    'mobile_transport_ready': false,
    'grants_access': false,
  };
  @override
  Future<Json> request(
    String method,
    String uri, {
    Object? body,
    Json? query,
  }) async {
    if (uri.endsWith('/users')) {
      if (failOwners) throw const PlatformRequestException(503, 'users');
      return {
        'items': [
          {'id': 'u1', 'username': '合成用户', 'disabled': false},
          {'id': 'u2', 'username': '停用账号', 'disabled': true},
        ],
      };
    }
    if (method == 'GET') {
      if (failGet) throw const PlatformRequestException(503, 'devices');
      return snapshot();
    }
    mutations.add({'path': uri, ...Map<String, dynamic>.from(body! as Map)});
    if (conflict) {
      throw const PlatformRequestException(409, 'device_registration_conflict');
    }
    if (pendingMutation != null) return pendingMutation!.future;
    revision++;
    return snapshot();
  }
}

Future<void> openRegistrations(
  WidgetTester tester,
  RegistrationsApi api, {
  Size size = const Size(1100, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: workspaceTheme(false),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => DeviceRegistrationsPanel(api: api),
            ),
            child: const Text('打开登记'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开登记'));
  await tester.pumpAndSettle();
}

Future<void> fillRegistration(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, '新建设备登记'));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  expect(find.textContaining('停用账号'), findsNothing);
  await tester.tap(find.text('合成用户 · u1').last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('registration-标签')), '合成登记');
  await tester.enterText(
    find.byKey(const Key('registration-已有 CSR PEM')),
    'synthetic public CSR',
  );
}

void main() {
  testWidgets(
    'approval status never means access and full fingerprint is inspectable',
    (tester) async {
      final api = RegistrationsApi()
        ..items = [
          {
            ...registration(),
            'state': 'approved',
            'expires_at': '2099-01-01T00:00:00Z',
          },
        ];
      await openRegistrations(tester, api);
      expect(find.textContaining('登记审批通过，尚未开通手机访问'), findsOneWidget);
      expect(find.textContaining('手机通道未开通'), findsOneWidget);
      expect(find.text('调整登记有效期'), findsOneWidget);
      await tester.tap(find.text('查看 / 复制完整指纹'));
      await tester.pumpAndSettle();
      expect(
        find.text(registration()['spki_sha256'] as String),
        findsOneWidget,
      );
      expect(find.text('复制指纹'), findsOneWidget);
    },
  );
  testWidgets(
    'create uses active owner explicit CSR and one revision; duplicate submit and Back blocked',
    (tester) async {
      final api = RegistrationsApi()..pendingMutation = Completer<Json>();
      await openRegistrations(tester, api);
      await fillRegistration(tester);
      final save = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '提交登记'))
          .onPressed!;
      save();
      save();
      await tester.pump();
      expect(api.mutations, hasLength(1));
      expect(api.mutations.single, {
        'path': path,
        'revision': 4,
        'owner_user_id': 'u1',
        'label': '合成登记',
        'csr_pem': 'synthetic public CSR',
      });
      await tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .maybePop();
      await tester.pump();
      expect(find.byKey(const Key('registration-已有 CSR PEM')), findsOneWidget);
      api.pendingMutation!.complete(api.snapshot());
      await tester.pumpAndSettle();
      expect(find.byType(DeviceRegistrationsPanel), findsOneWidget);
    },
  );
  testWidgets(
    'approve and disable use revision payload, busy outer Back stays and disabled is terminal',
    (tester) async {
      final api = RegistrationsApi()..items = [registration()];
      await openRegistrations(tester, api);
      await tester.tap(find.text('审批登记'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('registration-UTC 到期时间')),
        '2099-01-01T00:00:00Z',
      );
      await tester.tap(find.text('提交登记'));
      await tester.pumpAndSettle();
      expect(api.mutations.single, {
        'path': '$path/device-a/approve',
        'revision': 4,
        'expires_at': '2099-01-01T00:00:00.000Z',
      });
      api.pendingMutation = Completer<Json>();
      await tester.tap(find.text('停用登记'));
      await tester.pumpAndSettle();
      final confirmDisable = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认停用'))
          .onPressed!;
      confirmDisable();
      confirmDisable();
      await tester.pump();
      await tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .maybePop();
      await tester.pump();
      expect(find.byType(DeviceRegistrationsPanel), findsOneWidget);
      expect(api.mutations.last, {
        'path': '$path/device-a/disable',
        'revision': 5,
      });
      api.items = [
        {...registration(), 'state': 'disabled'},
      ];
      api.pendingMutation!.complete(api.snapshot());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '停用登记'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'conflict preserves inputs blocks blind retry and explicit refresh enables reviewed retry',
    (tester) async {
      final api = RegistrationsApi()..conflict = true;
      await openRegistrations(tester, api);
      await fillRegistration(tester);
      await tester.tap(find.text('提交登记'));
      await tester.pumpAndSettle();
      expect(find.text('synthetic public CSR'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交登记'))
            .onPressed,
        isNull,
      );
      api.revision = 9;
      api.conflict = false;
      await tester.tap(find.text('刷新版本并核对'));
      await tester.pumpAndSettle();
      expect(find.textContaining('版本已刷新'), findsOneWidget);
      expect(find.text('synthetic public CSR'), findsOneWidget);
      await tester.tap(find.text('提交登记'));
      await tester.pumpAndSettle();
      expect(api.mutations.last['revision'], 9);
    },
  );
  testWidgets(
    'owner list failure disables creation without erasing existing registrations',
    (tester) async {
      final api = RegistrationsApi()
        ..items = [registration()]
        ..failOwners = true;
      await openRegistrations(tester, api);
      expect(find.textContaining('账号列表不可用'), findsOneWidget);
      expect(find.textContaining('合成设备'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '新建设备登记'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets(
    'failed refresh preserves visible old list with warning, not empty success',
    (tester) async {
      final api = RegistrationsApi()..items = [registration()];
      await openRegistrations(tester, api);
      api.failGet = true;
      await tester.tap(find.text('刷新登记'));
      await tester.pumpAndSettle();
      expect(find.textContaining('上次结果'), findsOneWidget);
      expect(find.textContaining('合成设备'), findsOneWidget);
      expect(find.text('暂无设备登记。'), findsNothing);
    },
  );
  testWidgets(
    'narrow draft cancel and repeated callbacks cannot lose parent or submit',
    (tester) async {
      final api = RegistrationsApi();
      await openRegistrations(tester, api, size: const Size(460, 640));
      await fillRegistration(tester);
      final cancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed!;
      cancel();
      cancel();
      await tester.pumpAndSettle();
      expect(find.text('放弃未提交的登记内容？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('synthetic public CSR'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改'));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceRegistrationsPanel), findsOneWidget);
      expect(api.mutations, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('duplicate clean close preserves underlying management route', (
    tester,
  ) async {
    final api = RegistrationsApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: workspaceTheme(false),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (host) => Scaffold(
                    body: TextButton(
                      onPressed: () => showDialog<void>(
                        context: host,
                        builder: (_) => DeviceRegistrationsPanel(api: api),
                      ),
                      child: const Text('管理页打开登记'),
                    ),
                  ),
                ),
              ),
              child: const Text('进入管理页'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('进入管理页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理页打开登记'));
    await tester.pumpAndSettle();
    final close = tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == '关闭设备登记',
          ),
        )
        .onPressed!;
    close();
    close();
    await tester.pumpAndSettle();
    expect(find.byType(DeviceRegistrationsPanel), findsNothing);
    expect(find.text('管理页打开登记'), findsOneWidget);
    expect(find.text('进入管理页'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
