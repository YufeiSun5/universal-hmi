import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:universal_hmi/features/mcp_settings.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/mcp_api.dart';

Json state({
  String mode = 'read_only',
  int revision = 1,
  bool canChange = true,
  bool allowWrite = false,
}) => {
  'mode': mode,
  'revision': revision,
  'can_change_mode': canChange,
  'can_enable_write': canChange && allowWrite,
  'startup_write_allowed': allowWrite,
  'available_tool_count': mode == 'off' ? 0 : 1,
};
http.Response json(Json data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
http.Response rpcResponse(http.Request request, {bool probeFails = false}) {
  final body = jsonDecode(request.body) as Json;
  final method = body['method'];
  if (method == 'notifications/initialized') return http.Response('', 202);
  return json({
    'jsonrpc': '2.0',
    'id': body['id'],
    'result': switch (method) {
      'initialize' => {'protocolVersion': mcpProtocolVersion},
      'tools/list' => {
        'tools': [
          {
            'name': 'health_get',
            'annotations': {'readOnlyHint': true},
          },
        ],
      },
      'tools/call' => {
        'isError': probeFails,
        'structuredContent': {'status': 'ok', 'service': 'universal-hmi'},
      },
      _ => <String, dynamic>{},
    },
  });
}

Future<void> panel(WidgetTester tester, PlatformApi api) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: McpSettingsPanel(api: api, endpoint: 'https://hmi.test/mcp'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'connection uses actual fixed route, protocol headers and only read-only probe',
    () async {
      final requests = <http.Request>[];
      final api = PlatformClient(
        Uri.parse('https://hmi.test'),
        client: MockClient((r) async {
          requests.add(r);
          return rpcResponse(r);
        }),
      );
      addTearDown(api.close);
      final report = await McpService(api.scoped()).testConnection();
      expect(report.tools, ['health_get']);
      expect(requests.length, 4);
      for (final request in requests) {
        expect(request.url.toString(), 'https://hmi.test/mcp');
        expect(
          request.headers['Accept'],
          'application/json, text/event-stream',
        );
        expect(request.headers['MCP-Protocol-Version'], mcpProtocolVersion);
        expect(request.followRedirects, false);
      }
      final bodies = requests.map((r) => jsonDecode(r.body) as Json).toList();
      expect(bodies.map((b) => b['method']), [
        'initialize',
        'notifications/initialized',
        'tools/list',
        'tools/call',
      ]);
      expect(bodies.last['params'], {
        'name': 'health_get',
        'arguments': <String, dynamic>{},
      });
    },
  );

  test(
    'connection shares existing session auth and retires stale scope on expiry',
    () async {
      final requests = <http.Request>[];
      var expired = false;
      final api = PlatformClient(
        Uri.parse('https://hmi.test'),
        client: MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/login')) {
            return json({
              'enabled': true,
              'authenticated': true,
              'can_write': true,
              'csrf_token': 'fixture-csrf',
              'bearer_token': 'fixture-bearer',
              'expires_at': DateTime.now()
                  .add(const Duration(hours: 1))
                  .toUtc()
                  .toIso8601String(),
            });
          }
          if (expired) {
            return json({
              'error': {'code': 'authentication_required'},
            }, 401);
          }
          return rpcResponse(r);
        }),
      );
      addTearDown(api.close);
      await api.login('fixture', 'isolated-only');
      final scope = api.scoped();
      await McpService(scope).testConnection();
      for (final r in requests.skip(1)) {
        expect(r.headers['Authorization'], 'Bearer fixture-bearer');
        expect(r.headers['X-CSRF-Token'], 'fixture-csrf');
      }
      expired = true;
      await expectLater(
        McpService(scope).testConnection(),
        throwsA(isA<PlatformRequestException>()),
      );
      expect(api.session!.expired, true);
      final count = requests.length;
      await expectLater(
        McpService(scope).testConnection(),
        throwsA(isA<PlatformRequestException>()),
      );
      expect(requests.length, count);
    },
  );

  test('malformed envelope and tool error never produce success', () async {
    for (final kind in ['wrong-id', 'probe-error', 'empty-tools']) {
      final api = PlatformClient(
        Uri.parse('https://hmi.test'),
        client: MockClient((r) async {
          final body = jsonDecode(r.body) as Json;
          if (kind == 'wrong-id') {
            return json({'jsonrpc': '2.0', 'id': 99, 'result': {}});
          }
          if (kind == 'empty-tools' && body['method'] == 'tools/list') {
            return json({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {'tools': []},
            });
          }
          return rpcResponse(r, probeFails: kind == 'probe-error');
        }),
      );
      await expectLater(
        McpService(api).testConnection(),
        throwsFormatException,
      );
      api.close();
    }
  });

  testWidgets(
    'read-only status is visible and no mode write happens on open or test',
    (tester) async {
      var puts = 0;
      final api = PlatformClient(
        Uri.parse('https://hmi.test'),
        client: MockClient((r) async {
          if (r.method == 'PUT') puts++;
          if (r.url.path == mcpSettingsPath) return json(state());
          return rpcResponse(r);
        }),
      );
      addTearDown(api.close);
      await panel(tester, api);
      expect(find.text('当前模式：只读'), findsOneWidget);
      expect(find.textContaining('服务器启动时未开放'), findsOneWidget);
      expect(find.text('服务端点：https://hmi.test/mcp'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mcp-test')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mcp-test-result')), findsOneWidget);
      expect(puts, 0);
    },
  );

  testWidgets('mode is applied explicitly once, busy blocks repeat actions', (
    tester,
  ) async {
    var current = state(allowWrite: true);
    var puts = 0;
    final gate = Completer<http.Response>();
    final api = PlatformClient(
      Uri.parse('https://hmi.test'),
      client: MockClient((r) async {
        if (r.method == 'PUT') {
          puts++;
          expect(jsonDecode(r.body), {'mode': 'off', 'revision': 1});
          return gate.future;
        }
        return json(current);
      }),
    );
    addTearDown(api.close);
    await panel(tester, api);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭').last);
    await tester.pumpAndSettle();
    expect(puts, 0);
    await tester.tap(find.byKey(const Key('mcp-apply')));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('mcp-apply'))).onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('mcp-test'))).onPressed,
      isNull,
    );
    expect(puts, 1);
    current = state(mode: 'off', revision: 2, allowWrite: true);
    gate.complete(json(current));
    await tester.pumpAndSettle();
    expect(find.text('当前模式：关闭'), findsOneWidget);
    expect(puts, 1);
  });

  testWidgets(
    'reader cannot change mode; test error is visible and retry succeeds',
    (tester) async {
      var failed = true;
      final api = PlatformClient(
        Uri.parse('https://hmi.test'),
        client: MockClient((r) async {
          if (r.url.path == mcpSettingsPath) {
            return json(state(canChange: false, allowWrite: true));
          }
          if (failed) {
            return json({
              'error': {'code': 'mcp_busy'},
            }, 429);
          }
          return rpcResponse(r);
        }),
      );
      addTearDown(api.close);
      await panel(tester, api);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .onChanged,
        isNull,
      );
      await tester.tap(find.byKey(const Key('mcp-test')));
      await tester.pumpAndSettle();
      expect(find.text('MCP 正忙，请稍后再测试'), findsOneWidget);
      expect(find.byKey(const Key('mcp-test-result')), findsNothing);
      failed = false;
      await tester.tap(find.byKey(const Key('mcp-test')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mcp-error')), findsNothing);
      expect(find.byKey(const Key('mcp-test-result')), findsOneWidget);
    },
  );

  testWidgets(
    'disabled transport is tested without automatically enabling it',
    (tester) async {
      var puts = 0, calls = 0;
      final api = PlatformClient(
        Uri.parse('https://hmi.test'),
        client: MockClient((r) async {
          if (r.method == 'PUT') puts++;
          if (r.url.path == mcpSettingsPath) return json(state(mode: 'off'));
          calls++;
          return json({
            'error': {'code': 'mcp_disabled'},
          }, 503);
        }),
      );
      addTearDown(api.close);
      await panel(tester, api);
      await tester.tap(find.byKey(const Key('mcp-test')));
      await tester.pumpAndSettle();
      expect(find.text('MCP 已关闭；可先应用只读模式，再测试连接'), findsOneWidget);
      expect(puts, 0);
      expect(calls, 1);
    },
  );

  testWidgets(
    'dismissed panel ignores late test result and never repeats request',
    (tester) async {
      var calls = 0;
      final gate = Completer<http.Response>();
      final api = PlatformClient(
        Uri.parse('https://hmi.test'),
        client: MockClient((r) async {
          if (r.url.path == mcpSettingsPath) return json(state());
          calls++;
          if (calls == 1) return gate.future;
          return rpcResponse(r);
        }),
      );
      addTearDown(api.close);
      await panel(tester, api);
      await tester.tap(find.byKey(const Key('mcp-test')));
      await tester.pump();
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      gate.complete(
        json({
          'jsonrpc': '2.0',
          'id': 1,
          'result': {'protocolVersion': mcpProtocolVersion},
        }),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Remaining calls are read-only; no automatic mode mutation or retry occurs.
      expect(calls, 4);
    },
  );
}
