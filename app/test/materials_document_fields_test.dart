import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/materials/document_fields.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/widgets.dart';
import 'package:universal_hmi/shared/api.dart';
import 'materials_test.dart' show MaterialsApi, sized, openEditor;

void main() {
  testWidgets(
    'person selection freezes attribution and editing returns to manual entry',
    (t) async {
      await sized(t, const Size(1000, 1100));
      final api = MaterialsApi();
      api.responses['/api/v1/materials/personnel'] = {
        'items': [
          {'user_id': 'u2', 'name': '采购账号'},
        ],
      };
      Json fields = {};
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => SingleChildScrollView(
                child: MaterialDocumentFieldsEditor(
                  api: api,
                  kind: 'inbound',
                  values: fields,
                  onChanged: (v) => update(() => fields = v),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byTooltip('选择采购员账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('采购账号'));
      await t.pumpAndSettle();
      expect(fields['purchaser'], {'user_id': 'u2', 'name': '采购账号'});
      expect(find.byType(MaterialAssetView), findsNothing);
      expect(api.calls.any((c) => '${c['path']}'.contains('signature')), false);
      await t.enterText(
        find.byKey(const ValueKey('material-detail-field-purchaser')),
        '外部采购人',
      );
      await t.pump();
      expect(fields['purchaser'], {'user_id': '', 'name': '外部采购人'});
      await t.enterText(
        find.byKey(const ValueKey('material-detail-field-certificate_count')),
        '0',
      );
      await t.enterText(
        find.byKey(const ValueKey('material-detail-field-freight')),
        '12.50',
      );
      await t.pump();
      expect(materialDocumentFieldErrors(fields), isEmpty);
      expect(materialDocumentFieldsPayload(fields)['certificate_count'], 0);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets(
    'station picker allows subsequent manual station and narrow layout',
    (t) async {
      await sized(t, const Size(440, 900));
      final api = MaterialsApi();
      api.responses['/api/v1/stations'] = {
        'items': [
          {'id': 's1', 'name': '已有站所'},
        ],
      };
      Json fields = {};
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => SingleChildScrollView(
                child: MaterialDocumentFieldsEditor(
                  api: api,
                  kind: 'outbound',
                  values: fields,
                  onChanged: (v) => update(() => fields = v),
                ),
              ),
            ),
          ),
        ),
      );
      await t.ensureVisible(find.byTooltip('选择已有站所'));
      await t.tap(find.byTooltip('选择已有站所'));
      await t.pumpAndSettle();
      await t.tap(find.text('已有站所'));
      await t.pumpAndSettle();
      expect(fields['station'], '已有站所');
      await t.enterText(
        find.byKey(const ValueKey('material-detail-field-station')),
        '手填站所',
      );
      await t.pump();
      expect(fields['station'], '手填站所');
      await t.enterText(
        find.byKey(const ValueKey('material-detail-field-project_number')),
        '000A-12',
      );
      await t.pump();
      expect(fields['project_number'], '000A-12');
      expect(t.takeException(), isNull);
    },
  );

  test(
    'optional integer and freight validation distinguishes blank and zero',
    () {
      expect(materialDocumentFieldErrors({}), isEmpty);
      expect(materialDocumentFieldsPayload({})['certificate_count'], isNull);
      for (final value in ['-1', '1.5', 'abc', '1000000000']) {
        expect(
          materialDocumentFieldErrors({
            'certificate_count': value,
          }).containsKey('certificate_count'),
          true,
        );
      }
      expect(
        materialDocumentFieldErrors({'freight': '-0.1'}).containsKey('freight'),
        true,
      );
      expect(
        materialDocumentFieldErrors({'certificate_count': '0', 'freight': '0'}),
        isEmpty,
      );
    },
  );

  testWidgets(
    'document draft survives close and reopen including leading zero fields',
    (t) async {
      await sized(t, const Size(1400, 1100));
      final api = MaterialsApi();
      final session = MaterialsSession();
      await openEditor(t, api, session, 'inbound');
      final supplier = find.byKey(
        const ValueKey('material-detail-field-supplier'),
      );
      await t.ensureVisible(supplier);
      await t.enterText(supplier, '供应单位甲');
      final invoice = find.byKey(
        const ValueKey('material-detail-field-invoice_number'),
      );
      await t.ensureVisible(invoice);
      await t.enterText(invoice, '000INV');
      await t.pump();
      expect(
        materialDocumentFields(
          session.draft('inbound-new').values,
        )['invoice_number'],
        '000INV',
      );
      await t.tap(find.byTooltip('保留并返回'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认'));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('material-detail-field-invoice_number')),
        findsNothing,
      );
      // The existing close flow retains the session draft.
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      await t.ensureVisible(invoice);
      expect(t.widget<TextField>(invoice).controller!.text, '000INV');
      expect(t.widget<TextField>(supplier).controller!.text, '供应单位甲');
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );

  testWidgets('stored personnel are labels and never signature widgets', (
    t,
  ) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MaterialDocumentFieldsView(
            record: {
              'kind': 'outbound',
              'details': {
                'project_number': '000P',
                'recipient_person': {'user_id': 'u', 'name': '实际领用账号'},
                'supervisor': {'name': '外部主管'},
              },
            },
          ),
        ),
      ),
    );
    expect(find.text('工程编号：000P'), findsOneWidget);
    expect(find.text('实际领用人：实际领用账号'), findsOneWidget);
    expect(find.byType(MaterialAssetView), findsNothing);
  });
}
