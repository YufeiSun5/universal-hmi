import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/public_bans.dart';
import 'package:universal_hmi/features/public_access_events.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';
import 'client_navigation_test.dart' show ClientApi;

class BanApi extends ClientApi {
  int revision = 7;
  final mutations = <Json>[];
  List<Json> bans = [];
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.startsWith('/api/v1/security/public-bans')) {
      if (method == 'POST') {
        final input = body as Json;
        expect(input['revision'], revision);
        mutations.add(input);
        revision++;
        bans = path.endsWith('/ban')
            ? [
                {
                  'ip': input['ip'],
                  'reason': 'manual',
                  'created_at': 'now',
                  'expires_at': 'tomorrow',
                },
              ]
            : [];
      }
      return {'revision': revision, 'items': bans};
    }
    if (path == '/api/v1/security/public-access/events') {
      requests.add('$method $path');
      return {
        'scope': 'self',
        'items': <Json>[],
        'next_before': 0,
        'status': {'enabled': true},
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets(
    'manual ban and unban submit the current revision and explicit duration',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = BanApi();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PublicBansPanel(api: api)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('手动封禁 IP'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '203.0.113.7');
      await tester.tap(find.text('确认封禁'));
      await tester.pumpAndSettle();
      expect(api.mutations.single, {
        'revision': 7,
        'ip': '203.0.113.7',
        'minutes': 1440,
      });
      expect(find.textContaining('管理员手动封禁'), findsOneWidget);
      await tester.tap(find.text('核对并解封'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认解封'));
      await tester.pumpAndSettle();
      expect(api.mutations.last, {'revision': 8, 'ip': '203.0.113.7'});
      expect(find.text('当前没有有效封禁。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final view in ['runtime', 'developer']) {
    testWidgets(
      '$view exposes interception records without granting user management',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final api = BanApi();
        await tester.pumpWidget(
          MaterialApp(
            home: Workspace(
              api: api,
              initialView: view,
              username: 'reader',
              canDevelop: true,
              canManageUsers: false,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (view == 'developer') {
          await tester.tap(find.byTooltip('登录与安全'));
          await tester.pumpAndSettle();
          expect(find.text('用户与访问范围'), findsNothing);
          expect(find.text('公网 Web 白名单'), findsNothing);
        }
        expect(find.byTooltip('拦截与访问记录'), findsOneWidget);
        if (view == 'runtime') expect(find.byTooltip('用户与权限'), findsNothing);
        await tester.tap(find.byTooltip('拦截与访问记录'));
        await tester.pumpAndSettle();
        expect(find.byType(PublicAccessEventsPanel), findsOneWidget);
        expect(find.textContaining('当前范围：本账号'), findsOneWidget);
        expect(
          api.requests,
          contains('GET /api/v1/security/public-access/events'),
        );
        expect(api.mutations, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
