import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/api.dart';
import 'workspace_test.dart' show FakeApi, launch;

class HistoryCountApi extends FakeApi {
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/history') {
      return {
        'items': [],
        'stats': {'count': query?['min'] == '30' ? 2 : 3},
        'boundary': 3,
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets(
    'History count has an independent accessible label after query and filtering',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await launch(tester, HistoryCountApi());
        await tester.tap(find.byKey(const Key('nav-4')));
        await tester.pumpAndSettle();
        final count = find.byKey(const Key('history-sample-count'));
        expect(find.text('样本  3'), findsOneWidget);
        expect(find.bySemanticsLabel('历史样本数：3'), findsOneWidget);
        expect(tester.getSemantics(count).getSemanticsData().label, '历史样本数：3');
        await tester.enterText(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == '最小值',
          ),
          '30',
        );
        await tester.enterText(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.labelText == '最大值',
          ),
          '70',
        );
        await tester.tap(find.byKey(const Key('history-query')));
        await tester.pumpAndSettle();
        expect(find.text('样本  2'), findsOneWidget);
        expect(find.bySemanticsLabel('历史样本数：3'), findsNothing);
        expect(find.bySemanticsLabel('历史样本数：2'), findsOneWidget);
        expect(tester.getSemantics(count).getSemanticsData().label, '历史样本数：2');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );
}
