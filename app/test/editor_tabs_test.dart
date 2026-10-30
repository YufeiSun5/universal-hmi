import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/features/process/gis_screen.dart';
import 'package:universal_hmi/platform/gis_view.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_test.dart' show ScreenApi;
import 'workspace_test.dart' show launch;

class TabApi extends ScreenApi {
  Completer<Json>? delayedA;
  Completer<Json>? delayedSave;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) {
    if (method == 'PUT' && delayedSave != null) return delayedSave!.future;
    if (method == 'GET' && path == '/api/v1/screens/a' && delayedA != null) {
      return delayedA!.future;
    }
    return super.request(method, path, body: body, query: query);
  }
}

TabApi fixture() => TabApi()
  ..screens.addAll({
    for (final id in ['a', 'b', 'map'])
      id: ScreenDocument(
        id: id,
        name: '画面 $id',
        station: '',
        revision: 1,
        kind: id == 'map' ? 'gis' : 'process',
      ).toJson(),
  });

Future<void> open(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('screen-resource-$id')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'tab context owns its menus and restores the workspace view and GIS preview',
    (tester) async {
      final api = fixture();
      await launch(tester, api, size: const Size(1700, 1000));
      await tester.tap(find.byKey(const Key('nav-8')));
      await tester.pumpAndSettle();
      await open(tester, 'map');
      expect(find.byKey(const ValueKey('workspace-navigation-')), findsNothing);
      expect(find.byKey(const Key('nav-8')), findsNothing);
      expect(find.text('保存画面'), findsOneWidget);
      await tester.tap(find.text('预览'));
      await tester.pumpAndSettle();
      expect(find.text('返回编辑'), findsOneWidget);
      expect(find.text('地图站点'), findsNothing);
      await open(tester, 'a');
      expect(find.byKey(const Key('nav-6')), findsNothing);
      expect(find.byType(ProcessWorkspace), findsOneWidget);
      expect(find.byTooltip('显示素材库'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('workspace-tab-')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('workspace-navigation-')),
        findsOneWidget,
      );
      expect(find.byType(GisScreen), findsNothing);
      expect(find.byType(ProcessWorkspace), findsNothing);
      // The restored menu is active, rather than silently returning to overview.
      final monitor = tester.widget<TextButton>(find.byKey(const Key('nav-8')));
      expect(
        monitor.style!.foregroundColor!.resolve({}),
        WorkbenchColors.accent,
      );
      await tester.tap(find.byKey(const ValueKey('editor-tab-map')));
      await tester.pumpAndSettle();
      expect(find.text('返回编辑'), findsOneWidget);
      expect(find.text('地图站点'), findsNothing);
      await tester.tap(find.text('返回编辑'));
      await tester.pumpAndSettle();
      expect(find.text('地图站点'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('close-editor-tab-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('close-editor-tab-map')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('workspace-navigation-')),
        findsOneWidget,
      );
      expect(find.byType(GisScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'saving GIS continues across tab switches and updates the retained revision',
    (tester) async {
      final api = fixture();
      await launch(tester, api, size: const Size(1700, 1000));
      await open(tester, 'map');
      final draft = tester
          .widget<GisScreen>(find.byType(GisScreen))
          .drafts!['map']!;
      tester.widget<GisView>(find.byType(GisView)).onChanged!({
        'stations': <Json>[],
      });
      await tester.pumpAndSettle();
      api.delayedSave = Completer<Json>();
      await tester.tap(find.text('保存画面'));
      await tester.pump();
      await open(tester, 'b');
      expect(draft.saving, isTrue);
      api.delayedSave!.complete({...draft.document, 'revision': 2});
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-tab-map')));
      await tester.pumpAndSettle();
      expect(draft.document['revision'], 2);
      expect(draft.dirty, isFalse);
      expect(draft.saving, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'same-scope documents and GIS retain independent drafts, tabs deduplicate and dirty close cancels',
    (tester) async {
      final api = fixture();
      await launch(tester, api, size: const Size(1700, 1000));
      await open(tester, 'a');
      final a = tester
          .widget<ProcessWorkspace>(find.byType(ProcessWorkspace))
          .session;
      final field = find.descendant(
        of: find.byKey(const ValueKey('screen-name')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '未保存的 A');
      await open(tester, 'b');
      final b = tester
          .widget<ProcessWorkspace>(find.byType(ProcessWorkspace))
          .session;
      expect(identical(a, b), isFalse);
      expect(a.controller.document.name, '未保存的 A');
      expect(a.controller.dirty, isTrue);
      expect(b.controller.document.name, '画面 b');
      await open(tester, 'map');
      final map = tester.widget<GisScreen>(find.byType(GisScreen));
      tester.widget<GisView>(find.byType(GisView)).onChanged!({
        'stations': <Json>[],
      });
      await tester.pumpAndSettle();
      expect(map.drafts!['map']!.dirty, isTrue);
      await tester.tap(find.byKey(const ValueKey('editor-tab-a')));
      await tester.pumpAndSettle();
      expect(
        identical(
          tester
              .widget<ProcessWorkspace>(find.byType(ProcessWorkspace))
              .session,
          a,
        ),
        isTrue,
      );
      expect(a.controller.canUndo, isTrue);
      await open(tester, 'a');
      expect(find.byKey(const ValueKey('editor-tab-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-tab-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-tab-map')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('close-editor-tab-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-tab-a')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('close-editor-tab-b')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-tab-b')), findsNothing);
      expect(a.controller.document.name, '未保存的 A');
      await tester.tap(find.byKey(const ValueKey('close-editor-tab-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃修改并关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(GisScreen), findsOneWidget);
      expect(
        tester.widget<GisScreen>(find.byType(GisScreen)).drafts!['map']!.dirty,
        isTrue,
      );
      expect(api.screens['a']!['name'], '画面 a');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new template opens separately and a late load cannot replace the selected tab',
    (tester) async {
      final api = fixture();
      await launch(tester, api, size: const Size(1700, 1000));
      api.delayedA = Completer<Json>();
      await open(tester, 'a');
      await open(tester, 'b');
      api.delayedA!.complete(api.screens['a']);
      await tester.pumpAndSettle();
      final b = tester
          .widget<ProcessWorkspace>(find.byType(ProcessWorkspace))
          .session;
      expect(b.controller.document.id, 'b');
      await tester.tap(find.text('添加画面'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('template-builtin-blank')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('new-screen-name')), '独立新图');
      await tester.tap(find.text('添加并打开'));
      await tester.pumpAndSettle();
      final created = tester
          .widget<ProcessWorkspace>(find.byType(ProcessWorkspace))
          .session;
      expect(created.controller.document.name, '独立新图');
      expect(created.controller.dirty, isFalse);
      expect(find.byKey(const ValueKey('editor-tab-b')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-tab-b')));
      await tester.pumpAndSettle();
      expect(
        identical(
          tester
              .widget<ProcessWorkspace>(find.byType(ProcessWorkspace))
              .session,
          b,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'save and close retains the draft on conflict and closes only after successful save',
    (tester) async {
      final api = fixture();
      await launch(tester, api, size: const Size(1700, 1000));
      await open(tester, 'a');
      final session = tester
          .widget<ProcessWorkspace>(find.byType(ProcessWorkspace))
          .session;
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('screen-name')),
          matching: find.byType(TextField),
        ),
        '保存后关闭',
      );
      api.conflict = true;
      await tester.tap(find.byKey(const ValueKey('close-editor-tab-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并关闭'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-tab-a')), findsOneWidget);
      expect(session.controller.dirty, isTrue);
      expect(session.controller.document.name, '保存后关闭');
      api.conflict = false;
      await tester.tap(find.byKey(const ValueKey('close-editor-tab-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并关闭'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('editor-tab-a')), findsNothing);
      expect(api.screens['a']!['name'], '保存后关闭');
      expect(api.screens['a']!['revision'], 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
