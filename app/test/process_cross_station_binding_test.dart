import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/workspace.dart';
import 'process_test.dart' show ScreenApi;

void main() {
  for (final kind in ['value', 'pipe']) {
    testWidgets('$kind 可搜索并绑定跨站授权变量', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final node = ScreenElement.create(kind, const Offset(100, 100));
      final session = ProcessSession('A')..loaded = true;
      session.controller.open(session.controller.document.copy(nodes: [node]));
      session.controller.select(node.id);
      const definitions = {
        'a': {'id': 'a', 'name': '本地温度', 'station': 'A'},
        'b': {'id': 'b', 'name': '远端压力', 'station': 'B'},
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProcessWorkspace(
              api: ScreenApi(),
              session: session,
              station: 'A',
              definitions: definitions,
              live: const {},
              online: true,
              canWrite: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final trigger = kind == 'pipe'
          ? find.byKey(const Key('pipe-arrow_visible_rule'))
          : find.text('选择点位');
      await tester.ensureVisible(trigger);
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      if (kind == 'pipe') {
        await tester.tap(find.text('绑定实例点位'));
        await tester.pumpAndSettle();
      }
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == '搜索变量：*、?、逗号多条件',
        ),
        '*远端*,不存在?',
      );
      await tester.pumpAndSettle();
      expect(find.text('B · b'), findsOneWidget);
      expect(find.text('A · a'), findsNothing);
      await tester.tap(find.text('远端压力  '));
      await tester.pumpAndSettle();
      if (kind == 'pipe') {
        await tester.tap(find.text('应用条件'));
        await tester.pumpAndSettle();
        final rule =
            session.controller.document.nodes.single.data['arrow_visible_rule']
                as Map;
        expect((rule['conditions'] as List).first['point_id'], 'b');
      } else {
        expect(session.controller.document.nodes.single.pointID, 'b');
      }
      expect(definitions['b']!['station'], 'B');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  }
}
