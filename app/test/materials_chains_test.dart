import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/materials/chain_detail.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/workspace.dart';
import 'package:universal_hmi/shared/desktop_sidebar.dart';
import 'materials_test.dart' as fixtures;

void main() {
  for (final size in [
    const Size(1366, 768),
    const Size(390, 844),
    const Size(844, 390),
  ]) {
    testWidgets('material side navigation and chain filter ${size.width}', (
      t,
    ) async {
      await fixtures.sized(t, size);
      final api = fixtures.MaterialsApi();
      final session = MaterialsSession();
      await t.pumpWidget(
        fixtures.host(MaterialsWorkspace(api: api, session: session)),
      );
      await t.pumpAndSettle();
      if (size.width >= 700) {
        expect(find.byType(DesktopSidebar), findsOneWidget);
      }
      final apps = t.getRect(
        find.byKey(const ValueKey('materials-section-applications')),
      );
      final log = t.getRect(
        find.byKey(const ValueKey('materials-section-chains')),
      );
      expect(apps.left, log.left);
      expect(log.top, greaterThan(apps.bottom));
      await t.tap(find.byKey(const ValueKey('materials-section-chains')));
      await t.pumpAndSettle();
      expect(
        api.calls.where((c) => c['path'] == '$materialsBase/chains'),
        hasLength(1),
      );
      final dropdown = find.byKey(const ValueKey('materials-chain-kind-'));
      await t.ensureVisible(dropdown);
      await t.tap(dropdown);
      await t.pumpAndSettle();
      await t.tap(find.text('出库退库链').last);
      await t.pumpAndSettle();
      expect(api.calls.last['query']['kind'], 'outbound');
      await t.tap(find.byTooltip('收起物料目录'));
      await t.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('materials-section-chains')),
        findsNothing,
      );
      await t.ensureVisible(find.byTooltip('显示物料目录'));
      await t.tap(find.byTooltip('显示物料目录'));
      await t.pumpAndSettle();
      if (size.width >= 700) {
        await t.scrollUntilVisible(
          find.byKey(const ValueKey('materials-section-chains')),
          100,
          scrollable: find
              .descendant(
                of: find.byType(DesktopSidebar),
                matching: find.byType(Scrollable),
              )
              .first,
        );
      }
      expect(
        find.byKey(const ValueKey('materials-section-chains')),
        findsOneWidget,
      );
      expect(session.section, 'chains');
      if (size.width < 700) {
        final requestCount = api.calls
            .where((c) => c['path'] == '$materialsBase/inbound')
            .length;
        await t.tap(find.byTooltip('展开物料目录'));
        await t.pumpAndSettle();
        expect(find.byType(DesktopSidebar), findsOneWidget);
        await t.tap(
          find.byKey(const ValueKey('materials-section-inbound')).last,
        );
        await t.pumpAndSettle();
        expect(session.section, 'inbound');
        expect(
          api.calls.where((c) => c['path'] == '$materialsBase/inbound').length,
          requestCount + 1,
        );
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    });
  }
  testWidgets(
    'chain detail honors summary-only nodes and stable reference links',
    (t) async {
      await fixtures.sized(t, const Size(390, 844));
      final api = fixtures.MaterialsApi();
      final session = MaterialsSession();
      api.responses['$materialsBase/chains/application/a'] = {
        'chain': {
          'id': 'a',
          'kind': 'application',
          'number': 'SQ-1',
          'status': 'approved',
        },
        'nodes': {
          'total': 2,
          'items': [
            {
              'id': 'v1',
              'kind': 'approved',
              'number': 'SQ-1',
              'created': '2026-11-13T00:00:00Z',
              'owner': '审批人',
              'reference_kind': 'application',
              'reference_id': 'a',
              'can_open': true,
              'application': {
                'version': 1,
                'text': '维修需要材料',
                'status': 'approved',
                'signature_id': 'sig',
              },
            },
            {
              'id': 'd1',
              'kind': 'inbound',
              'number': 'RK-1',
              'created': '2026-11-13T00:01:00Z',
              'owner': '',
              'reference_kind': 'document',
              'reference_id': 'd',
              'can_open': false,
              'summary_only': true,
              'document': {
                'status': 'confirmed',
                'lines': [
                  {
                    'name': '阀门',
                    'specification': 'DN25',
                    'quantity': '2',
                    'unit': '个',
                    'category': '正常',
                  },
                ],
              },
            },
          ],
        },
      };
      await t.pumpWidget(
        fixtures.host(
          MaterialChainDetail(
            api: api,
            session: session,
            record: const {'id': 'a', 'kind': 'application'},
            access: const {'grants': fixtures.grants},
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('当前权限可查看入库摘要'), findsOneWidget);
      expect(find.text('打开原单'), findsOneWidget);
      expect(find.textContaining('合计金额'), findsNothing);
      await t.ensureVisible(find.text('打开原单'));
      await t.tap(find.text('打开原单'));
      await t.pumpAndSettle();
      expect(
        api.calls.any((c) => c['path'] == '$materialsBase/applications/a'),
        isTrue,
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
