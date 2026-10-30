import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/point_delete.dart';
import 'package:universal_hmi/shared/api.dart';

class DeleteApi implements PlatformApi {
  Json? previewBody, commitBody;
  bool blocked = true, fail = false;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path.endsWith('/catalog')) {
      return {
        'variables': [
          {'id': 'a', 'name': '温度', 'station': '一站', 'revision': 'rev-a'},
          {'id': 'b', 'name': '压力', 'station': '二站', 'revision': 'rev-b'},
        ],
      };
    }
    if (path.endsWith('/delete-preview')) {
      previewBody = Map<String, dynamic>.from(body as Map);
      return {
        'preview_token': 'token',
        'can_commit': !blocked,
        'items': [
          {
            'id': 'a',
            'name': '一站',
            'status': blocked ? 'blocked' : 'ready',
            'references': blocked
                ? [
                    {'kind': 'screen', 'id': 's'},
                  ]
                : [],
          },
        ],
      };
    }
    if (path.endsWith('/delete-commit')) {
      commitBody = Map<String, dynamic>.from(body as Map);
      if (fail) throw StateError('conflict');
      return {};
    }
    throw StateError(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('列表预选只保留有效身份，通配筛选不触发删除', (tester) async {
    final api = DeleteApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PointDeleteDialog(api: api, initialIDs: const {'a', 'missing'}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);
    expect(api.previewBody, isNull);
    expect(api.commitBody, isNull);
    await tester.enterText(find.byType(TextField), '*压力*,不存在?');
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择当前筛选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 项'), findsOneWidget);
    await tester.tap(find.text('预览删除'));
    await tester.pumpAndSettle();
    expect(api.previewBody!['targets'], [
      {'id': 'a', 'revision': 'rev-a'},
      {'id': 'b', 'revision': 'rev-b'},
    ]);
    expect(api.commitBody, isNull);
  });
  testWidgets('站点预览阻断并仅发送名称，失败后重新预览', (tester) async {
    final api = DeleteApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StationDeleteDialog(api: api, station: '一站'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(api.previewBody!['targets'], [
      {'name': '一站'},
    ]);
    expect(find.textContaining('画面：s'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认删除'))
          .onPressed,
      isNull,
    );
    api.blocked = false;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StationDeleteDialog(api: api, station: '一站'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    api.fail = true;
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认删除'))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '一站');
    await tester.pump();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(api.commitBody!['targets'], [
      {'name': '一站'},
    ]);
    expect(api.commitBody!['preview_token'], 'token');
    expect(find.text('重新预览'), findsOneWidget);
  });
  testWidgets('筛选多选、引用阻断、失败保留选择并提交修订', (tester) async {
    final api = DeleteApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PointDeleteDialog(api: api)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '温度');
    await tester.pump();
    await tester.tap(find.text('选择当前筛选'));
    await tester.pump();
    await tester.tap(find.text('预览删除'));
    await tester.pumpAndSettle();
    expect(api.previewBody!['targets'], [
      {'id': 'a', 'revision': 'rev-a'},
    ]);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认删除'))
          .onPressed,
      isNull,
    );
    expect(find.textContaining('画面：s'), findsOneWidget);
    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();
    api.blocked = false;
    api.fail = true;
    await tester.tap(find.text('预览删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(api.commitBody!['preview_token'], 'token');
    expect(find.text('已选择 1 项'), findsOneWidget);
    expect(find.textContaining('删除失败'), findsOneWidget);
  });
}
