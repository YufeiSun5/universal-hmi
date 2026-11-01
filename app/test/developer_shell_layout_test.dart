import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'process_test.dart' show ScreenApi;
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/main.dart' show Workspace;
import 'package:universal_hmi/shared/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'workspace_test.dart' show launch;

class _AlertScreenApi extends ScreenApi {
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    final result = await super.request(method, path, body: body, query: query);
    if (path == '/api/v1/runtime') {
      return {
        ...result,
        'storage_error': 'synthetic disk unavailable',
        'dropped': 123456789,
      };
    }
    return result;
  }
}

void main() {
  for (final station in ['A', '这是用于验证完整站名仍可查看的很长中文换热站名称', '告警站']) {
    testWidgets(
      'real developer shell keeps primary commands after resize: $station',
      (tester) async {
        final api = station == '告警站' ? _AlertScreenApi() : ScreenApi();
        api.rows.add(api.point('a', station));
        api.screens['A1'] = ScreenDocument(
          id: 'A1',
          name: 'A 工艺图',
          station: station,
          revision: 1,
          nodes: [
            ScreenElement.create(
              'value',
              const Offset(100, 100),
            ).update({'point_id': 'a', 'text': '进水温度 '}),
          ],
        ).toJson();
        await tester.runAsync(() => processSymbols);
        await launch(tester, api, size: const Size(1280, 800));
        await tester.tap(find.byKey(Key('station-$station')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('screen-resource-A1')));
        await tester.pumpAndSettle();
        for (final size in [
          const Size(1280, 800),
          const Size(640, 480),
          const Size(420, 360),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          for (final key in [
            'process-save',
            'process-preview',
            'process-transfer',
            'process-screen-selection',
          ]) {
            expect(find.byKey(Key(key)).hitTestable(), findsOneWidget);
          }
          for (final label in ['项目', '数据', '编辑', '查看']) {
            expect(find.text(label).hitTestable(), findsOneWidget);
          }
          expect(
            find.byKey(const Key('display-timezone')).hitTestable(),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('active-station')).hitTestable(),
            findsOneWidget,
          );
          if (station == '告警站') {
            expect(find.text('存储错误  ').hitTestable(), findsOneWidget);
            expect(find.text('丢弃 123456789  ').hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'authenticated developer retains account and logout at narrow width',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(420, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var accountCalls = 0, logoutCalls = 0;
      final api = ScreenApi();
      await tester.pumpWidget(
        MaterialApp(
          theme: workspaceTheme(),
          home: Workspace(
            api: api,
            username: '合成工程师',
            onAccount: () => accountCalls++,
            onLogout: () => logoutCalls++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('账号安全').hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('logout')).hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('账号安全'));
      await tester.tap(find.byKey(const Key('logout')));
      await tester.pumpAndSettle();
      expect(accountCalls, 1);
      expect(logoutCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
