import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/materials/receipt.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/workspace.dart';
import 'materials_test.dart' as fixtures;

void main() {
  testWidgets(
    'confirmed inbound receipt starts a fresh draft without reposting',
    (t) async {
      await fixtures.sized(t, const Size(1093, 614));
      final api = fixtures.MaterialsApi();
      final session = MaterialsSession()..section = 'inbound';
      session.draft('inbound-new').lines.add({
        'key': 'l',
        'item_id': 'i',
        'name': '阀门',
        'unit': '个',
        'category_id': 'c',
        'category_name': '正常',
        'quantity': '2',
        'price': '3',
      });
      api.intercept = (m, p, b) async {
        if (m == 'POST' && p.endsWith('/inbound')) {
          return {'id': 'receipt-1', 'number': 'RK-001', 'kind': 'inbound'};
        }
        return api.answer(m, p);
      };
      await t.pumpWidget(
        fixtures.host(MaterialsWorkspace(api: api, session: session)),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('新建入库'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('material-submit')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      await t.tap(find.text('确认入库并增加库存'));
      await t.pumpAndSettle();
      expect(find.text('单号：RK-001'), findsOneWidget);
      expect(find.text('已生成入库单并增加库存。'), findsOneWidget);
      expect(find.text('导出Excel出库单'), findsNothing);
      await t.pump(const Duration(seconds: 10));
      expect(find.text('继续新建'), findsOneWidget);
      await t.tap(find.text('继续新建'));
      await t.pumpAndSettle();
      expect(session.draft('inbound-new').lines, isEmpty);
      expect(api.calls.where((v) => v['method'] == 'POST').length, 1);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets(
    'receipt export failure keeps saved result and can retry without writes',
    (t) async {
      await fixtures.sized(t, const Size(1093, 614));
      final api = fixtures.MaterialsApi();
      api.intercept = (m, p, b) async => throw StateError('网络中断');
      await t.pumpWidget(fixtures.host(const SizedBox()));
      final context = t.element(find.byType(Scaffold));
      final result = showDialog<String>(
        context: context,
        builder: (_) => MaterialReceipt(
          api: api,
          record: const {'id': 'out-1', 'number': 'CK-001'},
          kind: 'outbound',
        ),
      );
      await t.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        await t.tap(find.text('导出Excel出库单'));
        await t.pumpAndSettle();
        expect(find.textContaining('单据已保存，不会再次扣库存'), findsOneWidget);
        expect(find.text('单号：CK-001'), findsOneWidget);
      }
      expect(api.calls.length, 2);
      expect(
        api.calls.every(
          (v) =>
              v['method'] == 'GET' &&
              v['path'] == '$materialsBase/documents/out-1/export',
        ),
        true,
      );
      await t.tap(find.text('查看单据'));
      await t.pumpAndSettle();
      expect(await result, 'view');
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'category Chinese composition and keyboard submit at 125 percent scale',
    (t) async {
      t.view.physicalSize = const Size(1366, 768);
      t.view.devicePixelRatio = 1.25;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final api = fixtures.MaterialsApi();
      final session = MaterialsSession();
      await fixtures.openEditor(t, api, session, 'category');
      final field = find.byKey(const ValueKey('material-field-name'));
      await t.showKeyboard(field);
      t.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '阀门',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await t.pump();
      expect(api.calls.where((v) => v['method'] == 'POST'), isEmpty);
      t.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '阀门',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await t.pump();
      final submit = find.byKey(const Key('material-submit'));
      var focused = false;
      for (var i = 0; i < 15; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pumpAndSettle();
        final buttonContext = t.element(submit);
        focused =
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<FilledButton>() ==
            buttonContext.widget;
        if (focused) break;
      }
      expect(focused, true);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(
        api.calls.singleWhere((v) => v['method'] == 'POST')['body']['name'],
        '阀门',
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
