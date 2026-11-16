import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:universal_hmi/features/materials/detail.dart';
import 'package:universal_hmi/features/materials/requisition_editor.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/workspace.dart';
import 'package:universal_hmi/features/materials/requisition_export.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'materials_test.dart' show MaterialsApi, sized, openEditor;

const workflowGrants = {
  'materials_request': true,
  'materials_review': true,
  'materials_approve': true,
  'materials_receive': true,
};
Json step(String stage, int version, {String decision = 'approved'}) => {
  'id': '$version-$stage',
  'stage': stage,
  'actor': '评审用户',
  'actor_id': 'u1',
  'created':
      '2026-11-16T0${const {'compile': 1, 'review': 2, 'approval': 3, 'receipt': 4}[stage]}:20:00Z',
  'decision': decision,
  'signature_id': decision == 'rejected' ? '' : 'sig',
  'reason': decision == 'rejected' ? '请核对弯头数量并补充说明' : '',
};
Json requisition() => {
  'project': '示例工程5号楼',
  'project_number': 'GC-2026-016',
  'requested_at': '2026-11-16',
  'contractor': '示例建设单位',
  'asset_ids': ['source'],
  'attachments': [
    {'id': 'source', 'name': '工程物资请购清单.xlsx', 'kind': 'attachment'},
  ],
  'lines': [
    {
      'name': '90°弯头',
      'specification': 'DN100',
      'unit': '个',
      'quantity': '22',
      'needed_at': '有',
      'notes': '',
    },
    {
      'name': '无缝钢管',
      'specification': 'Φ100',
      'unit': '米',
      'quantity': '60',
      'needed_at': {'要求': '下周内', '补充': '分批'},
      'notes': '已领30米',
    },
  ],
};
Json application() => {
  'workflow': 2,
  'id': 'a1',
  'number': 'SQ-20261116-REVIEW',
  'owner_id': 'u1',
  'owner': '评审用户',
  'version': 2,
  'status': 'review',
  'text': '用于楼栋维修，请核对清单。',
  'submitted': '2026-11-16T01:20:00Z',
  'requisition': requisition(),
  'steps': [step('compile', 2, decision: 'submitted')],
};

class RequisitionSelector extends FileSelectorPlatform {
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async =>
      XFile.fromData(Uint8List.fromList([80, 75, 1, 2]), name: '请购清单.xlsx');
}

