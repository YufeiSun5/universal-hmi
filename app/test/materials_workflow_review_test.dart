import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/materials/detail.dart';
import 'package:universal_hmi/features/materials/editor.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/widgets.dart';
import 'package:universal_hmi/features/materials/workspace.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'materials_test.dart' show MaterialsApi, grants, sized;

const item = <String, dynamic>{
  'id': 'pipe1',
  'name': 'DN35 镀锌钢管',
  'specification': 'DN35',
  'unit': '根',
  'category_id': 'dn35',
  'category_name': '镀锌钢管 / DN35',
  'stock_category_id': 'dn35',
  'stock_category': '镀锌钢管 / DN35',
  'price': '500',
  'quantity': '35',
  'total_quantity': '35',
  'warning': '5',
  'version': 1,
  'balance_version': 1,
};
const line = <String, dynamic>{
  'id': 'l1',
  'key': 'l1',
  'item_id': 'pipe1',
  'name': 'DN35 镀锌钢管',
  'specification': 'DN35',
  'unit': '根',
  'category_id': 'dn35',
  'category': '镀锌钢管 / DN35',
  'category_name': '镀锌钢管 / DN35',
  'quantity': '25',
  'price': '500',
  'amount': '12500.00',
  'remaining': '25',
  'returned': '0',
  'available': '35',
  'item_version': 1,
  'balance_version': 1,
};
Json application(String id) => {
  'id': id,
  'number': 'SQ-20261116-C45591882E78',
  'owner': '孙工',
  'owner_id': 'u1',
  'status': 'approved',
  'version': 2,
  'text': '需要 DN35 管 35 根，DN50 管 50 根',
  'submitted': '2026-11-16T01:26:55Z',
};
Json document(String kind) => {
  'id': kind,
  'number': '${kind == 'inbound' ? 'RK' : 'CK'}-20261116-BD8576900ACA',
  'kind': kind,
  'owner': '孙工',
  'owner_id': 'u1',
  'status': kind == 'inbound' ? 'confirmed' : 'not_returned',
  'created': '2026-11-16T01:36:24Z',
  'known_amount': '12500.00',
  'missing_prices': 0,
  'lines': [line],
  'application_id': kind == 'inbound' ? 'a1' : '',
  'application_version': 2,
  'purpose': kind == 'outbound' ? '日常维修领用' : '',
  'recipient': kind == 'outbound' ? '维修班组' : '',
};
MaterialsApi reviewApi() {
  final api = MaterialsApi();
  api.intercept = (m, p, b) async {
    final q = api.calls.last['query'] as Json;
    if (m != 'GET') return api.answer(m, p);
    if (p.endsWith('/categories')) {
      return {
        'items': q['parent_id'] == 'pipe'
            ? [
                {
                  'id': 'dn35',
                  'name': 'DN35',
                  'path': '镀锌钢管 / DN35',
                  'children': 0,
                  'version': 1,
                },
              ]
            : [
                {
                  'id': 'pipe',
                  'name': '镀锌钢管',
                  'path': '镀锌钢管',
                  'children': 1,
                  'version': 1,
                },
                {
                  'id': 'spare',
                  'name': '维修备件',
                  'path': '维修备件',
                  'children': 0,
                  'version': 1,
                },
              ],
        'total': q['parent_id'] == 'pipe' ? 1 : 2,
      };
    }
    if (p.endsWith('/items') || p.endsWith('/stock')) {
      return {
        'items': [
          if (q['category_id'] == null ||
              q['category_id'] == 'dn35' ||
              q['category_id'] == 'pipe')
            {...item, if (p.endsWith('/items')) 'stock_category_id': null},
          if (q['category_id'] == null)
            {
              ...item,
              'id': 'elbow',
              'name': '弯头',
              'specification': 'DN200',
              'price': '',
              'quantity': '0',
              'stock_category': '维修备件',
              'category_name': '维修备件',
            },
        ],
        'total': q['category_id'] == null ? 2 : 1,
      };
    }
    if (p.endsWith('/applications')) {
      return {
        'items': [
          application('a1'),
          {
            ...application('a2'),
            'text': '维修泵房阀门，需要 DN50 球阀 10 个',
            'number': 'SQ-20261114-TEST0002',
          },
        ],
        'total': 2,
      };
    }
    if (p.endsWith('/applications/a1')) {
      return {
        'application': application('a1'),
        'versions': [
          {...application('a1')},
        ],
        'inbound': {
          'items': [document('inbound')],
          'total': 1,
        },
      };
    }
    if (p.endsWith('/documents/inbound') || p.endsWith('/documents/outbound')) {
      final kind = p.split('/').last;
      return {
        'document': document(kind),
        'can_read_application': true,
        'movements': {
          'items': [
            {
              'kind': kind,
              'quantity': kind == 'inbound' ? '25' : '-25',
              'number': document(kind)['number'],
              'document_id': kind,
              'actor': '孙工',
              'created': '2026-11-16T01:36:24Z',
            },
          ],
          'total': 1,
        },
      };
    }
    if (p.endsWith('/inbound') || p.endsWith('/outbound')) {
      return {
        'items': [document(p.split('/').last)],
        'total': 1,
      };
    }
    if (p.endsWith('/chains')) {
      return {
        'items': [
          {
            'id': 'a1',
            'kind': 'application',
            'number': application('a1')['number'],
            'owner': '孙工',
            'title': application('a1')['text'],
            'status': 'approved',
            'node_count': 3,
            'updated': '2026-11-16T01:36:24Z',
          },
        ],
        'total': 1,
      };
    }
    return api.answer(m, p);
  };
  return api;
}

