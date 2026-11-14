import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/account_home.dart';
import 'package:universal_hmi/shared/page_access.dart';
import 'materials_test.dart' as fixtures;

Map<String, dynamic> catalog({String home = 'materials/inbound'}) => {
  'preferences': {'home': home, 'revision': 4},
  'pages': [
    {
      'id': 'overview',
      'page': 16,
      'label': '数据总览',
      'configured': true,
      'mobile': true,
    },
    {
      'id': 'materials/inbound',
      'page': 20,
      'label': '物料管理 · 入库管理',
      'configured': true,
      'mobile': false,
    },
    {
      'id': 'history',
      'page': 12,
      'label': '历史',
      'configured': false,
      'mobile': true,
    },
  ],
};

void main() {
  test(
    'explicit target wins; mobile fallback never rewrites unified preference',
    () {
      final access = PageAccess.fromJson(catalog());
      expect(access.resolve(mobile: false).materialSection, 'inbound');
      expect(access.resolve(mobile: false, explicitView: 'overview').page, 16);
      expect(access.resolve(mobile: true).page, 16);
      expect(access.resolve(mobile: true).reason, contains('保持不变'));
      expect(access.home, 'materials/inbound');
      expect(access.allowedPages(true), {16, 12});
      expect(access.resolve(mobile: false, explicitView: 'external').page, 12);
      final revoked = PageAccess.fromJson({
        'preferences': {'home': 'materials/inbound'},
        'pages': [],
      });
      expect(revoked.resolve(mobile: false).page, 21);
      expect(revoked.home, 'materials/inbound');
      expect(
        PageAccess.fromJson(
          catalog(home: 'history'),
        ).resolve(mobile: false).page,
        16,
      );
    },
  );
  testWidgets(
    'home saves owned revision and opens selected allowed destination',
    (t) async {
      final api = fixtures.MaterialsApi();
      var data = catalog();
      api.intercept = (method, path, body) async {
        if (path == '/api/v1/page-access') return data;
        if (path == '/api/v1/account/home') {
          expect(body, {'home': 'overview', 'revision': 4});
          data = catalog(home: 'overview');
          return {'home': 'overview', 'revision': 5};
        }
        return api.answer(method, path);
      };
      String? opened;
      await t.pumpWidget(
        fixtures.host(
          SingleChildScrollView(
            child: AccountHome(api: api, onOpen: (v) => opened = v),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('当前设置：物料管理 · 入库管理'), findsOneWidget);
      await t.tap(find.byType(DropdownButtonFormField<String>));
      await t.pumpAndSettle();
      expect(find.text('历史'), findsNothing);
      await t.tap(find.text('数据总览').last);
      await t.pumpAndSettle();
      await t.tap(find.text('保存首页'));
      await t.pumpAndSettle();
      await t.tap(find.text('立即打开'));
      expect(opened, 'overview');
      expect(t.takeException(), isNull);
    },
  );
}
