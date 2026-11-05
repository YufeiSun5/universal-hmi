import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/dynamic_display.dart';
import 'package:universal_hmi/features/process/display_editor.dart';
import 'package:universal_hmi/features/process/scene.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'package:universal_hmi/features/process/subscriptions.dart';
import 'package:universal_hmi/shared/api.dart';

ScreenElement lamp() =>
    ScreenElement.create(
      'symbol',
      const Offset(20, 20),
      symbol: 'monitor_pump',
    ).update({
      'id': 'lamp',
      'point_id': 'state',
      'state_display': defaultStateDisplay(),
    });
ScreenElement level() =>
    ScreenElement.create('level', const Offset(100, 20)).update({
      'id': 'level',
      'point_id': 'level',
      'level_display': {
        'minimum': -20.0,
        'maximum': 80.0,
        'orientation': 'vertical',
      },
    });
ScreenDocument drawing(List<ScreenElement> nodes) => ScreenDocument(
  id: 'screen',
  name: '显示验收',
  station: 'A',
  width: 600,
  height: 300,
  nodes: nodes,
);
const defs = <String, Json>{
  'state': {'name': '泵反馈', 'station': 'B'},
  'level': {'name': '水箱液位', 'station': 'B'},
};
Map<String, Json> sample(String id, Object? value, {String quality = 'good'}) =>
    {
      id: {'value': value, 'quality': quality},
    };