Future<void> fonts() async {
  if (Platform.environment['HMI_WIDGET_SCREENSHOTS'] == null) return;
  await (FontLoader(
    'HmiCJK',
  )..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'))).load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

Widget reviewHost(Widget child, GlobalKey key) => RepaintBoundary(
  key: key,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: workspaceTheme(),
    home: Scaffold(backgroundColor: const Color(0xff858b90), body: child),
  ),
);
Future<void> shot(WidgetTester t, GlobalKey key, String name) async {
  expect(t.takeException(), isNull);
  final dir = Platform.environment['HMI_WIDGET_SCREENSHOTS'];
  if (dir == null) return;
  await t.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(dir).create(recursive: true);
    await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets(
    'retained draft does not repeatedly block navigation or discard pending operation',
    (t) async {
      final api = reviewApi();
      final session = MaterialsSession();
      addTearDown(session.dispose);
      final draft = session.draft('inbound-new');
      draft.set('notes', '尚未提交的备注');
      draft.pending = {'operation_id': 'original-operation'};
      draft.pendingPath = '$materialsBase/inbound';
      final key = GlobalKey<MaterialsWorkspaceState>();
      await t.pumpWidget(
        reviewHost(
          MaterialsWorkspace(key: key, api: api, session: session),
          GlobalKey(),
        ),
      );
      await t.pumpAndSettle();
      for (final section in [
        'inbound',
        'stock',
        'applications',
        'outbound',
        'inbound',
      ]) {
        await t.tap(find.byKey(ValueKey('materials-section-$section')));
        await t.pumpAndSettle();
        expect(session.section, section);
        expect(find.byType(AlertDialog), findsNothing);
        expect(await key.currentState!.prepareLeave(), isTrue);
      }
      expect(draft.values['notes'], '尚未提交的备注');
      expect(draft.pending!['operation_id'], 'original-operation');
      expect(session.dirty, isTrue);
    },
  );

  testWidgets(
    'related records replace detail content without nested popup and failed load retries',
    (t) async {
      final api = reviewApi();
      final session = MaterialsSession();
      addTearDown(session.dispose);
      await t.pumpWidget(
        reviewHost(
          MaterialDetail(
            api: api,
            session: session,
            kind: 'document',
            record: {'id': 'inbound'},
            access: {'user_id': 'u1', 'grants': grants},
          ),
          GlobalKey(),
        ),
      );
      await t.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        expect(find.text('本单流水'), findsOneWidget);
        await t.ensureVisible(find.text('查看来源申请 · 批准版本 2'));
        await t.tap(find.text('查看来源申请 · 批准版本 2'));
        await t.pumpAndSettle();
        expect(find.text('申请详情与追溯'), findsOneWidget);
        expect(find.byType(Dialog), findsOneWidget);
        await t.ensureVisible(
          find.text('入库单 ${document('inbound')['number']}'),
        );
        await t.tap(find.text('入库单 ${document('inbound')['number']}'));
        await t.pumpAndSettle();
        expect(find.text('单据详情与追溯'), findsOneWidget);
        expect(find.byType(Dialog), findsOneWidget);
      }
      final original = api.intercept!;
      api.intercept = (m, p, b) async {
        if (p.endsWith('/applications/a1')) throw StateError('申请读取失败');
        return original(m, p, b);
      };
      await t.ensureVisible(find.text('查看来源申请 · 批准版本 2'));
      await t.tap(find.text('查看来源申请 · 批准版本 2'));
      await t.pumpAndSettle();
      expect(find.textContaining('申请读取失败'), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
      api.intercept = original;
      await t.tap(find.text('重试'));
      await t.pumpAndSettle();
      expect(find.text('申请内容'), findsOneWidget);
      await t.tap(find.byTooltip('返回上一张单据'));
      await t.pumpAndSettle();
      expect(find.text('单据详情与追溯'), findsOneWidget);
      final delayed = Completer<Json>();
      api.intercept = (m, p, b) =>
          p.endsWith('/applications/a1') ? delayed.future : original(m, p, b);
      await t.tap(find.text('查看来源申请 · 批准版本 2'));
      await t.pump();
      await t.tap(find.byTooltip('返回上一张单据'));
      await t.pumpAndSettle();
      delayed.complete({'application': application('a1')});
      await t.pumpAndSettle();
      expect(find.text('单据详情与追溯'), findsOneWidget);
      expect(find.text('本单流水'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  for (final size in [const Size(1440, 900), const Size(480, 760)]) {
    testWidgets('review six material pages with data $size', (t) async {
      await sized(t, size);
      await fonts();
      final api = reviewApi();
      final session = MaterialsSession();
      addTearDown(session.dispose);
      final key = GlobalKey();
      await t.pumpWidget(
        reviewHost(MaterialsWorkspace(api: api, session: session), key),
      );
      await t.pumpAndSettle();
      for (final section in [
        'applications',
        'catalog',
        'inbound',
        'stock',
        'outbound',
        'chains',
      ]) {
        await t.tap(find.byKey(ValueKey('materials-section-$section')));
        await t.pumpAndSettle();
        await shot(t, key, 'page-$section-${size.width.toInt()}');
        if (section == 'catalog') {
          await t.ensureVisible(find.text('物料档案'));
          await t.tap(find.text('物料档案'));
          await t.pumpAndSettle();
          await shot(t, key, 'page-items-${size.width.toInt()}');
        }
      }
    });
    for (final kind in ['inbound', 'outbound']) {
      testWidgets('review $kind editor and category picker $size', (t) async {
        await sized(t, size);
        await fonts();
        final api = reviewApi();
        final session = MaterialsSession();
        addTearDown(session.dispose);
        final key = GlobalKey();
        final draft = session.draft('$kind-new');
        draft.values = {
          'purpose': '日常维修领用',
          'recipient': '维修班组',
          'application_id': kind == 'inbound' ? 'a1' : '',
          'application_label': application('a1')['text'],
          'application_version': 2,
        };
        draft.lines = [
          {...line},
        ];
        await t.pumpWidget(
          reviewHost(
            MaterialEditor(
              api: api,
              session: session,
              kind: kind,
              canCatalog: true,
            ),
            key,
          ),
        );
        await t.pumpAndSettle();
        await shot(t, key, 'editor-$kind-${size.width.toInt()}');
        await t.ensureVisible(find.text('添加物料'));
        await t.tap(find.text('添加物料'));
        await t.pumpAndSettle();
        await shot(t, key, 'picker-$kind-${size.width.toInt()}');
        expect(find.text('参考单价：¥500 / 根'), findsOneWidget);
        if (kind == 'outbound') {
          expect(find.text('暂无库存'), findsOneWidget);
          final disabled = find
              .ancestor(
                of: find.text('暂无库存'),
                matching: find.byWidgetPredicate((w) => w is OutlinedButton),
              )
              .first;
          expect(t.widget<OutlinedButton>(disabled).onPressed, isNull);
        }
        await t.tap(find.text('DN35').last);
        await t.pumpAndSettle();
        final query = api.calls.lastWhere(
          (c) =>
              c['path'] ==
              '$materialsBase/${kind == 'outbound' ? 'stock' : 'items'}',
        )['query'];
        expect(query['category_id'], 'dn35');
        expect(query['offset'], 0);
        await t.enterText(
          find.byKey(const Key('material-picker-search')),
          '镀锌',
        );
        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pumpAndSettle();
        final filtered = api.calls.last['query'];
        expect(filtered['search'], '镀锌');
        expect(filtered['category_id'], 'dn35');
        await t.tap(find.text('收起分类'));
        await t.pumpAndSettle();
        await t.ensureVisible(find.text('选择物料').last);
        await t.tap(find.text('选择物料').last);
        await t.pumpAndSettle();
        expect(draft.lines.length, 2);
        expect(draft.lines.last['item_id'], 'pipe1');
        expect(draft.lines.last['category_id'], 'dn35');
        expect(t.takeException(), isNull);
      });
    }
    testWidgets('review application picker $size', (t) async {
      await sized(t, size);
      await fonts();
      final key = GlobalKey();
      await t.pumpWidget(
        reviewHost(
          MaterialRecordPicker(
            api: reviewApi(),
            title: '选择已批准申请',
            endpoint: '$materialsBase/applications',
            applicationSelection: true,
            query: const {'status': 'approved'},
            label: (v) => '${v['number']}',
          ),
          key,
        ),
      );
      await t.pumpAndSettle();
      await shot(t, key, 'picker-application-${size.width.toInt()}');
      expect(find.text(application('a1')['text']), findsOneWidget);
      expect(find.text('选择此申请'), findsWidgets);
    });
    testWidgets('review outbound detail $size', (t) async {
      await sized(t, size);
      await fonts();
      final key = GlobalKey();
      final session = MaterialsSession();
      addTearDown(session.dispose);
      await t.pumpWidget(
        reviewHost(
          MaterialDetail(
            api: reviewApi(),
            session: session,
            kind: 'document',
            record: {'id': 'outbound'},
            access: {'user_id': 'u1', 'grants': grants},
          ),
          key,
        ),
      );
      await t.pumpAndSettle();
      await shot(t, key, 'detail-outbound-${size.width.toInt()}');
      expect(find.text('剩余可退'), findsOneWidget);
      expect(find.text('导出Excel领料单'), findsOneWidget);
      expect(find.text('办理退库'), findsOneWidget);
    });
  }
}
