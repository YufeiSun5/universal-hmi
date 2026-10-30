import 'dart:async';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/platform/backend_native.dart';
import 'package:universal_hmi/platform/backend_process.dart';
import 'package:universal_hmi/platform/desktop_lifecycle.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/features/process/gis_screen.dart';
import 'package:universal_hmi/platform/gis_view.dart';
import 'editor_tabs_test.dart' show fixture, open;
import 'workspace_test.dart' show launch;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('role and endpoint identity match equivalent entry points', () {
    for (final view in ['runtime', 'gis', 'process', 'equipment']) {
      expect(desktopRole(view), 'runtime');
    }
    expect(desktopRole('developer'), 'developer');
    expect(desktopRole(null), 'developer');
    expect(
      desktopEndpointIdentity('HTTP://EXAMPLE.COM:80'),
      'http://example.com/',
    );
    expect(
      desktopEndpointIdentity('http://example.com/a/../api/'),
      'http://example.com/api/',
    );
  });

  test(
    'retired workspace unregister cannot remove current exit guard',
    () async {
      final guards = ApplicationExitGuards();
      final removeOld = guards.register(() async => true);
      final removeCurrent = guards.register(() async => false);
      removeOld();
      expect(await guards.canExit(), false);
      removeCurrent();
      expect(await guards.canExit(), true);
    },
  );

  testWidgets(
    'Windows handshake conveys role and rejects duplicate before startup',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      MethodCall? received;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        desktopLifecycleChannel,
        (call) async {
          received = call;
          return false;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          desktopLifecycleChannel,
          null,
        ),
      );
      expect(
        await initializeDesktopLifecycle(
          initialView: 'process',
          endpoint: 'http://localhost:19001',
        ),
        false,
      );
      expect(received!.method, 'initialize');
      expect(received!.arguments, {
        'role': 'runtime',
        'endpoint': 'http://localhost:19001/',
      });
      received = null;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(await initializeDesktopLifecycle(), true);
      expect(received, isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'cancelled exit never stops backend or drains; concurrent requests share guard and retry',
    (tester) async {
      var drains = 0, guards = 0;
      final decision = Completer<bool>();
      final listener = listenForBackendExit(
        LocalBackendProcess(
          isReady: () async => true,
          launch: () async => null,
        ),
        canExit: () {
          guards++;
          return guards == 1 ? decision.future : Future.value(true);
        },
        drainRendering: () async {
          drains++;
        },
      );
      addTearDown(listener.dispose);
      final a = listener.didRequestAppExit();
      final b = listener.didRequestAppExit();
      await tester.pump();
      expect(guards, 1);
      decision.complete(false);
      expect(await a, AppExitResponse.cancel);
      expect(await b, AppExitResponse.cancel);
      expect(drains, 0);
      expect(await listener.didRequestAppExit(), AppExitResponse.exit);
      expect(drains, 1);
      expect(guards, 2);
    },
  );

  testWidgets(
    'exit guard flushes focused process draft, includes hidden GIS, and preserves drafts after failed save',
    (tester) async {
      final api = fixture();
      await launch(tester, api, size: const Size(1700, 1000));
      await open(tester, 'map');
      final gis = tester
          .widget<GisScreen>(find.byType(GisScreen))
          .drafts!['map']!;
      tester.widget<GisView>(find.byType(GisView)).onChanged!({
        'stations': <Map<String, dynamic>>[],
      });
      await tester.pumpAndSettle();
      await open(tester, 'a');
      final session = tester
          .widget<ProcessWorkspace>(find.byType(ProcessWorkspace))
          .session;
      final field = find.descendant(
        of: find.byKey(const ValueKey('screen-name')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '退出前的聚焦输入');
      var request = applicationExitGuards.canExit();
      await tester.pumpAndSettle();
      expect(find.textContaining('有 2 个画面尚未保存'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await request, false);
      expect(session.controller.document.name, '退出前的聚焦输入');
      expect(session.controller.dirty, true);
      expect(gis.dirty, true);
      api.conflict = true;
      request = applicationExitGuards.canExit();
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部保存并退出'));
      await tester.pumpAndSettle();
      expect(await request, false);
      expect(session.controller.dirty, true);
      expect(gis.dirty, true);
      api.conflict = false;
      request = applicationExitGuards.canExit();
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部保存并退出'));
      await tester.pumpAndSettle();
      expect(await request, true);
      expect(session.controller.dirty, false);
      expect(gis.dirty, false);
      expect(api.screens['a']!['name'], '退出前的聚焦输入');
      await tester.pumpWidget(const SizedBox());
      expect(await applicationExitGuards.canExit(), true);
    },
  );

  testWidgets('saving blocks application exit even with no dirty draft', (
    tester,
  ) async {
    final api = fixture();
    await launch(tester, api, size: const Size(1700, 1000));
    await open(tester, 'a');
    final session = tester
        .widget<ProcessWorkspace>(find.byType(ProcessWorkspace))
        .session;
    session.saving = true;
    final decision = applicationExitGuards.canExit();
    await tester.pumpAndSettle();
    expect(find.text('画面正在保存'), findsOneWidget);
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(await decision, false);
    session.saving = false;
    final cleanExit = applicationExitGuards.canExit();
    await tester.pumpAndSettle();
    expect(await cleanExit, true);
    await tester.pumpWidget(const SizedBox());
  });
}
