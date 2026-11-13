import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/online_connections.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'public_access_test.dart' show PublicPolicyApi;

class OnlineApi extends PublicPolicyApi {
  bool unavailable = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path != '/api/v1/security/online') {
      return super.request(method, path, body: body, query: query);
    }
    if (unavailable) throw const PlatformRequestException(503, '暂时不可用');
    return {
      'users': 1,
      'connections': 2,
      'items': [
        for (final ip in ['192.168.1.10', '192.168.1.11'])
          {
            'username': '值班员',
            'ip': ip,
            'client': '浏览器',
            'channel': 'lan:http:web',
            'started': '2026-11-10T10:00:00Z',
            'last_seen': '2026-11-10T10:05:00Z',
          },
      ],
    };
  }
}

void main() {
  testWidgets(
    'online count and named connections refresh and clear on error at narrow width',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 700);
      addTearDown(tester.view.reset);
      final api = OnlineApi();
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(false),
          home: Scaffold(body: OnlineConnectionsPanel(api: api)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('在线账号 1 人 · 在线连接 2 个'), findsOneWidget);
      expect(find.text('值班员'), findsNWidgets(2));
      expect(find.textContaining('192.168.1.10'), findsOneWidget);
      expect(tester.takeException(), isNull);
      api.unavailable = true;
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.text('在线数：—'), findsOneWidget);
      expect(find.text('值班员'), findsNothing);
      expect(find.textContaining('无法获取在线状态'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
