import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/query_toolbar.dart';

void main() {
  for (final scenario in [(600.0, false), (110.0, false), (600.0, true)]) {
    final (height, landscape) = scenario;
    testWidgets('query stays reachable at $height, landscape=$landscape', (
      t,
    ) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = landscape
          ? const Size(844, 390)
          : const Size(390, 844);
      addTearDown(t.view.reset);
      final controllers = List.generate(7, (_) => TextEditingController());
      addTearDown(() {
        for (final c in controllers) {
          c.dispose();
        }
      });
      String? submitted;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: QueryToolbar(
                key: const Key('toolbar'),
                maxHeight: height,
                minControlHeight: 44,
                fields: [
                  for (var i = 0; i < controllers.length; i++)
                    SizedBox(
                      width: 220,
                      child: TextField(
                        key: ValueKey('field-$i'),
                        controller: controllers[i],
                        decoration: InputDecoration(labelText: 'Condition $i'),
                      ),
                    ),
                ],
                actions: [
                  FilledButton(
                    onPressed: () {
                      submitted = controllers.last.text;
                    },
                    child: const Text('Query'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        t.getSize(find.byKey(const Key('toolbar'))).height,
        lessThanOrEqualTo(landscape ? 78 : 178),
      );
      final query = find.widgetWithText(FilledButton, 'Query');
      expect(query.hitTestable(), findsOneWidget);
      expect(t.getSize(query).height, greaterThanOrEqualTo(44));
      await t.ensureVisible(find.byKey(const ValueKey('field-6')));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const ValueKey('field-6')),
        'retained condition',
      );
      await t.pumpAndSettle();
      expect(query.hitTestable(), findsOneWidget);
      await t.tap(query);
      expect(submitted, 'retained condition');
      expect(t.takeException(), isNull);
    });
  }
}
