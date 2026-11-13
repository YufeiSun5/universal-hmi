import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/total_reports/bridge.dart';
import 'package:universal_hmi/features/total_reports/workspace.dart';
import 'workspace_test.dart' show FakeApi, launch;

void reply(
  TotalReportBridge bridge,
  Map<String, dynamic> message,
  dynamic result,
) {
  bridge.receive({
    'channel': TotalReportBridge.channel,
    'type': 'response',
    'id': message['id'],
    'result': result,
  });
}

void main() {
  test('Native send hang is bounded by the same request timeout', () async {
    final bridge = TotalReportBridge();
    bridge.send = (_) => Completer<void>().future;
    await expectLater(
      bridge.request('leave', timeout: const Duration(milliseconds: 10)),
      throwsA(isA<TimeoutException>()),
    );
    bridge.dispose();
  });

  test('Disposal resolves waiting response without claiming save', () async {
    final bridge = TotalReportBridge();
    bridge.send = (_) async {};
    final pending = bridge.request('leave');
    bridge.dispose();
    expect(await pending, false);
  });

  testWidgets('Unresponsive report offers recovery and explicit leave', (
    tester,
  ) async {
    await launch(tester, FakeApi());
    await tester.tap(find.byTooltip('总统计报表'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final reports = tester.state<TotalReportsWorkspaceState>(
      find.byType(TotalReportsWorkspace),
    );
    reports.ready = true;
    reports.dirty = true;
    var sent = 0;
    reports.bridge.send = (_) async {
      sent++;
    };
    final first = reports.prepareLeave();
    final second = reports.prepareLeave();
    await tester.pump(const Duration(seconds: 9));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(sent, 1);
    expect(find.text('报表保存尚未确认'), findsOneWidget);
    await tester.tap(find.text('返回报表'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(await first, false);
    expect(await second, false);
    expect(reports.dirty, true);
    // A subsequent module click offers recovery immediately, without another
    // timeout; explicit discard lets the existing navigation finish.
    await tester.tap(find.byTooltip('资源管理器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(sent, 1);
    expect(find.text('报表保存尚未确认'), findsOneWidget);
    await tester.tap(find.text('放弃未确认修改并离开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(TotalReportsWorkspace), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Save rejection can retry, successful confirmation permits leaving',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: TotalReportsWorkspace(api: FakeApi())),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final reports = tester.state<TotalReportsWorkspaceState>(
        find.byType(TotalReportsWorkspace),
      );
      reports.ready = true;
      reports.dirty = true;
      var saveSucceeds = false;
      reports.bridge.send = (data) async {
        final m = jsonDecode(data) as Map<String, dynamic>;
        reply(reports.bridge, m, m['type'] == 'ping' || saveSucceeds);
      };
      final pending = reports.prepareLeave();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('报表保存尚未确认'), findsOneWidget);
      expect(reports.dirty, true);
      saveSucceeds = true;
      await tester.tap(find.text('重试确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(await pending, true);
      expect(reports.dirty, false);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
