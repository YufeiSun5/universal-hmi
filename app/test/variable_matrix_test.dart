import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/variable_matrix.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/table.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'workspace_test.dart' show FakeApi, launch;

const _sourceTime = '2026-10-02T03:04:05Z';
const _receivedTime = '2026-10-02T03:04:07Z';

Json _sample(String id, {String quality = 'good'}) => {
  'point_id': id,
  'value': 21.5,
  'raw': 43,
  'quality': quality,
  'source_time': _sourceTime,
  'received_time': _receivedTime,
};

Future<void> _pumpMatrix(
  WidgetTester tester, {
  required List<Json> points,
  Map<String, Json> samples = const {},
  bool online = true,
  bool compact = true,
  bool showStation = false,
  String selectedID = '',
  ValueChanged<int>? onSelect,
  void Function(int, Offset)? onContext,
  ValueChanged<double>? onScroll,
  double initialScrollOffset = 0,
  ValueChanged<int>? onBuildPoint,
  ValueChanged<String>? onBuildLive,
  Size size = const Size(960, 540),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: workspaceTheme(),
      home: Scaffold(
        body: VariableMatrix(
          itemCount: points.length,
          pointBuilder: (i) {
            onBuildPoint?.call(i);
            return points[i];
          },
          liveBuilder: (id) {
            onBuildLive?.call(id);
            return samples[id] ?? _sample(id);
          },
          online: online,
          selectedID: selectedID,
          onSelect: onSelect ?? (_) {},
          onContext: onContext ?? (_, _) {},
          compact: compact,
          showStation: showStation,
          initialScrollOffset: initialScrollOffset,
          onScroll: onScroll,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _tiles => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('point-row-'),
);

VariableMatrix _matrix(WidgetTester tester) =>
    tester.widget<VariableMatrix>(find.byType(VariableMatrix));

ScrollController _gridController(WidgetTester tester) => tester
    .widget<GridView>(find.byKey(const Key('point-grid-scroll')))
    .controller!;

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> _density(WidgetTester tester, String density) async {
  await _tap(tester, 'matrix-density-control');
  await _tap(tester, 'matrix-density-$density');
}

String _clock(String value) {
  final time = DateTime.parse(value).toLocal();
  return [
    time.hour,
    time.minute,
    time.second,
  ].map((part) => part.toString().padLeft(2, '0')).join(':');
}

void main() {
  testWidgets(
    'Quality has distinct color and icon cues while values and R/RW stay explicit',
    (tester) async {
      final api = FakeApi();
      final points = [
        api.point('good', 'IO-01', writable: true),
        api.point('bad', 'IO-01'),
        api.point('stale', 'IO-01'),
      ];
      final samples = {
        for (final quality in ['good', 'bad', 'stale'])
          quality: _sample(quality, quality: quality),
      };
      await _pumpMatrix(tester, points: points, samples: samples);
      final icons = [
        for (final id in ['good', 'bad', 'stale'])
          tester.widget<Icon>(find.byKey(Key('quality-$id'))),
      ];
      expect(icons.map((icon) => icon.color).toSet(), hasLength(3));
      expect(icons.map((icon) => icon.icon).toSet(), hasLength(3));
      expect(icons.every((icon) => icon.color != null), isTrue);
      expect(
        tester.widget<Text>(find.byKey(const Key('value-good'))).data,
        '21.5',
      );
      expect(tester.widget<Text>(find.byKey(const Key('rw-good'))).data, 'RW');
      expect(tester.widget<Text>(find.byKey(const Key('rw-bad'))).data, 'R');
      final tooltip = tester.widget<Tooltip>(
        find
            .ancestor(
              of: find.byKey(const Key('point-row-good')),
              matching: find.byType(Tooltip),
            )
            .first,
      );
      expect(tooltip.message, contains('2026'));
      expect(tooltip.message, contains(_clock(_sourceTime)));
      expect(tooltip.message, contains(_clock(_receivedTime)));
      expect(tooltip.message, contains('源'));
      expect(tooltip.message, contains('接收'));

      await _pumpMatrix(
        tester,
        points: points,
        samples: samples,
        online: false,
      );
      final offline = tester.widget<Icon>(
        find.byKey(const Key('quality-good')),
      );
      expect({...icons.map((icon) => icon.color), offline.color}, hasLength(4));
      expect({...icons.map((icon) => icon.icon), offline.icon}, hasLength(4));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Cell selection and secondary click keep the correct point index',
    (tester) async {
      final api = FakeApi();
      int? selected, contextual;
      Offset? contextPosition;
      await _pumpMatrix(
        tester,
        points: [api.point('one', 'IO-01'), api.point('two', 'IO-01')],
        selectedID: 'two',
        onSelect: (index) => selected = index,
        onContext: (index, position) {
          contextual = index;
          contextPosition = position;
        },
      );
      await _tap(tester, 'point-row-two');
      expect(selected, 1);
      final target = tester.getCenter(find.byKey(const Key('point-row-one')));
      final mouse = await tester.startGesture(
        target,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.up();
      await tester.pumpAndSettle();
      expect(contextual, 0);
      expect(contextPosition, target);
      expect(selected, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Tab reaches each cell and Enter/Space activate that cell once', (
    tester,
  ) async {
    final api = FakeApi();
    final selections = <int>[];
    await _pumpMatrix(
      tester,
      points: [for (int i = 0; i < 3; i++) api.point('p$i', 'IO-01')],
      onSelect: selections.add,
    );
    final expected = <int>[];
    for (int index = 0; index < 3; index++) {
      bool cellHasFocus() => Focus.of(
        tester.element(find.byKey(Key('value-p$index'))),
      ).hasPrimaryFocus;
      // The scroll view and matrix may also be keyboard focus stops.
      for (int tab = 0; tab < 6 && !cellHasFocus(); tab++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(cellHasFocus(), isTrue, reason: 'Cell $index is Tab reachable');
      expect(selections, expected, reason: 'Tab alone must not select a cell');
      for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expected.add(index);
        expect(
          selections,
          expected,
          reason: '${key.keyLabel} selects cell $index once',
        );
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Same-name cells show their real stations and missing values stay blank',
    (tester) async {
      final api = FakeApi();
      await _pumpMatrix(
        tester,
        showStation: true,
        points: [
          {...api.point('station-one', 'IO-01'), 'name': 'Pressure'},
          {...api.point('station-two', 'IO-02'), 'name': 'Pressure'},
        ],
        samples: {
          'station-one': _sample('station-one'),
          'station-two': {
            ..._sample('station-two', quality: 'missing'),
            'value': 9876.5,
          },
        },
      );
      expect(find.text('Pressure'), findsNWidgets(2));
      for (final entry in {
        'station-one': 'IO-01',
        'station-two': 'IO-02',
      }.entries) {
        final cell = find.byKey(Key('point-row-${entry.key}'));
        final stationLabel = find.descendant(
          of: cell,
          matching: find.byKey(Key('matrix-station-${entry.key}')),
        );
        expect(tester.widget<Text>(stationLabel).data, entry.value);
      }
      expect(
        tester.widget<Text>(find.byKey(const Key('value-station-one'))).data,
        '21.5',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('value-station-two'))).data,
        '—',
      );
      expect(find.text('9876.5'), findsNothing);
      expect(
        tester
            .widget<Icon>(find.byKey(const Key('quality-station-two')))
            .semanticLabel,
        '无数据',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Arrow keys and Home/End move selection and reveal distant cells',
    (tester) async {
      final api = FakeApi();
      int? selected;
      await _pumpMatrix(
        tester,
        points: [for (int i = 0; i < 500; i++) api.point('p$i', 'IO-01')],
        onSelect: (index) => selected = index,
      );
      final rowTop = tester
          .getTopLeft(find.byKey(const Key('point-row-p0')))
          .dy;
      final columns = _tiles.evaluate().where((element) {
        return (tester.getTopLeft(find.byWidget(element.widget)).dy - rowTop)
                .abs() <
            1;
      }).length;
      await _tap(tester, 'point-row-p1');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(selected, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(selected, 2 + columns);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pumpAndSettle();
      expect(selected, 499);
      expect(find.byKey(const Key('point-row-p499')), findsOneWidget);
      expect(_gridController(tester).offset, greaterThan(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pumpAndSettle();
      expect(selected, 0);
      expect(find.byKey(const Key('point-row-p0')), findsOneWidget);
      expect(_gridController(tester).offset, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final count in [500, 15000]) {
    testWidgets(
      '$count matrix cells build lazily and the final cell is reachable',
      (tester) async {
        final api = FakeApi();
        final points = [
          for (int i = 0; i < count; i++) api.point('p$i', 'IO-01'),
        ];
        final builtPoints = <int>{};
        final builtLive = <String>{};
        final scrolls = <double>[];
        await _pumpMatrix(
          tester,
          points: points,
          onBuildPoint: builtPoints.add,
          onBuildLive: builtLive.add,
          onScroll: scrolls.add,
        );
        expect(builtPoints.length, inExclusiveRange(1, 200));
        expect(builtLive.length, inExclusiveRange(1, 200));
        expect(_tiles.evaluate().length, lessThan(200));
        expect(find.byKey(Key('point-row-p${count - 1}')), findsNothing);
        final controller = _gridController(tester);
        expect(controller.position.maxScrollExtent, greaterThan(0));
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(find.byKey(Key('point-row-p${count - 1}')), findsOneWidget);
        expect(_tiles.evaluate().length, lessThan(200));
        expect(builtPoints.length, lessThan(400));
        expect(builtLive.length, lessThan(400));
        expect(scrolls.last, closeTo(controller.position.maxScrollExtent, 1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'Compact matrix fits more columns and comfortable mode exposes time',
    (tester) async {
      final api = FakeApi();
      final points = [for (int i = 0; i < 100; i++) api.point('p$i', 'IO-01')];
      int firstRowCount() {
        final firstTop = tester
            .getTopLeft(find.byKey(const Key('point-row-p0')))
            .dy;
        return _tiles.evaluate().where((element) {
          return (tester.getTopLeft(find.byWidget(element.widget)).dy -
                      firstTop)
                  .abs() <
              1;
        }).length;
      }

      await _pumpMatrix(tester, points: points);
      final compactColumns = firstRowCount();
      final compactHeight = tester
          .getSize(find.byKey(const Key('point-row-p0')))
          .height;
      await _pumpMatrix(tester, points: points, compact: false);
      expect(compactColumns, greaterThan(firstRowCount()));
      expect(firstRowCount(), greaterThan(1));
      expect(
        tester.getSize(find.byKey(const Key('point-row-p0'))).height,
        greaterThan(compactHeight),
      );
      expect(find.byKey(const Key('source-age-p0')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Workspace defaults to a lazy matrix for 15000 points and 500-point stations',
    (tester) async {
      final api = FakeApi();
      for (int i = 0; i < 15000; i++) {
        api.rows.add(
          api.point('p$i', 'IO-${(i ~/ 500 + 1).toString().padLeft(2, '0')}'),
        );
      }
      await launch(tester, api);
      expect(_matrix(tester).itemCount, 15000);
      expect(_tiles.evaluate().length, lessThan(200));
      final all = _gridController(tester);
      all.jumpTo(all.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('point-row-p14999')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('point-search')), 'p14999');
      await tester.pumpAndSettle();
      expect(_matrix(tester).itemCount, 1);
      expect(find.byKey(const Key('point-row-p14999')), findsOneWidget);
      await _tap(tester, 'station-IO-01');
      await _tap(tester, 'nav-8');
      expect(_matrix(tester).itemCount, 500);
      expect(_tiles.evaluate().length, lessThan(200));
      final station = _gridController(tester);
      station.jumpTo(station.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('point-row-p499')), findsOneWidget);
      expect(find.byKey(const Key('point-row-p500')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Matrix and table share station-scoped operational filters and search',
    (tester) async {
      final api = FakeApi();
      api.rows.addAll([
        api.point('good', 'IO-01', writable: true),
        api.point('bad', 'IO-01'),
        api.point('stale', 'IO-01'),
        api.point('read-only', 'IO-01'),
        api.point('other-station', 'IO-02', writable: true),
      ]);
      api.qualityByID.addAll({
        'bad': 'bad',
        'stale': 'stale',
        'other-station': 'bad',
      });
      await launch(tester, api);
      await _tap(tester, 'station-IO-01');
      await _tap(tester, 'nav-8');
      expect(_matrix(tester).itemCount, 4);
      await _tap(tester, 'operational-writable');
      expect(_matrix(tester).itemCount, 1);
      expect(find.byKey(const Key('point-row-good')), findsOneWidget);
      await _tap(tester, 'operational-attention');
      expect(_matrix(tester).itemCount, 2);
      expect(find.byKey(const Key('point-row-bad')), findsOneWidget);
      expect(find.byKey(const Key('point-row-stale')), findsOneWidget);
      expect(find.byKey(const Key('point-row-other-station')), findsNothing);
      await _tap(tester, 'choose-watched');
      await _tap(tester, 'watch-choice-bad');
      await _tap(tester, 'watch-save');
      await _tap(tester, 'operational-watched');
      expect(_matrix(tester).itemCount, 1);
      expect(find.byKey(const Key('point-row-bad')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('point-search')), 'stale');
      await tester.pumpAndSettle();
      expect(_matrix(tester).itemCount, 0);
      await _tap(tester, 'operational-all');
      expect(_matrix(tester).itemCount, 1);
      expect(find.byKey(const Key('point-row-stale')), findsOneWidget);
      await _tap(tester, 'monitor-layout-table');
      expect(find.byType(VariableMatrix), findsNothing);
      expect(tester.widget<DenseTable>(find.byType(DenseTable)).rowCount, 1);
      expect(find.byKey(const Key('point-row-stale')), findsOneWidget);
      await _tap(tester, 'monitor-layout-matrix');
      expect(_matrix(tester).itemCount, 1);
      expect(find.byKey(const Key('point-row-stale')), findsOneWidget);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Stations restore their own matrix density selection scroll and layout',
    (tester) async {
      final api = FakeApi();
      for (int i = 0; i < 160; i++) {
        api.rows.add(api.point('aa-$i', 'IO-01'));
        api.rows.add(api.point('bb-$i', 'IO-02', writable: i.isEven));
      }
      await launch(tester, api);
      await _tap(tester, 'station-IO-01');
      await _tap(tester, 'nav-8');
      expect(_matrix(tester).compact, isTrue);
      await _density(tester, 'comfortable');
      await tester.enterText(find.byKey(const Key('point-search')), 'aa-');
      await tester.pumpAndSettle();
      await _tap(tester, 'point-row-aa-0');
      expect(_matrix(tester).selectedID, 'aa-0');
      final first = _gridController(tester);
      first.jumpTo(280);
      await tester.pumpAndSettle();
      final firstOffset = first.offset;
      expect(firstOffset, greaterThan(0));

      await _tap(tester, 'station-IO-02');
      await _tap(tester, 'nav-8');
      expect(_matrix(tester).compact, isTrue);
      expect(_matrix(tester).selectedID, isNot('aa-0'));
      expect(_gridController(tester).offset, 0);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('point-search')))
            .controller!
            .text,
        isEmpty,
      );
      await _tap(tester, 'point-row-bb-0');
      await _tap(tester, 'operational-writable');
      expect(_matrix(tester).itemCount, 80);
      await _tap(tester, 'monitor-layout-table');
      expect(tester.widget<DenseTable>(find.byType(DenseTable)).rowCount, 80);

      await _tap(tester, 'station-IO-01');
      expect(_matrix(tester).compact, isFalse);
      expect(_matrix(tester).selectedID, 'aa-0');
      expect(_matrix(tester).itemCount, 160);
      expect(_gridController(tester).offset, closeTo(firstOffset, 1));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('point-search')))
            .controller!
            .text,
        'aa-',
      );
      expect(find.byKey(const Key('write-inspector-aa-0')), findsOneWidget);
      expect(find.byKey(const Key('write-inspector-bb-0')), findsNothing);
      await _tap(tester, 'station-IO-02');
      expect(find.byType(VariableMatrix), findsNothing);
      expect(tester.widget<DenseTable>(find.byType(DenseTable)).rowCount, 80);
      expect(find.byKey(const Key('write-inspector-bb-0')), findsOneWidget);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    '125 percent scaling keeps the matrix and inspector usable without overflow',
    (tester) async {
      final api = FakeApi();
      api.rows.addAll([
        for (int i = 0; i < 500; i++) api.point('p$i', 'IO-01'),
      ]);
      await launch(tester, api, size: const Size(1180, 812));
      tester.view.devicePixelRatio = 1.25;
      await tester.pumpAndSettle();
      await _tap(tester, 'station-IO-01');
      await _tap(tester, 'nav-8');
      await _tap(tester, 'point-row-p0');
      expect(find.byKey(const Key('write-inspector-p0')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('matrix-density-control')),
      );
      await _density(tester, 'comfortable');
      expect(_matrix(tester).compact, isFalse);
      expect(_matrix(tester).itemCount, 500);
      final controller = _gridController(tester);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('point-row-p499')), findsOneWidget);
      expect(find.byKey(const Key('write-inspector-p0')), findsOneWidget);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
