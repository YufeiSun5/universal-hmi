import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/materials/category_browser.dart';
import 'package:universal_hmi/features/materials/category_tree.dart';
import 'package:universal_hmi/features/materials/form_guidance.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/workspace.dart';
import 'package:universal_hmi/features/materials/navigation.dart';
import 'materials_test.dart' as fixtures;

void main() {
  for (final size in [const Size(1366, 768), const Size(1093, 614)]) {
    testWidgets(
      'menu, narrow category tree and page occupy independent columns at $size',
      (t) async {
        await fixtures.sized(t, size);
        final api = fixtures.MaterialsApi();
        final session = MaterialsSession()..section = 'inbound';
        api.intercept = (m, p, b) async {
          if (p == '$materialsBase/categories') {
            final child = api.calls.last['query']['parent_id'] == 'r';
            return {
              'items': [
                child
                    ? {
                        'id': 'c',
                        'name': '同名长分类名称',
                        'path': '父分类 / 同名长分类名称',
                        'children': 0,
                      }
                    : {'id': 'r', 'name': '父分类', 'path': '父分类', 'children': 1},
              ],
              'total': 1,
            };
          }
          return api.answer(m, p);
        };
        await t.pumpWidget(
          fixtures.host(MaterialsWorkspace(api: api, session: session)),
        );
        await t.pumpAndSettle();
        final menu = t.getRect(
          find.byKey(const ValueKey('materials-menu-column')),
        );
        final tree = t.getRect(
          find.byKey(const ValueKey('materials-category-column')),
        );
        final page = t.getRect(
          find.byKey(const ValueKey('materials-page-column')),
        );
        expect(menu.right, lessThanOrEqualTo(tree.left));
        expect(tree.right, lessThanOrEqualTo(page.left));
        expect(tree.top, menu.top);
        expect(tree.height, menu.height);
        expect(tree.width, 120);
        expect(
          find.descendant(
            of: find.byType(MaterialNavigation),
            matching: find.byType(MaterialCategoryBrowser),
          ),
          findsNothing,
        );
        expect(find.byTooltip('父分类 / 同名长分类名称'), findsOneWidget);
        await t.tap(find.text('同名长分类名称'));
        await t.pumpAndSettle();
        expect(
          api.calls.lastWhere(
            (v) => v['path'] == '$materialsBase/inbound',
          )['query']['category_id'],
          'c',
        );
        await t.tap(find.byTooltip('收起物料目录'));
        await t.pumpAndSettle();
        expect(find.byType(MaterialNavigation), findsNothing);
        expect(find.byType(MaterialCategoryBrowser), findsOneWidget);
        expect(
          t
              .getRect(find.byKey(const ValueKey('materials-category-column')))
              .left,
          0,
        );
        await t.tap(find.text('全部分类'));
        await t.pumpAndSettle();
        expect(
          api.calls
              .lastWhere((v) => v['path'] == '$materialsBase/inbound')['query']
              .containsKey('category_id'),
          false,
        );
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        session.dispose();
      },
    );
  }
  testWidgets(
    'refresh discovers new branches and blocked deletion links to dependencies',
    (t) async {
      await fixtures.sized(t, const Size(1366, 768));
      final api = fixtures.MaterialsApi();
      final session = MaterialsSession()..section = 'catalog';
      var added = false;
      api.intercept = (m, p, b) async {
        if (p == '$materialsBase/categories') {
          final child = api.calls.last['query']['parent_id'] == 'r';
          return {
            'items': [
              child
                  ? {
                      'id': 'c',
                      'name': '新子类',
                      'path': '根类 / 新子类',
                      'children': 0,
                    }
                  : {
                      'id': 'r',
                      'name': '根类',
                      'path': '根类',
                      'children': added ? 1 : 0,
                    },
            ],
            'total': 1,
          };
        }
        if (p.endsWith('/deletion')) {
          return {
            'category': {'version': 1},
            'children': 1,
            'items': 1,
            'balances': 1,
            'can_delete': false,
          };
        }
        return api.answer(m, p);
      };
      await t.pumpWidget(
        fixtures.host(MaterialsWorkspace(api: api, session: session)),
      );
      await t.pumpAndSettle();
      expect(find.text('新子类'), findsNothing);
      added = true;
      await t.tap(find.byTooltip('刷新列表'));
      await t.pumpAndSettle();
      expect(find.text('新子类'), findsNWidgets(2));
      await t.tap(find.byTooltip('删除分类').first);
      await t.pumpAndSettle();
      await t.tap(find.text('查看分类库存'));
      await t.pumpAndSettle();
      expect(session.section, 'stock');
      expect(session.selectedCategory?['id'], 'r');
      expect(
        api.calls.lastWhere(
          (v) => v['path'] == '$materialsBase/stock',
        )['query']['category_id'],
        'r',
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  test('quantity guidance preserves precision and rejects invalid values', () {
    expect(
      materialUnscaled(materialScaled('99999999999.9999')!),
      '99999999999.9999',
    );
    for (final s in ['-1', '1e3', '1.00001', '100000000000', 'abc']) {
      expect(materialNumberError(s), isNotNull);
    }
    expect(materialNumberError('0', positive: true), isNotNull);
    expect(materialNumberError('0'), isNull);
    expect(materialNumberError('', optional: true), isNull);
  });
  testWidgets(
    'async roots expand by default and later child pages stay reachable',
    (t) async {
      await fixtures.sized(t, const Size(500, 900));
      final api = fixtures.MaterialsApi();
      final session = MaterialsSession();
      final first = Completer<Map<String, dynamic>>();
      var childReads = 0;
      api.intercept = (m, p, b) async {
        final query = api.calls.last['query'];
        if (query['parent_id'] == 'root') {
          childReads++;
          return {
            'items': [
              for (
                var i = (query['offset'] as int);
                i < ((query['offset'] as int) == 0 ? 50 : 51);
                i++
              )
                {
                  'id': 'c$i',
                  'name': '子类$i',
                  'path': '根类 / 子类$i',
                  'children': 0,
                },
            ],
            'total': 51,
          };
        }
        return first.future;
      };
      await t.pumpWidget(
        fixtures.host(
          MaterialCategoryBrowser(api: api, session: session, onSelect: (_) {}),
        ),
      );
      await t.pump();
      first.complete({
        'items': [
          {'id': 'root', 'name': '根类', 'path': '根类', 'children': 51},
        ],
        'total': 1,
      });
      await t.pumpAndSettle();
      expect(find.text('子类0'), findsOneWidget);
      expect(childReads, 1);
      final scrollable = find.descendant(
        of: find.byType(MaterialCategoryTree),
        matching: find.byType(Scrollable),
      );
      await t.scrollUntilVisible(
        find.text('更多子分类（50/51）'),
        400,
        scrollable: scrollable,
      );
      await t.tap(find.text('更多子分类（50/51）'));
      await t.pumpAndSettle();
      expect(childReads, 2);
      expect(find.text('子类50'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'requester never reads categories; classification and date persist across pages',
    (t) async {
      await fixtures.sized(t, const Size(1366, 768));
      final api = fixtures.MaterialsApi()
        ..permissions = {'materials_request': true};
      final session = MaterialsSession();
      await t.pumpWidget(
        fixtures.host(MaterialsWorkspace(api: api, session: session)),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('materials-section-chains')));
      await t.pumpAndSettle();
      expect(
        api.calls.where((v) => v['path'] == '$materialsBase/categories'),
        isEmpty,
      );
      await t.pumpWidget(const SizedBox());
      api.permissions = {...fixtures.grants};
      session.section = 'inbound';
      session.selectedCategory = {
        'id': 'parent',
        'name': '父类',
        'path': '一级 / 父类',
      };
      final key = GlobalKey<MaterialsWorkspaceState>();
      await t.pumpWidget(
        fixtures.host(MaterialsWorkspace(key: key, api: api, session: session)),
      );
      await t.pumpAndSettle();
      final query = api.calls.lastWhere(
        (v) => v['path'] == '$materialsBase/inbound',
      )['query'];
      expect(query['category_id'], 'parent');
      expect(DateTime.parse(query['from']).hour, 16);
      await t.tap(find.byKey(const ValueKey('materials-section-outbound')));
      await t.pumpAndSettle();
      expect(
        api.calls.lastWhere(
          (v) => v['path'] == '$materialsBase/outbound',
        )['query']['category_id'],
        'parent',
      );
      final before = api.calls.length;
      key.currentState!.from = '2026-11-15T16:00:00Z';
      key.currentState!.to = '2026-11-14T16:00:00Z';
      await key.currentState!.load();
      await t.pumpAndSettle();
      expect(api.calls.length, before);
      expect(find.textContaining('开始日期不能晚于结束日期'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'deletion dependency blocks submit and lost response retries same operation',
    (t) async {
      final api = fixtures.MaterialsApi();
      final session = MaterialsSession();
      var blocked = true, lost = true;
      api.intercept = (m, p, b) async {
        if (m == 'GET') {
          return {
            'category': {'version': 3},
            'children': 0,
            'items': blocked ? 1 : 0,
            'balances': 0,
            'can_delete': !blocked,
          };
        }
        if (lost) {
          lost = false;
          throw TimeoutException('响应丢失');
        }
        return {'id': 'c', 'version': 4};
      };
      await t.pumpWidget(
        fixtures.host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => changeMaterialCategoryDeletion(
                context,
                api,
                session,
                {'id': 'c', 'path': '根类 / 子类'},
              ),
              child: const Text('删除'),
            ),
          ),
        ),
      );
      await t.tap(find.text('删除'));
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认删除'))
            .onPressed,
        isNull,
      );
      await t.tap(find.text('返回'));
      await t.pumpAndSettle();
      blocked = false;
      await t.tap(find.text('删除'));
      await t.pumpAndSettle();
      await t.tap(find.text('确认删除'));
      await t.pumpAndSettle();
      final first = api.calls.last['body'];
      await t.tap(find.text('重试确认结果'));
      await t.pumpAndSettle();
      expect(api.calls.last['body'], first);
      expect(find.text('删除'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
