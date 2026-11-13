import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/shared/pagination.dart';

void main() {
  testWidgets('direct page selection and validated jump use row offsets', (
    t,
  ) async {
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var offset = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => PaginationBar(
              total: 650,
              offset: offset,
              pageSize: 50,
              onChanged: (v) => setState(() => offset = v),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('page-13')));
    await t.pumpAndSettle();
    expect(offset, 600);
    expect(
      t
          .widget<TextButton>(
            find.descendant(
              of: find.byTooltip('下一页'),
              matching: find.byType(TextButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await t.enterText(find.byKey(const ValueKey('page-jump')), '6');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
    expect(offset, 250);
    await t.enterText(find.byKey(const ValueKey('page-jump')), '14');
    await t.tap(find.text('跳转'));
    await t.pump();
    expect(offset, 250);
    expect(find.text('请输入 1–13'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('page-1')));
    await t.pump();
    expect(offset, 0);
    expect(find.text('请输入 1–13'), findsNothing);
  });
  for (final width in [264.0, 360.0, 390.0, 760.0, 1000.0, 1366.0]) {
    testWidgets('pagination fits width $width with scaled text', (t) async {
      t.view.physicalSize = Size(width, 600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 600),
              textScaler: const TextScaler.linear(1.3),
            ),
            child: Scaffold(
              body: PaginationBar(
                total: 650000,
                offset: 300,
                pageSize: 50,
                trailing: const Icon(Icons.download),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.ensureVisible(find.byKey(const ValueKey('page-13000')));
      expect(
        find.byKey(const ValueKey('page-13000')).hitTestable(),
        findsOneWidget,
      );
    });
  }
  testWidgets('busy, empty and bounded queries do not offer invalid pages', (
    t,
  ) async {
    var calls = 0;
    Future<void> show(int total, bool busy, {int? cap}) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PaginationBar(
            total: total,
            offset: 0,
            pageSize: 50,
            maxOffset: cap,
            busy: busy,
            onChanged: (_) => calls++,
          ),
        ),
      ),
    );
    await show(650, true);
    await t.tap(find.byKey(const ValueKey('page-13')));
    expect(calls, 0);
    await show(0, false);
    expect(
      t
          .widget<TextButton>(
            find.descendant(
              of: find.byTooltip('下一页'),
              matching: find.byType(TextButton),
            ),
          )
          .onPressed,
      isNull,
    );
    await show(650, false, cap: 200);
    expect(find.byKey(const ValueKey('page-13')), findsNothing);
    await t.tap(find.byTooltip('跳转页码'));
    await t.pumpAndSettle();
    expect(find.textContaining('最多浏览 5 页'), findsOneWidget);
  });
}
