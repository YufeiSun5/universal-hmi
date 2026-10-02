import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/features/variable_matrix.dart';
import 'workspace_test.dart' show FakeApi, launch;

void completeDemo(FakeApi api) {
  api.rows.clear();
  for (var station = 1; station <= 30; station++) {
    for (var channel = 0; channel < 3; channel++) {
      api.rows.add(
        api.point(
          's$station-$channel',
          'IO-${station.toString().padLeft(2, '0')}',
        ),
      );
    }
  }
}

class ActivationDuringLoadApi extends FakeApi {
  int directoryReads = 0;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (method == 'GET' && path == '/api/v1/points') {
      directoryReads++;
      if (directoryReads == 1) {
        final previous = rows
            .map((row) => Map<String, dynamic>.of(row))
            .toList();
        completeDemo(this);
        runtimeVersion = 'activated-v2';
        return {'items': previous};
      }
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets(
    'Directory read spanning activation retries to a coherent 90-point snapshot',
    (tester) async {
      final api = ActivationDuringLoadApi();
      api.rows.add(api.point('old', 'IO-01'));
      await launch(tester, api);
      expect(api.directoryReads, 2);
      expect(
        tester.widget<VariableMatrix>(find.byType(VariableMatrix)).itemCount,
        90,
      );
      expect(find.textContaining('90 变量 · 30 站点'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'External activation refreshes station directory without clearing a station filter',
    (tester) async {
      final api = FakeApi();
      api.rows.add(api.point('s1-0', 'IO-01'));
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('station-IO-01')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-8')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('point-search')), 's1-0');
      await tester.pumpAndSettle();
      completeDemo(api);
      api.runtimeVersion = 'activated-v2';
      await tester.pump(const Duration(milliseconds: 800));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('point-search')))
            .controller!
            .text,
        's1-0',
      );
      expect(find.byKey(const Key('point-row-s1-0')), findsOneWidget);
      expect(find.textContaining('90 变量 · 30 站点'), findsOneWidget);
      await tester.tap(find.byKey(const Key('station-global')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<VariableMatrix>(find.byType(VariableMatrix)).itemCount,
        90,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('A previously unseen runtime ID also refreshes the directory', (
    tester,
  ) async {
    final api = FakeApi();
    api.rows.add(api.point('one', 'IO-01'));
    await launch(tester, api);
    api.rows.add(api.point('two', 'IO-02'));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle();
    expect(
      tester.widget<VariableMatrix>(find.byType(VariableMatrix)).itemCount,
      2,
    );
    expect(find.byKey(const Key('station-IO-02')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
