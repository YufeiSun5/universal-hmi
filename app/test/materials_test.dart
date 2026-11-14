import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/materials/detail.dart';
import 'package:universal_hmi/features/materials/category_tree.dart';
import 'package:universal_hmi/features/materials/editor.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/signature.dart';
import 'package:universal_hmi/features/materials/workspace.dart';
import 'package:universal_hmi/features/materials/widgets.dart';
import 'package:universal_hmi/platform/process_files.dart';
import 'package:universal_hmi/shared/api.dart';

const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGP0qJjNgA0wYRUdtBIAEyYBa74a5twAAAAASUVORK5CYII=';
const grants = {
  'materials_request': true,
  'materials_approve': true,
  'materials_inbound': true,
  'materials_outbound': true,
  'materials_catalog': true,
};

class MaterialsApi implements PlatformApi {
  Json permissions = {...grants};
  final calls = <Json>[];
  final responses = <String, Json>{};
  Future<Json> Function(String, String, Json)? intercept;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    final payload = body == null
        ? <String, dynamic>{}
        : jsonDecode(jsonEncode(body)) as Json;
    calls.add({
      'method': method,
      'path': path,
      'body': payload,
      'query': query ?? {},
    });
    if (intercept != null) return intercept!(method, path, payload);
    return answer(method, path);
  }

  Json answer(String method, String path) {
    if (responses.containsKey(path)) return responses[path]!;
    if (path.endsWith('/capabilities')) {
      return {'user_id': 'u1', 'grants': permissions};
    }
    if (path == '/api/v1/account/signature') {
      return {'asset_id': 'sig', 'version': 1};
    }
    if (path.contains('/assets/')) return {'data': png};
    if (method == 'POST') return {'id': 'saved', 'version': 1};
    return {'items': <Json>[], 'total': 0};
  }

  @override
  void close() {}
  @override
  Future<Uint8List> download(String id) => throw UnimplementedError();
  @override
  Future<Json> upload(String name, Uint8List bytes) =>
      throw UnimplementedError();
}