Future<void> screenshot(WidgetTester t, GlobalKey key, String name) async {
  final directory = Platform.environment['HMI_WIDGET_SCREENSHOTS'];
  if (directory == null) return;
  await t.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
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
    theme: workspaceTheme(),
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets(
    'batch exports only selected closed versions and retains selection on failure',
    (t) async {
      await sized(t, const Size(1280, 900));
      final api = MaterialsApi();
      api.responses['$materialsBase/applications'] = {
        'items': [
          {...application(), 'id': 'closed1', 'status': 'closed'},
          {...application(), 'id': 'closed2', 'status': 'closed'},
          {...application(), 'id': 'pending', 'status': 'review'},
        ],
        'total': 3,
      };
      api.intercept = (m, p, b) async {
        if (m == 'POST') throw StateError('network failure');
        return api.answer(m, p);
      };
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RequisitionExportDialog(api: api)),
        ),
      );
      await t.pumpAndSettle();
      expect(api.calls.first['query']['status'], 'closed');
      expect(
        t
            .widget<CheckboxListTile>(find.byType(CheckboxListTile).last)
            .onChanged,
        isNull,
      );
      await t.tap(find.text('选择本页'));
      await t.pumpAndSettle();
      await t.tap(find.text('导出所选 2 张'));
      await t.pumpAndSettle();
      expect(api.calls.last['body']['items'], [
        {'id': 'closed1', 'version': 2},
        {'id': 'closed2', 'version': 2},
      ]);
      expect(find.textContaining('导出失败'), findsOneWidget);
      expect(find.text('已选 2 / 50 张'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'Excel preview remains editable, records compile confirmation and original attachment',
    (t) async {
      await sized(t, const Size(1280, 900));
      final original = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = RequisitionSelector();
      addTearDown(() => FileSelectorPlatform.instance = original);
      final api = MaterialsApi();
      final session = MaterialsSession();
      addTearDown(session.dispose);
      api.intercept = (m, p, b) async {
        if (p.endsWith('/applications/import')) {
          return {
            'requisition': {
              ...requisition(),
              'template_asset_id': 'source',
              'template_sheet': 'Sheet1',
            },
            'text': '从模板恢复的申请说明',
            'sheet': 'Sheet1',
            'sheets': ['Sheet1'],
            'warnings': <String>[],
            'asset': {
              'id': 'source',
              'name': '请购清单.xlsx',
              'kind': 'attachment',
            },
          };
        }
        return api.answer(m, p);
      };
      await openEditor(t, api, session, 'application');
      await t.tap(find.text('导入 Excel 并复核'));
      await t.pumpAndSettle();
      expect(find.text('示例工程5号楼'), findsOneWidget);
      expect(find.text('90°弯头'), findsOneWidget);
      final quantity = find.byWidgetPredicate(
        (w) => w is TextField && w.key.toString().contains('-quantity'),
      );
      await t.enterText(quantity.first, '24');
      await t.tap(find.text('复核并提交'));
      await t.pumpAndSettle();
      expect(
        api.calls.where((c) => c['path'] == '$materialsBase/applications'),
        isEmpty,
      );
      await t.tap(find.text('确认并签名提交'));
      await t.pumpAndSettle();
      final sent =
          api.calls.singleWhere(
                (c) => c['path'] == '$materialsBase/applications',
              )['body']
              as Json;
      expect(sent['workflow'], 2);
      expect(sent['requisition']['lines'][0]['quantity'], '24');
      expect(sent['requisition']['asset_ids'], ['source']);
      expect(sent['requisition']['template_asset_id'], 'source');
      expect(sent['requisition']['template_sheet'], 'Sheet1');
      expect(sent['text'], '从模板恢复的申请说明');
      expect(sent['requisition']['lines'][1]['needed_at'], {
        '要求': '下周内',
        '补充': '分批',
      });
      expect(session.dirty, false);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'same account can review approve and acknowledge, each command binds its stage',
    (t) async {
      await sized(t, const Size(1280, 1050));
      final api = MaterialsApi();
      final session = MaterialsSession();
      addTearDown(session.dispose);
      var current = application();
      api.intercept = (m, p, b) async {
        if (p.endsWith('/decision')) {
          expect(b['stage'], current['status']);
          expect(b['version'], 2);
          current = {
            ...current,
            'status': const {
              'review': 'approval',
              'approval': 'receipt',
              'receipt': 'closed',
            }[b['stage']],
            'steps': [
              ...current['steps'],
              step(b['stage'], 2, decision: b['decision']),
            ],
          };
          return current;
        }
        if (p.endsWith('/applications/a1')) {
          return {
            'application': current,
            'versions': [current],
            'inbound': {'items': <Json>[], 'total': 0},
          };
        }
        return api.answer(m, p);
      };
      await t.pumpWidget(
        reviewHost(
          MaterialDetail(
            api: api,
            session: session,
            kind: 'application',
            record: current,
            access: {'user_id': 'u1', 'grants': workflowGrants},
          ),
          GlobalKey(),
        ),
      );
      await t.pumpAndSettle();
      for (final label in ['审核通过', '批准申请', '确认已阅']) {
        final button = find.text(label);
        await t.ensureVisible(button);
        await t.tap(button);
        await t.pumpAndSettle();
        await t.tap(find.widgetWithText(FilledButton, '确认'));
        await t.pumpAndSettle();
      }
      expect(current['status'], 'closed');
      expect((current['steps'] as List).length, 4);
      expect(
        api.calls
            .where((c) => c['method'] == 'POST')
            .map((c) => c['body']['stage']),
        ['review', 'approval', 'receipt'],
      );
      expect(t.takeException(), isNull);
    },
  );
  for (final size in [const Size(1280, 1000), const Size(480, 800)]) {
    testWidgets('versioned chain and preview fit $size', (t) async {
      await sized(t, size);
      await fonts();
      final key = GlobalKey();
      final api = MaterialsApi();
      final session = MaterialsSession();
      addTearDown(session.dispose);
      final first = {
        ...application(),
        'version': 1,
        'status': 'rejected',
        'steps': [
          step('compile', 1, decision: 'submitted'),
          step('review', 1, decision: 'rejected'),
        ],
      };
      final current = application();
      api.responses['$materialsBase/applications/a1'] = {
        'application': current,
        'versions': [first, current],
        'inbound': {'items': <Json>[], 'total': 0},
      };
      await t.pumpWidget(
        reviewHost(
          MaterialDetail(
            api: api,
            session: session,
            kind: 'application',
            record: current,
            access: {'user_id': 'u1', 'grants': workflowGrants},
          ),
          key,
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await screenshot(t, key, 'requisition-detail-${size.width.toInt()}');
      await t.ensureVisible(find.text('修改重提'));
      await t.tap(find.text('修改重提'));
      await t.pumpAndSettle();
      await screenshot(t, key, 'requisition-chain-${size.width.toInt()}');
      await t.ensureVisible(find.text('查看此版清单与签名'));
      await t.tap(find.text('查看此版清单与签名'));
      await t.pumpAndSettle();
      expect(find.text('第 2 版清单'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(find.byTooltip('关闭版本'));
      await t.pumpAndSettle();
      await t.pumpWidget(
        reviewHost(
          RequisitionEditor(api: api, session: session, seed: current),
          key,
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await screenshot(t, key, 'requisition-editor-${size.width.toInt()}');
      await t.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'review and receive permissions expose application page with todo as default',
    (t) async {
      for (final capability in ['review', 'receive']) {
        final api = MaterialsApi()
          ..permissions = {'materials_$capability': true};
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(body: MaterialsWorkspace(api: api)),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('申请与审批'), findsWidgets);
        final call = api.calls.lastWhere(
          (c) => c['path'] == '$materialsBase/applications',
        );
        expect(call['query']['status'], 'todo');
        expect(find.text('新建申请'), findsNothing);
        await t.pumpWidget(const SizedBox());
      }
    },
  );
}
