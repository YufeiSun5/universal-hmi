import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_hmi/platform/connection_bootstrap.dart';

void main() {
  const pem = '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----';
  testWidgets('remote settings can save an empty address draft', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ConnectionBootstrap(
        initialView: null,
        remoteOnly: true,
        settingsOnly: true,
        child: MaterialApp(home: Scaffold()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('空地址草稿已保存'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString('connection.address'),
      '',
    );
  });
  testWidgets('settings save remote selection without starting backend', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'connection.remote': true,
      'connection.address': 'https://example.com:8443',
      'connection.certOrigin': 'https://example.com:8443',
      'connection.certPem': pem,
    });
    var starts = 0;
    await tester.pumpWidget(
      ConnectionBootstrap(
        initialView: null,
        settingsOnly: true,
        child: const MaterialApp(home: Scaffold(body: Text('started'))),
        startBackend: ({initialView, remote}) async {
          starts++;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(starts, 0);
    expect(find.textContaining('设置已保存'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString('connection.address'),
      'https://example.com:8443',
    );
  });
  testWidgets('unconfigured remote-only cannot start local backend', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var starts = 0;
    await tester.pumpWidget(
      ConnectionBootstrap(
        initialView: null,
        remoteOnly: true,
        child: const MaterialApp(home: Scaffold(body: Text('started'))),
        startBackend: ({initialView, remote}) async {
          starts++;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(starts, 0);
    expect(find.textContaining('请输入 HTTPS'), findsOneWidget);
  });
  testWidgets('local-only starts locally without overwriting remote choice', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'connection.remote': true,
      'connection.address': 'https://example.com',
    });
    Uri? endpoint;
    var starts = 0;
    await tester.pumpWidget(
      ConnectionBootstrap(
        initialView: null,
        localOnly: true,
        child: const MaterialApp(home: Scaffold(body: Text('started'))),
        startBackend: ({initialView, remote}) async {
          endpoint = remote;
          starts++;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(starts, 1);
    expect(endpoint, isNull);
    expect(find.text('started'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getBool('connection.remote'),
      true,
    );
  });
}
