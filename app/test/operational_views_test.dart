import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/table.dart';
import 'package:universal_hmi/features/variable_matrix.dart';
import 'workspace_test.dart' show FakeApi, launch;

void main() {
  testWidgets(
    'Source summary opens only that station and source in monitoring',
    (tester) async {
      final api = FakeApi();
      api.rows.addAll([
        {...api.point('one', 'IO-01'), 'source_id': 'source-a'},
        {...api.point('two', 'IO-01'), 'source_id': 'source-b'},
        {...api.point('three', 'IO-02'), 'source_id': 'source-a'},
      ]);
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('station-IO-01')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('overview-source-source-a')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('active-station'))).data,
        'IO-01',
      );
      expect(
        tester.widget<VariableMatrix>(find.byType(VariableMatrix)).itemCount,
        1,
      );
      expect(find.byKey(const Key('point-row-one')), findsOneWidget);
      expect(find.byKey(const Key('point-row-three')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Overview is an operational summary and anomaly entry keeps station scope',
    (tester) async {
      final api = FakeApi();
      api.rows.addAll([
        api.point('one', 'IO-01'),
        api.point('two', 'IO-01'),
        api.point('three', 'IO-02'),
        api.point('four', 'IO-02'),
      ]);
      api.qualityByID.addAll({'one': 'bad', 'three': 'bad', 'four': 'stale'});
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('station-IO-01')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('station-overview')), findsOneWidget);
      expect(find.byType(DenseTable), findsNothing);
      expect(find.text('未配置关注变量'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('overview-issue-count'))).data,
        '质量异常 · 1',
      );
      await tester.tap(find.byKey(const Key('overview-attention-all')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('active-station'))).data,
        'IO-01',
      );
      expect(
        tester.widget<VariableMatrix>(find.byType(VariableMatrix)).itemCount,
        1,
      );
      expect(find.byKey(const Key('point-row-one')), findsOneWidget);
      expect(find.byKey(const Key('point-row-three')), findsNothing);
      await tester.tap(find.byKey(const Key('station-IO-02')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('overview-issue-count'))).data,
        '质量异常 · 2',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Configured watches remain separate and restore for each station',
    (tester) async {
      final api = FakeApi();
      api.rows.addAll([api.point('one', 'IO-01'), api.point('two', 'IO-02')]);
      await launch(tester, api);
      Future<void> watch(String station, String id) async {
        await tester.tap(find.byKey(Key('station-$station')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('choose-watched')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(Key('watch-choice-${id == 'one' ? 'two' : 'one'}')),
          findsNothing,
        );
        await tester.tap(find.byKey(Key('watch-choice-$id')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('watch-save')));
        await tester.pumpAndSettle();
      }

      await watch('IO-01', 'one');
      await watch('IO-02', 'two');
      expect(find.byKey(const Key('watched-variable-two')), findsOneWidget);
      expect(find.byKey(const Key('watched-variable-one')), findsNothing);
      await tester.tap(find.byKey(const Key('station-IO-01')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('watched-variable-one')), findsOneWidget);
      expect(find.byKey(const Key('watched-variable-two')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
