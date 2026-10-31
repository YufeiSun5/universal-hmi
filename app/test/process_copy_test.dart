import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/copy_screen.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/screen_explorer.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'process_test.dart' show ScreenApi;

class LostResponseApi extends ScreenApi {
  bool different = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    final result = await super.request(method, path, body: body, query: query);
    if (method == 'PUT') {
      if (different) screens[result['id']] = {...result, 'name': '其他内容'};
      throw const PlatformRequestException(503, '响应丢失');
    }
    return result;
  }
}

ScreenDocument source({bool linked = false}) => ScreenDocument(
  id: 'source',
  name: '已有工艺',
  station: 'A',
  revision: 4,
  templateID: linked ? 'layout' : '',
  templateRevision: linked ? 2 : 0,
  assets: {'image': EmbeddedImage('图像', 'image/png', 'YQ==')},
  nodes: [
    ScreenElement.create(
      'value',
      const Offset(20, 20),
    ).update({'id': 'reading', 'point_id': 'point-a'}),
    ScreenElement.create('pipe', const Offset(30, 80)).withPoints(
      const [Offset(30, 80), Offset(300, 80)],
      changes: {
        'id': 'pipe',
        'start_node': 'reading',
        'start_port': 'right',
        'arrow_visible_rule': {
          'match': 'all',
          'conditions': [
            {
              'point_id': 'condition-a',
              'slot': 'run',
              'operator': '>',
              'value': 1,
            },
          ],
        },
        'arrow_motion_rule': {
          'match': 'all',
          'conditions': [
            {
              'point_id': 'motion-a',
              'slot': 'run',
              'operator': '>',
              'value': 2,
            },
          ],
        },
      },
    ),
  ],
);

void main() {
  for (final different in [false, true]) {
    testWidgets(
      'lost response verifies persisted content (different=$different)',
      (tester) async {
        final api = LostResponseApi()..different = different;
        ScreenDocument? result;
        final longSource = source().copy(name: '图' * 80);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await copyProcessScreen(
                      context,
                      api,
                      longSource,
                      const ['A'],
                    );
                  },
                  child: const Text('复制'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('复制'));
        await tester.pumpAndSettle();
        final input = tester.widget<TextField>(
          find.byKey(const Key('copy-screen-name')),
        );
        expect(input.controller!.text.length, 80);
        await tester.tap(find.byKey(const Key('copy-screen-save')));
        await tester.pumpAndSettle();
        expect(api.screens.length, 1);
        if (different) {
          expect(result, isNull);
          expect(find.textContaining('复制失败'), findsOneWidget);
          expect(api.screens.values.single['name'], '其他内容');
        } else {
          expect(result!.revision, 1);
          expect(find.byKey(const Key('copy-screen-save')), findsNothing);
        }
      },
    );
  }
  testWidgets(
    'directory copy reads resolved layout and saves cross station independently',
    (tester) async {
      final original = source(linked: true);
      final originalJson = {
        ...original.toJson(),
        'nodes': [for (final n in original.nodes) n.data],
        'assets': original.assets.map((k, v) => MapEntry(k, v.toJson())),
      };
      final before = jsonEncode(originalJson);
      final api = ScreenApi()..screens['source'] = originalJson;
      Map<String, dynamic>? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScreenExplorer(
              api: api,
              stations: const ['A', 'B'],
              station: 'A',
              development: true,
              canWrite: true,
              onStation: (_) {},
              onOpen: (d) => opened = d,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('copy-screen-source')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('copy-screen-name')),
        '复制后的工艺',
      );
      await tester.tap(find.byKey(const Key('copy-screen-station')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('copy-screen-save')));
      await tester.pumpAndSettle();
      final copy = ScreenDocument.fromJson(opened!);
      expect(copy.id, isNot(original.id));
      expect(copy.station, 'B');
      expect(copy.name, '复制后的工艺');
      expect(copy.revision, 1);
      expect(api.savedScreen!['revision'], 0);
      expect(copy.linked, isFalse);
      expect(api.savedScreen!.containsKey('bindings'), isFalse);
      expect(copy.nodes.map((n) => n.id), ['reading', 'pipe']);
      expect(copy.nodes.first.pointID, '');
      expect(copy.nodes.last.startNode, 'reading');
      expect(copy.nodes.last.startPort, 'right');
      expect(copy.nodes.last.points, original.nodes.last.points);
      expect(copy.assets['image']!.data, original.assets['image']!.data);
      for (final key in ['arrow_visible_rule', 'arrow_motion_rule']) {
        expect(
          ((copy.nodes.last.data[key] as Map)['conditions'] as List)
              .single['point_id'],
          '',
        );
      }
      expect(jsonEncode(api.screens['source']), before);
    },
  );

  testWidgets('failed save retains name and public scope for retry', (
    tester,
  ) async {
    final api = ScreenApi()..conflict = true;
    ScreenDocument? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await copyProcessScreen(context, api, source(), const [
                  'A',
                  'B',
                ]);
              },
              child: const Text('复制'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('copy-screen-name')), '重试名称');
    await tester.tap(find.byKey(const Key('copy-screen-station')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('公共画面').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('copy-screen-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('复制失败'), findsOneWidget);
    expect(result, isNull);
    expect(find.text('重试名称'), findsOneWidget);
    api.conflict = false;
    await tester.tap(find.byKey(const Key('copy-screen-save')));
    await tester.pumpAndSettle();
    expect(result!.name, '重试名称');
    expect(result!.station, '');
    expect(api.screens.length, 1);
  });

  testWidgets(
    'editor copies dirty snapshot and keeps source draft without tab host',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1700, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final session = ProcessSession('A')..loaded = true;
      final original = source();
      session.controller.open(original);
      session.controller.rename('未保存草稿');
      final draft = session.controller.document;
      final api = ScreenApi()..screens[original.id] = original.toJson();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcessWorkspace(
              api: api,
              session: session,
              station: 'A',
              stations: const ['A', 'B'],
              definitions: const {},
              live: const {},
              online: true,
              canWrite: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('process-copy-screen')));
      await tester.tap(find.byKey(const Key('process-copy-screen')));
      await tester.pumpAndSettle();
      expect(find.text('未保存草稿 副本'), findsOneWidget);
      await tester.tap(find.byKey(const Key('copy-screen-save')));
      await tester.pumpAndSettle();
      expect(api.savedScreen!['name'], '未保存草稿 副本');
      expect(identical(session.controller.document, draft), isTrue);
      expect(session.controller.dirty, isTrue);
      expect(api.screens['source']!['name'], original.name);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
