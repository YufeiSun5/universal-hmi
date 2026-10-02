import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/editors.dart';
import 'package:universal_hmi/shared/api.dart';

import 'workspace_test.dart' show FakeApi;

class InvalidPreviewApi extends FakeApi {
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/rules/preview') {
      requests.add('$method $path');
      return {
        'known': false,
        'matches': false,
        'side_effects': false,
        'error': 'action target is not writable',
      };
    }
    return super.request(method, path, body: body, query: query);
  }
}

void main() {
  testWidgets(
    'Rule preview shows validation errors without executing actions',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = InvalidPreviewApi();
      final point = api.point('p1', 'A');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => ruleEditor(context, api, [point], []),
                child: const Text('Open rule'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open rule'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('预览条件'));
      await tester.tap(find.text('预览条件'));
      await tester.pumpAndSettle();
      expect(find.text('规则无效：action target is not writable'), findsOneWidget);
      expect(find.text('输入缺失、坏质量或陈旧，条件未知'), findsNothing);
      expect(api.requests, ['POST /api/v1/rules/preview']);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('Open rule'), findsOneWidget);
    },
  );
}
