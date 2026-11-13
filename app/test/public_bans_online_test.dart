import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/online_maintenance.dart';
import 'package:universal_hmi/features/total_reports/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi;

class BanApi extends FakeApi {
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/security/public-bans') {
      return {
        'revision': 1,
        'items': [
          {
            'ip': '172.16.1.10',
            'reason': 'waf',
            'created_at': '2026-11-12T07:05:56Z',
            'expires_at': '2026-11-12T07:20:56Z',
            'details': {
              'summary': '5 分钟内累计 3 次请求被防护拒绝',
              'entry': '内网入口',
              'method': 'GET',
              'path': '/total-reports/index.html',
              'rules': [
                {'id': 931130, 'description': '远程文件包含特征'},
              ],
            },
          },
        ],
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

class LeaseApi extends FakeApi {
  final pending = Completer<Json>();
  int releases = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/locks')) {
      if (((body as Map)['addresses'] as List).isEmpty) {
        releases++;
        return {'items': [], 'cells': []};
      }
      return pending.future;
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  for (final width in [1440.0, 390.0]) {
    testWidgets(
      'online unban shows specific reason without manual-ban controls at $width',
      (t) async {
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(width, 900);
        addTearDown(t.view.reset);
        await t.pumpWidget(
          MaterialApp(
            home: OnlineMaintenancePage(
              api: BanApi(),
              username: '运维员',
              canManageUsers: false,
              canApproveDevices: false,
              canManageCertificates: false,
              canManagePublicBans: true,
              canEditEquipment: false,
              canEditEquipmentNavigation: false,
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('触发入口：内网入口'), findsOneWidget);
        expect(find.text('规则 931130：远程文件包含特征'), findsOneWidget);
        expect(find.text('手动封禁 IP'), findsNothing);
        expect(find.text('核对并解封'), findsOneWidget);
        expect(t.takeException(), isNull);
      },
    );
  }
  testWidgets('disposing a report releases late in-flight lock again', (
    t,
  ) async {
    final api = LeaseApi();
    await t.pumpWidget(MaterialApp(home: TotalReportsWorkspace(api: api)));
    final state = t.state<TotalReportsWorkspaceState>(
      find.byType(TotalReportsWorkspace),
    );
    final pending = state.receive({
      'type': 'api',
      'id': 'lock-1',
      'method': 'POST',
      'path': '/api/v1/total-reports/electricity/2026/locks',
      'body': {
        'client': 'tab-a',
        'addresses': ['J14'],
      },
    });
    await t.pumpWidget(const SizedBox());
    expect(api.releases, 1);
    api.pending.complete({'items': [], 'cells': []});
    await pending;
    expect(api.releases, 2);
    expect(t.takeException(), isNull);
  });
}
