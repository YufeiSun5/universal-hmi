import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/diagram.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/pipe_flow.dart';
import 'package:universal_hmi/features/process/scene.dart';
import 'package:universal_hmi/features/process/subscriptions.dart';
import 'package:universal_hmi/shared/api.dart';

void main() {
  for (final diagram in [false, true]) {
    testWidgets(
      '${diagram ? 'client diagram' : 'editor scene'} conditions animate across stations and fail closed',
      (tester) async {
        final rule = <String, dynamic>{
          'match': 'all',
          'conditions': [
            {
              'slot': 'running',
              'point_id': 'remote',
              'operator': '>',
              'value': 0,
            },
          ],
        };
        final node = ScreenElement.create('pipe', Offset.zero).withPoints(
          [const Offset(20, 50), const Offset(480, 50)],
          changes: {
            'arrow_animate': true,
            'arrow_mode': 'count',
            'arrow_count': 4,
            'arrow_motion_rule': rule,
          },
        );
        final document = ScreenDocument(
          id: 'test',
          name: 'test',
          station: 'A',
          width: 500,
          height: 240,
          nodes: [node],
        );
        final original = document.toJson().toString();
        expect(processSubscriptionIDs(document), {'remote'});
        const definitions = <String, Json>{
          'remote': {'station': 'B', 'name': '跨站运行'},
        };
        Future<void> draw({
          String quality = 'good',
          Object? value = 1,
          bool online = true,
          bool missing = false,
          bool reverse = false,
          bool animate = true,
          bool arrow = true,
          bool ticker = true,
        }) async {
          final doc = document.copy(
            nodes: [
              node.update({
                'arrow_reverse': reverse,
                'arrow_animate': animate,
                'arrow': arrow,
              }),
            ],
          );
          final live = <String, Json>{
            if (!missing) 'remote': {'quality': quality, 'value': value},
          };
          final Widget child = diagram
              ? ProcessDiagram(
                  document: doc,
                  definitions: definitions,
                  live: live,
                  online: online,
                  symbols: const {},
                  showControls: false,
                )
              : ProcessScene(
                  document: doc,
                  symbols: const {},
                  definitions: definitions,
                  live: live,
                  online: online,
                );
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: TickerMode(
                  enabled: ticker,
                  child: SizedBox(width: 500, height: 240, child: child),
                ),
              ),
            ),
          );
        }

        FlowPipePainter painter() => tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .whereType<FlowPipePainter>()
            .single;
        await draw();
        await tester.pump(const Duration(milliseconds: 100));
        final first = painter().phase;
        await tester.pump(const Duration(seconds: 15));
        expect(painter().phase, greaterThan(first + 800));
        final sustained = painter().phase;
        await draw();
        await tester.pump(const Duration(milliseconds: 100));
        expect(painter().phase, greaterThan(sustained));
        await draw(reverse: true);
        expect(painter().reverse, true);
        await tester.pump(const Duration(milliseconds: 100));
        expect(painter().phase, greaterThan(sustained));
        await draw(ticker: false);
        final hidden = painter().phase;
        await tester.pump(const Duration(seconds: 1));
        expect(painter().phase, hidden);
        await draw(animate: false);
        expect(painter().phase, 0);
        await draw(arrow: false);
        expect(painter().arrow, false);
        expect(painter().phase, 0);
        await draw(value: 0);
        expect(painter().phase, 0);
        expect(find.text('— 箭头条件数据无效'), findsNothing);
        for (final quality in ['bad', 'stale', 'uncertain', 'unknown']) {
          await draw(quality: quality);
          expect(painter().phase, 0);
          expect(find.text('— 箭头条件数据无效'), findsOneWidget);
        }
        await draw(online: false);
        expect(painter().phase, 0);
        expect(find.text('— 箭头条件数据无效'), findsOneWidget);
        await draw(missing: true);
        expect(painter().phase, 0);
        await draw(value: double.nan);
        expect(painter().phase, 0);
        await draw();
        await tester.pump(const Duration(milliseconds: 100));
        final restored = painter().phase;
        await tester.pump(const Duration(milliseconds: 100));
        expect(painter().phase, greaterThan(restored));
        expect(find.text('— 箭头条件数据无效'), findsNothing);
        expect(document.toJson().toString(), original);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
