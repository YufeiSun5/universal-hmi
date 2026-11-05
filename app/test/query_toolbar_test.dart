import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/query_toolbar.dart';

void main() {
  testWidgets('actions use spare last-row space and align painted controls', (
    t,
  ) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1000, 800);
    addTearDown(t.view.reset);
    final input = TextEditingController(text: 'kept');
    addTearDown(input.dispose);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: QueryToolbar(
              key: const Key('aligned-toolbar'),
              fields: [
                SizedBox(
                  width: 250,
                  child: DropdownButtonFormField<String>(
                    key: const Key('station'),
                    initialValue: 'a',
                    decoration: const InputDecoration(labelText: 'Station'),
                    items: const [
                      DropdownMenuItem(value: 'a', child: Text('Station A')),
                    ],
                    onChanged: (_) {},
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: TextField(
                    key: const Key('search'),
                    controller: input,
                    decoration: const InputDecoration(labelText: 'Search'),
                  ),
                ),
              ],
              actions: [
                FilledButton(onPressed: () {}, child: const Text('Query')),
              ],
            ),
          ),
        ),
      ),
    );
    Finder outline(Key field) => find.descendant(
      of: find.byKey(field),
      matching: find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.foregroundPainter.runtimeType.toString() == '_InputBorderPainter',
      ),
    );
    final action = find.widgetWithText(FilledButton, 'Query');
    for (final width in [1000.0, 430.0, 620.0]) {
      t.view.physicalSize = Size(width, 800);
      await t.pumpAndSettle();
      final station = t.getRect(outline(const Key('station')));
      final search = t.getRect(outline(const Key('search')));
      final button = t.getRect(
        find.descendant(of: action, matching: find.byType(Material)).first,
      );
      expect(button.height, closeTo(search.height, .01));
      expect(button.height, closeTo(station.height, .01));
      expect(button.top, closeTo(search.top, .01));
      expect(button.bottom, closeTo(search.bottom, .01));
      expect(button.right, closeTo(width - 11, .01));
      if (width >= 620) {
        expect(button.top, closeTo(station.top, .01));
        expect(
          t.getSize(find.byKey(const Key('aligned-toolbar'))).height,
          lessThan(65),
        );
      } else {
        expect(search.top, greaterThan(station.bottom));
        expect(
          t.getSize(find.byKey(const Key('aligned-toolbar'))).height,
          lessThan(125),
        );
      }
      expect(input.text, 'kept');
      expect(action.hitTestable(), findsOneWidget);
      expect(t.takeException(), isNull);
    }
  });

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