Future<void> sized(WidgetTester t, Size size) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = size;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));
Widget editorHost(
  MaterialsApi api,
  MaterialsSession session,
  String kind, {
  Json seed = const {},
}) => host(
  Builder(
    builder: (context) => TextButton(
      onPressed: () =>
          editMaterial(context, api, session, kind: kind, seed: seed),
      child: const Text('打开'),
    ),
  ),
);
Future<void> openEditor(
  WidgetTester t,
  MaterialsApi api,
  MaterialsSession session,
  String kind, {
  Json seed = const {},
}) async {
  await t.pumpWidget(editorHost(api, session, kind, seed: seed));
  await t.tap(find.text('打开'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'material signature link opens the personal account without losing draft',
    (t) async {
      final api = MaterialsApi();
      final session = MaterialsSession();
      session.draft('application').set('text', '保留这份申请草稿');
      var opened = 0;
      session.openAccount = () => opened++;
      await t.pumpWidget(host(MaterialsWorkspace(api: api, session: session)));
      await t.pumpAndSettle();
      expect(find.byType(PersonalSignature), findsNothing);
      await t.tap(find.byTooltip('设置个人签名'));
      await t.pumpAndSettle();
      expect(opened, 1);
      expect(session.draft('application').values['text'], '保留这份申请草稿');
      expect(
        api.calls.where((v) => v['path'] == '/api/v1/account/signature'),
        isEmpty,
      );
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'signature deletion confirms and ambiguous retry retains operation and history',
    (t) async {
      await sized(t, const Size(390, 844));
      final api = MaterialsApi();
      var fail = true;
      var current = <String, dynamic>{'asset_id': 'sig', 'version': 1};
      final versions = <Json>[
        {
          'asset_id': 'sig',
          'version': 1,
          'action': 'created',
          'created': '2026-11-13T00:00:00Z',
        },
      ];
      api.intercept = (m, p, b) async {
        if (p == '/api/v1/account/signature/history') {
          return {'items': versions, 'total': versions.length};
        }
        if (p == '/api/v1/account/signature') {
          if (m == 'GET') return current;
          expect(b['delete'], true);
          current = {'asset_id': '', 'version': 2};
          if (fail) {
            fail = false;
            versions.insert(0, {
              'asset_id': '',
              'version': 2,
              'action': 'deleted',
              'created': '2026-11-13T01:00:00Z',
            });
            throw TimeoutException('删除响应丢失');
          }
          return current;
        }
        return api.answer(m, p);
      };
      await t.pumpWidget(
        host(SingleChildScrollView(child: PersonalSignature(api: api))),
      );
      await t.pumpAndSettle();
      expect(find.text('签名历史（1）'), findsOneWidget);
      await t.tap(find.text('删除当前签名'));
      await t.pumpAndSettle();
      await t.tap(find.text('返回'));
      await t.pumpAndSettle();
      expect(api.calls.where((v) => v['method'] == 'POST'), isEmpty);
      await t.tap(find.text('删除当前签名'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认'));
      await t.pumpAndSettle();
      final sent = api.calls.where((v) => v['method'] == 'POST').single['body'];
      expect(find.text('重试确认删除'), findsOneWidget);
      await t.ensureVisible(find.text('重试确认删除'));
      await t.tap(find.text('重试确认删除'));
      await t.pumpAndSettle();
      expect(api.calls.where((v) => v['method'] == 'POST').last['body'], sent);
      expect(find.text('尚未上传签名'), findsOneWidget);
      expect(find.text('签名历史（2）'), findsOneWidget);
      await t.ensureVisible(find.text('第 1 版 · 创建'));
      await t.tap(find.text('第 1 版 · 创建'));
      await t.pumpAndSettle();
      expect(find.byType(MaterialAssetView), findsOneWidget);
      expect(find.text('删除当前签名'), findsNothing);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'each page queries on entry and reentry without clicking search',
    (t) async {
      await sized(t, const Size(1366, 768));
      final api = MaterialsApi();
      final session = MaterialsSession();
      final pending = Completer<Json>();
      api.intercept = (m, p, b) async {
        if (p == '$materialsBase/inbound') return pending.future;
        return api.answer(m, p);
      };
      await t.pumpWidget(host(MaterialsWorkspace(api: api, session: session)));
      await t.pumpAndSettle();
      expect(
        api.calls
            .where((v) => v['path'] == '$materialsBase/applications')
            .length,
        1,
      );
      for (final section in [
        'catalog',
        'inbound',
        'stock',
        'outbound',
        'chains',
        'applications',
      ]) {
        await t.tap(find.byKey(ValueKey('materials-section-$section')));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        final endpoint = section == 'catalog' ? 'categories' : section;
        expect(
          api.calls.where((c) => c['path'] == '$materialsBase/$endpoint'),
          isNotEmpty,
        );
      }
      // A slow old page must not replace the active page's data.
      pending.complete({
        'items': [
          {'id': 'late', 'number': '不应显示的旧入库单'},
        ],
        'total': 1,
      });
      await t.pumpAndSettle();
      expect(find.text('不应显示的旧入库单'), findsNothing);
      final count = api.calls.length;
      await t.tap(find.byKey(const ValueKey('materials-section-applications')));
      await t.pumpAndSettle();
      expect(api.calls.length, count + 1);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(host(MaterialsWorkspace(api: api, session: session)));
      await t.pumpAndSettle();
      expect(api.calls.last['path'], '$materialsBase/applications');
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  for (final width in [1366.0, 390.0]) {
    testWidgets('approval labels show distinct status badges at width $width', (
      t,
    ) async {
      await sized(t, Size(width, 844));
      final api = MaterialsApi();
      api.responses['$materialsBase/applications'] = {
        'items': [
          for (final status in ['pending', 'approved', 'rejected'])
            {
              'id': status,
              'number': 'SQ-$status',
              'text': '测试申请',
              'status': status,
              'version': 1,
            },
        ],
        'total': 3,
      };
      await t.pumpWidget(host(MaterialsWorkspace(api: api)));
      await t.pumpAndSettle();
      expect(find.byType(MaterialStatusBadge), findsNWidgets(3));
      for (final label in ['待审批', '已通过', '已驳回']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('category tree loads child pages and keeps expansion', (t) async {
    await sized(t, const Size(360, 640));
    final api = MaterialsApi();
    final session = MaterialsSession();
    api.intercept = (m, p, b) async => {
      'items': [
        {
          'id': 'child',
          'parent_id': 'root',
          'name': '二级分类',
          'path': '一级分类 / 二级分类',
          'children': 0,
        },
      ],
      'total': 1,
    };
    Widget tree() => host(
      MaterialCategoryTree(
        api: api,
        roots: const [
          {'id': 'root', 'name': '一级分类', 'path': '一级分类', 'children': 1},
        ],
        session: session,
        onEdit: (_) {},
        onAdd: (_) {},
      ),
    );
    await t.pumpWidget(tree());
    await t.pumpAndSettle();
    expect(find.text('二级分类'), findsOneWidget);
    expect(api.calls.single['query']['parent_id'], 'root');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(tree());
    await t.pumpAndSettle();
    expect(find.text('二级分类'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('category-expand-root')));
    await t.pumpAndSettle();
    expect(find.text('二级分类'), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(tree());
    await t.pumpAndSettle();
    expect(find.text('二级分类'), findsNothing);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    session.dispose();
  });
  test(
    'uncertain command freezes payload and same ID; rejection unlocks editing',
    () async {
      final api = MaterialsApi();
      final draft = MaterialDraft(onChanged: () {});
      api.intercept = (m, p, b) async =>
          throw TimeoutException('lost response');
      await expectLater(
        draft.submit(api, '/out', {'quantity': '1'}),
        throwsA(isA<TimeoutException>()),
      );
      final first = jsonEncode(draft.pending);
      expect(draft.pending, isNotNull);
      api.intercept = (m, p, b) async => {'id': 'same-result'};
      await draft.submit(api, '/out', {'quantity': '999'});
      expect(jsonEncode(api.calls.last['body']), first);
      expect(draft.pending, isNull);
      api.intercept = (m, p, b) async =>
          throw const PlatformRequestException(409, '库存变化');
      await expectLater(
        draft.submit(api, '/out', {'quantity': '2'}),
        throwsA(isA<PlatformRequestException>()),
      );
      expect(draft.pending, isNull);
    },
  );
  for (final size in [
    const Size(1920, 1080),
    const Size(1366, 768),
    const Size(800, 600),
    const Size(360, 780),
    const Size(390, 844),
    const Size(430, 900),
    const Size(844, 390),
  ]) {
    testWidgets('six pages fit ${size.width}x${size.height}', (t) async {
      await sized(t, size);
      final api = MaterialsApi();
      final session = MaterialsSession();
      await t.pumpWidget(host(MaterialsWorkspace(api: api, session: session)));
      await t.pumpAndSettle();
      for (final section in [
        'applications',
        'catalog',
        'inbound',
        'stock',
        'outbound',
        'chains',
      ]) {
        final button = find.byKey(ValueKey('materials-section-$section'));
        await t.ensureVisible(button);
        await t.tap(button);
        await t.pumpAndSettle();
        expect(session.section, section);
        expect(
          find.textContaining(
            section == 'catalog'
                ? '暂无记录'
                : section == 'inbound' || section == 'outbound'
                ? '该时间段和分类下没有单据'
                : '暂无记录，请调整筛选',
          ),
          section == 'catalog' ? findsWidgets : findsOneWidget,
        );
        expect(t.takeException(), isNull);
      }
      await t.pumpWidget(const SizedBox());
      session.dispose();
    });
  }
  testWidgets('permission projection and failed load can retry', (t) async {
    final api = MaterialsApi();
    var fail = true;
    api.intercept = (m, p, b) async {
      if (fail) throw Exception('网络失败');
      return api.answer(m, p);
    };
    api.permissions = {'materials_inbound': true};
    await t.pumpWidget(host(MaterialsWorkspace(api: api)));
    await t.pumpAndSettle();
    expect(find.textContaining('网络失败'), findsOneWidget);
    fail = false;
    await t.tap(find.text('重试'));
    await t.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('materials-section-applications')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('materials-section-catalog')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('materials-section-inbound')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('materials-section-stock')),
      findsOneWidget,
    );
    expect(find.text('新建入库'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    api.permissions = {};
    await t.pumpWidget(host(MaterialsWorkspace(api: api)));
    await t.pumpAndSettle();
    expect(find.textContaining('没有物料业务权限'), findsOneWidget);
  });
  testWidgets(
    'application timeout keeps Chinese input and retry does not duplicate ID',
    (t) async {
      await sized(t, const Size(390, 844));
      final api = MaterialsApi();
      final session = MaterialsSession();
      var lost = true;
      api.intercept = (m, p, b) async {
        if (m == 'POST' && lost) throw TimeoutException('响应丢失');
        return api.answer(m, p);
      };
      await openEditor(t, api, session, 'application');
      final field = find.byKey(const ValueKey('material-field-text'));
      await t.enterText(field, '采购阀门：中文长文本与回车\n第二行说明');
      await t.tap(find.byKey(const Key('material-submit')));
      await t.pumpAndSettle();
      expect(find.textContaining('提交结果待确认'), findsOneWidget);
      expect(t.widget<TextField>(field).enabled, false);
      final first = api.calls.last['body'];
      lost = false;
      await t.tap(find.text('重试确认结果'));
      await t.pumpAndSettle();
      expect(api.calls.last['body'], first);
      expect(session.dirty, false);
      expect(find.text('打开'), findsOneWidget);
      expect(t.takeException(), isNull);
      session.dispose();
    },
  );
  testWidgets(
    'draft survives close and reopen; definite failure keeps editing',
    (t) async {
      final api = MaterialsApi();
      final session = MaterialsSession();
      api.intercept = (m, p, b) async {
        if (m == 'POST') throw const PlatformRequestException(400, '请输入有效单价');
        return api.answer(m, p);
      };
      session.draft('item-new').values = {
        'unit': '台',
        'category_id': 'c',
        'warning': '0',
      };
      await openEditor(t, api, session, 'item');
      await t.enterText(
        find.byKey(const ValueKey('material-field-name')),
        '循环泵',
      );
      await t.tap(find.byKey(const Key('material-submit')));
      await t.pumpAndSettle();
      expect(find.textContaining('有效单价'), findsOneWidget);
      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('material-field-name')),
            )
            .enabled,
        true,
      );
      await t.tap(find.text('保留并返回'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认'));
      await t.pumpAndSettle();
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      expect(
        t
            .widget<TextField>(
              find.byKey(const ValueKey('material-field-name')),
            )
            .controller!
            .text,
        '循环泵',
      );
      expect(session.dirty, true);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'inbound cannot silently omit failed photos; explicit retry recovers',
    (t) async {
      final api = MaterialsApi();
      final session = MaterialsSession();
      final draft = session.draft('inbound-new');
      draft.lines.add({
        'key': 'l1',
        'item_id': 'i',
        'category_id': 'c',
        'name': '阀门',
        'unit': '个',
        'quantity': '1',
        'price': '',
      });
      draft.images.add(
        MaterialImageDraft(ProcessFile('凭证.png', base64Decode(png)))
          ..error = '上传失败',
      );
      draft.changed();
      await openEditor(t, api, session, 'inbound');
      await t.tap(find.byKey(const Key('material-submit')));
      await t.pumpAndSettle();
      expect(find.textContaining('有图片未上传成功'), findsOneWidget);
      expect(
        api.calls.where((v) => v['path'] == '$materialsBase/inbound'),
        isEmpty,
      );
      await t.ensureVisible(find.text('重试上传'));
      await t.tap(find.text('重试上传'));
      await t.pumpAndSettle();
      expect(draft.images.single.assetID, 'saved');
      expect(find.text('已上传'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets('outbound uses server price preview and only confirms once', (
    t,
  ) async {
    final api = MaterialsApi();
    final session = MaterialsSession();
    final draft = session.draft('outbound-new');
    draft.values = {'purpose': '维修'};
    draft.lines.add({
      'key': 'l1',
      'item_id': 'a',
      'name': '阀门',
      'unit': '个',
      'category_id': 'normal',
      'category_name': '正常',
      'quantity': '5',
      'price': '',
      'item_version': 1,
      'balance_version': 2,
    });
    final pending = Completer<Json>();
    api.intercept = (m, p, b) async {
      if (p.endsWith('/outbound-preview')) {
        return {
          'lines': [
            {
              'name': '阀门',
              'category': '正常',
              'quantity': '5',
              'unit': '个',
              'price': '12.5',
              'amount': '62.50',
            },
          ],
          'known_amount': '62.50',
          'missing_prices': 0,
          'signature': {'asset_id': 'sig', 'version': 3},
          'inputs': [
            {
              'item_id': 'a',
              'category_id': 'normal',
              'quantity': '5',
              'item_version': 9,
              'balance_version': 7,
            },
          ],
        };
      }
      if (p.endsWith('/outbound')) return pending.future;
      return api.answer(m, p);
    };
    await openEditor(t, api, session, 'outbound');
    await t.tap(find.byKey(const Key('material-submit')));
    // The editor stays busy while its confirmation dialog is open.
    await t.pump();
    await t.pump(const Duration(milliseconds: 350));
    expect(find.text('合计金额：62.50'), findsOneWidget);
    expect(
      api.calls.where((v) => v['path'].toString().endsWith('/outbound')),
      isEmpty,
    );
    await t.tap(find.text('确认扣减库存'));
    await t.pump();
    final saved = api.calls
        .where((v) => v['path'].toString().endsWith('/outbound'))
        .single;
    expect(saved['body']['lines'][0]['item_version'], 9);
    expect(saved['body']['signature_version'], 3);
    expect(
      t
          .widget<FilledButton>(find.byKey(const Key('material-submit')))
          .onPressed,
      isNull,
    );
    pending.complete({'id': 'out1'});
    await t.pumpAndSettle();
    expect(session.dirty, false);
    expect(t.takeException(), isNull);
    session.dispose();
  });
  testWidgets(
    'signature selection is not saving; failed save preserves selection',
    (t) async {
      final api = MaterialsApi();
      var failed = true;
      api.intercept = (m, p, b) async {
        if (m == 'POST' && p == '/api/v1/account/signature' && failed) {
          throw const PlatformRequestException(400, '保存失败');
        }
        return api.answer(m, p);
      };
      await t.pumpWidget(
        host(
          SingleChildScrollView(
            child: PersonalSignature(
              api: api,
              pickImage: () async => [ProcessFile('签名.png', base64Decode(png))],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('选择签名图片'));
      await t.pumpAndSettle();
      expect(api.calls.where((v) => v['method'] == 'POST'), isEmpty);
      await t.tap(find.text('保存签名'));
      await t.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
      failed = false;
      await t.tap(find.text('保存签名'));
      await t.pumpAndSettle();
      expect(
        api.calls
            .where(
              (v) =>
                  v['path'] == '$materialsBase/assets' && v['method'] == 'POST',
            )
            .length,
        1,
      );
      expect(find.text('签名已保存，历史单据保持原签名。'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('signature close protects selected image and pending save', (
    t,
  ) async {
    final api = MaterialsApi();
    await t.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (dialog) => AlertDialog(
                content: PersonalSignature(
                  api: api,
                  pickImage: () async => [
                    ProcessFile('签名.png', base64Decode(png)),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.maybePop(dialog),
                    child: const Text('关闭签名'),
                  ),
                ],
              ),
            ),
            child: const Text('打开签名'),
          ),
        ),
      ),
    );
    await t.tap(find.text('打开签名'));
    await t.pumpAndSettle();
    await t.tap(find.text('选择签名图片'));
    await t.pumpAndSettle();
    await t.tap(find.text('关闭签名'));
    await t.pumpAndSettle();
    expect(find.text('放弃未保存的签名？'), findsOneWidget);
    await t.tap(find.text('返回'));
    await t.pumpAndSettle();
    expect(find.text('保存签名'), findsOneWidget);
    api.intercept = (m, p, b) async {
      if (m == 'POST' && p == '/api/v1/account/signature') {
        throw TimeoutException('connection lost');
      }
      return api.answer(m, p);
    };
    await t.tap(find.text('保存签名'));
    await t.pumpAndSettle();
    await t.tap(find.text('关闭签名'));
    await t.pumpAndSettle();
    expect(find.textContaining('签名保存尚未确认'), findsOneWidget);
    expect(find.text('重试确认保存'), findsOneWidget);
    api.intercept = null;
    await t.tap(find.text('重试确认保存'));
    await t.pumpAndSettle();
    await t.tap(find.text('关闭签名'));
    await t.pumpAndSettle();
    expect(find.text('选择签名图片'), findsNothing);
    expect(t.takeException(), isNull);
  });
  testWidgets(
    'outbound detail forbids other user return and export failure is separate',
    (t) async {
      await sized(t, const Size(390, 844));
      final api = MaterialsApi();
      final session = MaterialsSession();
      final doc = {
        'id': 'out1',
        'number': 'CK-1',
        'kind': 'outbound',
        'owner_id': 'other',
        'owner': '其他人员',
        'created': '2026-11-13T00:00:00Z',
        'status': 'part_returned',
        'known_amount': '62.50',
        'missing_prices': 0,
        'lines': [
          {
            'name': '阀门',
            'unit': '个',
            'category': '正常',
            'quantity': '5',
            'price': '12.5',
            'amount': '62.50',
            'returned': '2',
            'remaining': '3',
          },
        ],
      };
      api.responses['$materialsBase/documents/out1'] = {
        'document': doc,
        'returns': {'items': [], 'total': 0},
        'movements': {'items': [], 'total': 0},
      };
      api.intercept = (m, p, b) async {
        if (p.endsWith('/export')) throw Exception('Excel生成失败');
        return api.answer(m, p);
      };
      await t.pumpWidget(
        host(
          MaterialDetail(
            api: api,
            session: session,
            kind: 'document',
            record: doc,
            access: {'user_id': 'u1', 'grants': grants},
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('办理退库'), findsNothing);
      await t.ensureVisible(find.text('导出Excel出库单'));
      await t.tap(find.text('导出Excel出库单'));
      await t.pumpAndSettle();
      expect(find.textContaining('不会再次扣库存'), findsOneWidget);
      expect(api.calls.where((v) => v['method'] == 'POST'), isEmpty);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
