import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/widgets.dart';
import 'materials_test.dart' as fixtures;

void main() {
  testWidgets(
    'inbound association has explicit action and retains chosen revision',
    (t) async {
      await fixtures.sized(t, const Size(1366, 768));
      final api = fixtures.MaterialsApi();
      final session = MaterialsSession();
      api.responses['$materialsBase/applications'] = {
        'items': [
          {
            'id': 'approved-1',
            'version': 3,
            'number': 'SQ-001',
            'owner': '张师傅',
            'text': '维修球阀',
            'submitted': '2026-11-14T02:00:00Z',
          },
        ],
        'total': 1,
      };
      await fixtures.openEditor(t, api, session, 'inbound');
      expect(find.text('选择已批准申请').hitTestable(), findsOneWidget);
      await t.tap(find.text('选择已批准申请'));
      await t.pumpAndSettle();
      final query = api.calls.last['query'];
      final now = DateTime.now().toUtc().add(const Duration(hours: 8));
      final day = DateTime.utc(now.year, now.month, now.day);
      expect(
        DateTime.parse(query['from']),
        day.subtract(const Duration(days: 6, hours: 8)),
      );
      expect(
        DateTime.parse(query['until']),
        day.add(const Duration(days: 1)).subtract(const Duration(hours: 8)),
      );
      expect(query['status'], 'approved');
      expect(find.text('提交时间：2026-11-14 10:00:00'), findsOneWidget);
      await t.tap(find.text('仅未入库'));
      await t.pumpAndSettle();
      expect(api.calls.last['query']['inbound_status'], 'none');
      await t.tap(find.textContaining('SQ-001').last);
      await t.pumpAndSettle();
      expect(
        session.draft('inbound-new').values['application_id'],
        'approved-1',
      );
      expect(session.draft('inbound-new').values['application_version'], 3);
      expect(find.text('已关联：SQ-001 · 维修球阀'), findsOneWidget);
      await t.tap(find.text('取消关联'));
      await t.pumpAndSettle();
      expect(session.draft('inbound-new').values['application_id'], '');
      expect(session.draft('inbound-new').values['application_version'], 0);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'date picker, unreceived and search reset pagination and reject stale choices on error',
    (t) async {
      await fixtures.sized(t, const Size(1093, 614));
      final api = fixtures.MaterialsApi();
      var fail = false;
      api.intercept = (m, p, b) async {
        if (fail) throw StateError('查询失败');
        return {
          'items': [
            {'id': 'a', 'submitted': '2026-11-15T01:00:00Z'},
          ],
          'total': 101,
        };
      };
      await t.pumpWidget(
        fixtures.host(
          MaterialRecordPicker(
            api: api,
            title: '选择已批准申请',
            endpoint: '$materialsBase/applications',
            query: const {'status': 'approved'},
            applicationSelection: true,
            label: (_) => '可选申请',
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('下一页'));
      await t.pumpAndSettle();
      expect(api.calls.last['query']['offset'], 50);
      await t.tap(find.byKey(const Key('material-picker-from')));
      await t.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await t.tap(find.text('1').last);
      await t.tap(find.text('确定'));
      await t.pumpAndSettle();
      final from = api.calls.last['query']['from'];
      expect(DateTime.parse(from).add(const Duration(hours: 8)).day, 1);
      expect(api.calls.last['query']['offset'], 0);
      await t.tap(find.text('仅未入库'));
      await t.pumpAndSettle();
      await t.enterText(find.byKey(const Key('material-picker-search')), '球阀');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pumpAndSettle();
      expect(api.calls.last['query']['search'], '球阀');
      expect(api.calls.last['query']['from'], from);
      expect(api.calls.last['query']['inbound_status'], 'none');
      fail = true;
      await t.tap(find.text('全部日期'));
      await t.pumpAndSettle();
      expect(api.calls.last['query'].containsKey('from'), false);
      expect(api.calls.last['query'].containsKey('until'), false);
      expect(find.text('可选申请'), findsNothing);
      fail = false;
      await t.tap(find.text('重试'));
      await t.pumpAndSettle();
      expect(find.text('可选申请'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary material picker has no application date or receipt filters',
    (t) async {
      final api = fixtures.MaterialsApi();
      await t.pumpWidget(
        fixtures.host(
          MaterialRecordPicker(
            api: api,
            title: '选择物料',
            endpoint: '$materialsBase/items',
            label: (_) => '物料',
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('仅未入库'), findsNothing);
      expect(find.byKey(const Key('material-picker-from')), findsNothing);
      expect(api.calls.last['query'].containsKey('from'), false);
    },
  );
}
