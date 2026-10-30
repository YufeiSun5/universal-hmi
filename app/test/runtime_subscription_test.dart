import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/main.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/features/process/subscriptions.dart';
import 'package:universal_hmi/features/process/catalog.dart';
import 'process_test.dart' show ScreenApi;

class SubscriptionApi extends ScreenApi
    implements RuntimeApi, SelectedRuntimeApi {
  final selections = <List<String>?>[];
  final streams = <StreamController<Json>>[];
  @override
  Stream<Json> runtimeEvents() =>
      throw StateError('legacy stream not expected');
  @override
  Stream<Json> runtimeSelectedEvents(List<String>? ids) {
    selections.add(ids);
    final stream = StreamController<Json>();
    stream.onListen = () async {
      final snapshot = await request('GET', '/api/v1/runtime');
      if (!stream.hasListener) return;
      stream.add({
        ...snapshot,
        'values': objects(
          snapshot['values'],
        ).where((v) => ids == null || ids.contains(v['point_id'])).toList(),
      });
    };
    streams.add(stream);
    return stream.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await ProcessSymbol.load();
  });
  test(
    'process subscription includes value and animation references; GIS deduplicates',
    () {
      final doc = ScreenDocument(
        id: 'test',
        name: 'test',
        station: '',
        nodes: [
          ScreenElement({
            'id': 'x',
            'type': 'value',
            'point_id': 'a',
            'arrow_visible_rule': {
              'conditions': [
                {'point_id': 'b'},
                {'point_id': ''},
              ],
            },
            'arrow_motion_rule': {
              'conditions': [
                {'point_id': 'a'},
                {'point_id': 'c'},
              ],
            },
          }),
        ],
      );
      expect(processSubscriptionIDs(doc), {'a', 'b', 'c'});
      expect(
        gisSubscriptionIDs({
          'stations': [
            {
              'bindings': {'primary_supply': 'a', 'primary_return': 'b'},
            },
            {
              'bindings': {'primary_supply': 'a'},
            },
          ],
        }),
        {'a', 'b'},
      );
    },
  );
  testWidgets(
    'runtime page subscribes its document and releases values on history navigation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = SubscriptionApi();
      api.rows.addAll([api.point('a', 'A'), api.point('b', 'B')]);
      api.screens['public'] = ScreenDocument(
        id: 'public',
        name: '公共工艺',
        station: '',
        revision: 1,
        nodes: [
          ScreenElement.create(
            'value',
            const Offset(80, 80),
          ).update({'point_id': 'a'}),
        ],
      ).toJson();
      await tester.pumpWidget(
        UniversalHmiApp(api: api, initialView: 'process'),
      );
      await tester.pumpAndSettle();

      expect(api.selections.last, ['a']);
      expect(
        api.selections.every((ids) => ids != null && !ids.contains('b')),
        true,
      );
      api.streams.last.add({
        'version': 'v1',
        'values': [
          {'point_id': 'a', 'quality': 'good', 'value': 42},
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史').first);
      await tester.pumpAndSettle();
      expect(api.selections.last, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      for (final stream in api.streams) {
        unawaited(stream.close());
      }
    },
  );
}
