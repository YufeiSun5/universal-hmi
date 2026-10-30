import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/bindings_panel.dart';
import 'package:universal_hmi/features/process/controller.dart';
import 'package:universal_hmi/features/process/model.dart';

void main() {
  testWidgets('公共实例可以选择授权跨站变量并保留变量归属', (tester) async {
    final node = ScreenElement.create(
      'value',
      const Offset(40, 40),
    ).update({'id': 'n', 'label': '压力'});
    final controller = ProcessController(
      ScreenDocument(
        id: 's',
        name: '实例',
        station: 'A',
        templateID: 'public',
        templateRevision: 1,
        nodes: [node],
      ),
    );
    final definitions = <String, Map<String, dynamic>>{
      'a': {'id': 'a', 'name': '本站压力', 'station': 'A', 'unit': 'MPa'},
      'b': {'id': 'b', 'name': '跨站温度', 'station': 'B', 'unit': '℃'},
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 500,
            child: ProcessBindingsPanel(
              controller: controller,
              definitions: definitions,
              enabled: true,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('压力'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'B');
    await tester.pumpAndSettle();
    expect(find.text('跨站温度'), findsOneWidget);
    await tester.tap(find.text('跨站温度'));
    await tester.pumpAndSettle();
    expect(controller.document.nodes.single.pointID, 'b');
    expect(controller.document.station, 'A');
    expect(definitions['b']!['station'], 'B');
    expect(find.text('B · 跨站温度 · b'), findsOneWidget);
    controller.dispose();
  });
}
