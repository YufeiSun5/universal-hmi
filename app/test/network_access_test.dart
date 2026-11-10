import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/network_access.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi;

class NetworkApi extends FakeApi {
  final saves = <Json>[];
  bool conflict = false;
  bool applyFailure = false;
  final applies = <Json>[];
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (method == 'PUT') {
      saves.add(Map<String, dynamic>.from(body! as Map));
      if (conflict) throw const PlatformRequestException(409, '配置已改变');
    }
    if (method == 'POST') applies.add(Map<String, dynamic>.from(body! as Map));
    return {
      'apply_available': true,
      if (method == 'POST') ...{
        'phase': applyFailure ? 'failed' : 'applied',
        if (applyFailure) ...{
          'error_code': 'port_in_use',
          'status_error': 'test occupied port',
          'recovery': 'previous_unchanged',
        },
      },
      'revision': 2,
      'enabled': false,
      'address': '192.168.10.6',
      'port': 18443,
      'origin': 'https://192.168.10.6:18443',
      'running': false,
      'public_origin': 'https://203.0.113.1:9090',
      'public_enabled': true,
      'addresses': [
        {'ip': '192.168.10.6', 'interface': '以太网'},
      ],
    };
  }
}

void main() {
  testWidgets('HTTP selection removes certificate setup and saves protocol', (
    tester,
  ) async {
    final api = NetworkApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NetworkAccessPage(api: api)),
      ),
    );
    await tester.pumpAndSettle();
    final protocol = find.byType(DropdownButtonFormField<String>).first;
    await tester.ensureVisible(protocol);
    await tester.tap(protocol);
    await tester.pumpAndSettle();
    await tester.tap(find.text('HTTP（无需安装证书）').last);
    await tester.pumpAndSettle();
    expect(find.text('内网证书'), findsNothing);
    expect(find.text('编辑地址：http://192.168.10.6:18443'), findsOneWidget);
    await tester.tap(find.text('保存入口配置'));
    await tester.pumpAndSettle();
    expect(api.saves.single['protocol'], 'http');
    expect(api.saves.single['port'], 18443);
    expect(tester.takeException(), isNull);
  });
  testWidgets('LAN development is opt in and saved with the network revision', (
    tester,
  ) async {
    final api = NetworkApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NetworkAccessPage(api: api)),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.widgetWithText(SwitchListTile, '允许工程师通过内网 Web 开发');
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存入口配置'));
    await tester.pumpAndSettle();
    expect(api.saves.single['allow_development'], isTrue);
    expect(api.saves.single['revision'], 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'apply confirms saved revision and displays real failure and recovery',
    (tester) async {
      final api = NetworkApi()..applyFailure = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NetworkAccessPage(api: api)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('应用内网配置'));
      await tester.pumpAndSettle();
      expect(api.applies, isEmpty);
      expect(find.textContaining('采集、公网和本机开发端保持运行'), findsOneWidget);
      await tester.tap(find.text('应用内网配置').last);
      await tester.pumpAndSettle();
      expect(api.applies.single['revision'], 2);
      expect(find.textContaining('原监听保持原状'), findsOneWidget);
      expect(find.textContaining('端口被占用'), findsOneWidget);
      expect(find.textContaining('已生效：'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'LAN address is editable; failed save preserves draft and current status',
    (tester) async {
      final api = NetworkApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: NetworkAccessPage(api: api)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('192.168.10.6'), findsOneWidget);
      expect(api.saves, isEmpty);
      await tester.enterText(
        find.widgetWithText(TextField, '内网 IPv4 地址'),
        '192.168.20.8',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Web 端口'), '19443');
      api.conflict = true;
      await tester.tap(find.text('保存入口配置'));
      await tester.pumpAndSettle();
      expect(api.saves.single['address'], '192.168.20.8');
      expect(api.saves.single['port'], 19443);
      expect(find.text('192.168.20.8'), findsOneWidget);
      expect(find.text('配置已改变'), findsOneWidget);
      expect(find.text('当前内网入口未运行'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