void main() {
  test(
    'lamp matches two explicit numeric or BOOL values and never guesses unknown',
    () {
      final n = lamp(), d = drawing([lamp()]);
      for (final raw in [1, true]) {
        final result = processStateDisplay(
          n,
          d,
          defs,
          sample('state', raw),
          true,
        );
        expect(result.text, '运行');
        expect(result.color, const Color(0xff16a34a));
      }
      for (final raw in [0, false]) {
        expect(
          processStateDisplay(n, d, defs, sample('state', raw), true).text,
          '停止',
        );
      }
      for (final raw in [2, -1, '1', null, double.nan]) {
        final result = processStateDisplay(
          n,
          d,
          defs,
          sample('state', raw),
          true,
        );
        expect(result.known, isFalse);
        expect(result.color, unknownDisplayColor);
      }
      for (final quality in ['bad', 'stale', 'uncertain', 'other']) {
        expect(
          processStateDisplay(
            n,
            d,
            defs,
            sample('state', 1, quality: quality),
            true,
          ).known,
          isFalse,
        );
      }
      expect(
        processStateDisplay(n, d, defs, sample('state', 1), false).known,
        isFalse,
      );
      expect(
        processStateDisplay(n, d, {}, sample('state', 1), true).known,
        isFalse,
      );
      final reverse = n.update({
        'state_display': {
          ...defaultStateDisplay(valve: true),
          'active_value': 0,
          'inactive_value': 1,
        },
      });
      expect(
        processStateDisplay(reverse, d, defs, sample('state', 0), true).text,
        '开启',
      );
      expect(
        processStateDisplay(reverse, d, defs, sample('state', 1), true).text,
        '关闭',
      );
    },
  );

  test(
    'level uses engineering range and retains out-of-range percentage and valid zero',
    () {
      final n = level(), d = drawing([level()]);
      for (final test in [
        (-20.0, 0.0),
        (0.0, .2),
        (30.0, .5),
        (80.0, 1.0),
        (100.0, 1.2),
        (-40.0, -.2),
      ]) {
        final result = processLevelDisplay(
          n,
          d,
          defs,
          sample('level', test.$1),
          true,
        );
        expect(result.ratio, closeTo(test.$2, 1e-9));
        expect(result.fraction, test.$2.clamp(0.0, 1.0));
      }
      expect(
        processLevelDisplay(n, d, defs, sample('level', 100), true).text,
        '120.0%',
      );
      expect(
        processLevelDisplay(n, d, defs, sample('level', 100), true).note,
        '高于上限',
      );
      for (final raw in [null, true, '20', double.infinity]) {
        expect(
          processLevelDisplay(n, d, defs, sample('level', raw), true).ratio,
          isNull,
        );
      }
      expect(
        processLevelDisplay(
          n,
          d,
          defs,
          sample('level', 0, quality: 'bad'),
          true,
        ).text,
        '—',
      );
      expect(
        processLevelDisplay(n, d, defs, sample('level', 0), false).ratio,
        isNull,
      );
      expect(
        () => validateProcessDisplay(
          n.update({
            'level_display': {
              'minimum': 5,
              'maximum': 5,
              'orientation': 'vertical',
            },
          }),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'display template and copy clear identities but preserve rules, limits and subscription projection',
    () {
      final d = drawing([lamp(), level()]);
      d.checkGeometry();
      final decoded = ScreenDocument.fromJson(
        jsonDecode(jsonEncode(d.toJson())) as Json,
      );
      expect(decoded.nodes[0].stateDisplay, d.nodes[0].stateDisplay);
      expect(decoded.nodes[1].levelDisplay, d.nodes[1].levelDisplay);
      expect(processSubscriptionIDs(decoded), {'state', 'level'});
      for (final copy in [d.toTemplate(), d.instantiate('C')]) {
        expect(processSubscriptionIDs(copy), isEmpty);
        expect(copy.nodes[0].stateDisplay, d.nodes[0].stateDisplay);
        expect(copy.nodes[1].levelDisplay, d.nodes[1].levelDisplay);
      }
      expect(d.bindingOverlay['level']['point_id'], 'level');
      expect(
        () => d
            .copy(
              nodes: [
                lamp().update({
                  'state_display': {
                    ...defaultStateDisplay(),
                    'inactive_value': 1,
                  },
                }),
              ],
            )
            .checkGeometry(),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'scene updates lamp, percentage and unknown status without recoloring pump artwork',
    (tester) async {
      const symbols = [
        ProcessSymbol(
          'monitor_pump',
          '泵',
          '设备',
          'assets/process/examples/inline-pump-v1.png',
          tintable: false,
        ),
      ];
      final pump =
          ScreenElement.create(
            'symbol',
            const Offset(200, 30),
            symbol: 'monitor_pump',
          ).update({
            'id': 'pump',
            'point_id': 'state',
            'state_display': defaultStateDisplay(),
          });
      final d = drawing([lamp(), level(), pump]);
      Future<void> show(Object state, Object raw, {bool online = true}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ProcessScene(
                document: d,
                symbols: {for (final s in symbols) s.id: s},
                definitions: defs,
                live: {...sample('state', state), ...sample('level', raw)},
                online: online,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await show(1, 30);
      expect(find.text('50.0%'), findsOneWidget);
      expect(
        tester
            .widget<StatusLamp>(find.byKey(const Key('process-state-pump')))
            .color,
        const Color(0xff16a34a),
      );
      expect(find.byType(ColorFiltered), findsNothing);
      await show(0, 100);
      expect(find.text('120.0%\n高于上限'), findsOneWidget);
      expect(
        tester
            .widget<StatusLamp>(find.byKey(const Key('process-state-pump')))
            .color,
        const Color(0xffdc2626),
      );
      await show(1, 30, online: false);
      expect(find.text('未知'), findsOneWidget);
      expect(
        tester
            .widget<StatusLamp>(find.byKey(const Key('process-state-pump')))
            .color,
        unknownDisplayColor,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'range editor keeps invalid draft open then submits correct limits',
    (tester) async {
      Json? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<Json>(
                    context: context,
                    builder: (_) => ProcessDisplayEditor(node: level()),
                  );
                },
                child: const Text('编辑比例柱'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑比例柱'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('display-maximum')), '-30');
      await tester.tap(find.text('应用到草稿'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.textContaining('上限必须大于下限'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('display-maximum')), '180');
      await tester.tap(find.text('应用到草稿'));
      await tester.pumpAndSettle();
      expect(result?['minimum'], -20);
      expect(result?['maximum'], 180);
      expect(tester.takeException(), isNull);
    },
  );
}
