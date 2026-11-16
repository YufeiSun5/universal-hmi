import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/materials/batch_export.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/workspace.dart';
import 'materials_test.dart' as fixtures;

void main() {
  for (final kind in ['inbound', 'outbound']) {
    testWidgets('$kind batch keeps page selection, filters and order on retry', (
      t,
    ) async {
      await fixtures.sized(t, const Size(480, 800));
      final api = fixtures.MaterialsApi();
      var page = 0;
      api.intercept = (method, path, body) async {
        if (method == 'POST') throw StateError('export interrupted');
        return {
          'items': [
            {
              'id': 'doc$page',
              'number': '单号$page',
              'kind': kind,
              'status': 'confirmed',
              'owner': '仓库员',
              'created': '2026-11-16T01:00:00Z',
              'lines': [
                <String, dynamic>{'name': '管件'},
              ],
            },
            {
              'id': 'wrong$page',
              'number': '其他类型',
              'kind': 'return',
              'status': 'confirmed',
              'lines': [],
            },
          ],
          'total': 51,
        };
      };
      await t.pumpWidget(
        fixtures.host(
          MaterialBatchExportDialog(
            api: api,
            kind: kind,
            filters: const {
              'from': '2026-11-01',
              'until': '2026-12-01',
              'category_id': 'c1',
              'search': '管件',
            },
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(api.calls.first['path'], '$materialsBase/$kind');
      expect(api.calls.first['query']['category_id'], 'c1');
      expect(api.calls.first['query']['search'], '管件');
      expect(find.textContaining('同一工作表'), findsOneWidget);
      expect(
        t
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).last)
            .onChanged,
        isNull,
      );
      await t.tap(find.text('选择本页'));
      await t.pumpAndSettle();
      page = 1;
      // Changing the query retains explicit selections and does not select new rows.
      await t.enterText(find.byType(TextField), '新查询');
      await t.tap(find.text('查询'));
      await t.pumpAndSettle();
      expect(find.text('已选 1 / 50 张'), findsOneWidget);
      await t.tap(find.text('选择本页'));
      await t.pumpAndSettle();
      await t.tap(find.text('导出所选 2 张'));
      await t.pumpAndSettle();
      expect(api.calls.last['path'], '$materialsBase/documents/export');
      expect(api.calls.last['body'], {
        'kind': kind,
        'ids': ['doc0', 'doc1'],
      });
      expect(find.textContaining('导出失败'), findsOneWidget);
      expect(find.text('已选 2 / 50 张'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
    testWidgets('$kind list exposes batch export with its applied filters', (
      t,
    ) async {
      await fixtures.sized(t, const Size(1280, 900));
      final api = fixtures.MaterialsApi();
      final session = MaterialsSession()..section = kind;
      session.filters[kind] = {
        'from': '2026-11-01',
        'to': '2026-12-01',
        'search': 'RK',
      };
      await t.pumpWidget(
        fixtures.host(MaterialsWorkspace(api: api, session: session)),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('批量导出'));
      await t.pumpAndSettle();
      expect(find.byType(MaterialBatchExportDialog), findsOneWidget);
      expect(api.calls.last['query']['from'], '2026-11-01');
      expect(api.calls.last['query']['until'], '2026-12-01');
      expect(api.calls.last['query']['search'], 'RK');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    });
  }
}
