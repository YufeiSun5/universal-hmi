import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/materials/detail.dart';
import 'package:universal_hmi/features/materials/session.dart';
import 'package:universal_hmi/features/materials/widgets.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'materials_test.dart' show MaterialsApi, grants, sized;

void main() {
  for (final own in [true, false]) {
    for (final request in [true, false]) {
      for (final approve in [true, false]) {
        testWidgets(
          'decision access own=$own request=$request approve=$approve',
          (t) async {
            final api = MaterialsApi();
            final session = MaterialsSession();
            addTearDown(session.dispose);
            final record = <String, dynamic>{
              'id': 'a1',
              'number': 'SQ-1',
              'owner_id': own ? 'u1' : 'other',
              'owner': '申请人',
              'status': 'pending',
              'version': 1,
              'text': '采购阀门',
            };
            api.responses['$materialsBase/applications/a1'] = {
              'application': record,
            };
            await t.pumpWidget(
              MaterialApp(
                home: MaterialDetail(
                  api: api,
                  session: session,
                  kind: 'application',
                  record: record,
                  access: {
                    'user_id': 'u1',
                    'grants': {
                      'materials_request': request,
                      'materials_approve': approve,
                    },
                  },
                ),
              ),
            );
            await t.pumpAndSettle();
            final permitted = approve && (!own || request);
            expect(
              find.text('通过申请'),
              permitted ? findsOneWidget : findsNothing,
            );
            expect(
              find.text('驳回申请'),
              permitted ? findsOneWidget : findsNothing,
            );
            if (permitted) {
              await t.tap(find.text('通过申请'));
              await t.pumpAndSettle();
              await t.tap(find.text('确认'));
              await t.pumpAndSettle();
              final post = api.calls.singleWhere((c) => c['method'] == 'POST');
              expect(post['path'], '$materialsBase/applications/a1/decision');
              expect(post['body']['version'], 1);
              expect(post['body']['decision'], 'approved');
            }
            expect(t.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final size in [const Size(1280, 900), const Size(480, 760)]) {
    testWidgets('application content and actions at $size', (t) async {
      await sized(t, size);
      final directory = Platform.environment['HMI_WIDGET_SCREENSHOTS'];
      if (directory != null) {
        await (FontLoader('HmiCJK')..addFont(
              rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
            ))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      }
      final api = MaterialsApi();
      final session = MaterialsSession();
      addTearDown(session.dispose);
      final record = <String, dynamic>{
        'id': 'app1',
        'number': 'SQ-20261116-C45591882E78',
        'owner_id': 'u1',
        'owner': 'user001',
        'status': 'pending',
        'version': 1,
        'text': '需要 DN35 管 35 根，DN50 管 50 根',
        'submitted': '2026-11-16T01:26:55Z',
      };
      api.responses['$materialsBase/applications/app1'] = {
        'application': record,
        'versions': [
          {
            'version': 1,
            'status': 'pending',
            'submitted': record['submitted'],
            'text': record['text'],
          },
        ],
      };
      final boundary = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: workspaceTheme(),
            home: Scaffold(
              backgroundColor: const Color(0xff858b90),
              body: MaterialDetail(
                api: api,
                session: session,
                kind: 'application',
                record: record,
                access: {'user_id': 'u1', 'grants': grants},
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        t
            .getSize(
              find
                  .ancestor(
                    of: find.text('通过申请'),
                    matching: find.byWidgetPredicate((w) => w is FilledButton),
                  )
                  .first,
            )
            .height,
        greaterThanOrEqualTo(44),
      );
      expect(
        t
            .getSize(
              find
                  .ancestor(
                    of: find.text('驳回申请'),
                    matching: find.byWidgetPredicate(
                      (w) => w is OutlinedButton,
                    ),
                  )
                  .first,
            )
            .height,
        greaterThanOrEqualTo(44),
      );
      expect(
        t.getSize(find.byKey(const Key('material-detail-content'))).height,
        lessThan(size.height * .85),
      );
      expect(t.takeException(), isNull);
      if (directory != null) {
        await t.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$directory/application-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      record['text'] = List.filled(30, '较长的物料申请内容，包含规格、数量与用途。').join('\n');
      await t.tap(find.byTooltip('刷新详情'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('驳回申请'));
      await t.tap(find.text('驳回申请'));
      await t.pumpAndSettle();
      await t.enterText(
        find.byKey(const Key('material-decision-reason')),
        '需要补充规格',
      );
      await t.tap(find.text('确认'));
      await t.pumpAndSettle();
      final post = api.calls.singleWhere((c) => c['method'] == 'POST');
      expect(post['body']['decision'], 'rejected');
      expect(post['body']['reason'], '需要补充规格');
      expect(t.takeException(), isNull);
    });
    testWidgets('detail values and image preview at $size', (t) async {
      await sized(t, size);
      final directory = Platform.environment['HMI_WIDGET_SCREENSHOTS'];
      if (directory != null) {
        await (FontLoader('HmiCJK')..addFont(
              rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
            ))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      }
      final api = MaterialsApi();
      final session = MaterialsSession();
      addTearDown(session.dispose);
      final record = <String, dynamic>{
        'id': 'in1',
        'number': 'RK-20261114-E2CB114FBE9F',
        'kind': 'inbound',
        'status': 'confirmed',
        'owner': '孙工',
        'created': '2026-11-14T07:13:26Z',
        'notes': '现场维修备件',
        'known_amount': '2.32',
        'missing_prices': 0,
        'asset_ids': ['receipt1', 'receipt2'],
        'lines': [
          {
            'name': '弯头',
            'specification': 'DN200',
            'category': '管件 / 弯头 / DN200',
            'quantity': '1',
            'unit': '个',
            'price': '2.32',
            'amount': '2.32',
          },
        ],
      };
      api.responses['$materialsBase/documents/in1'] = {'document': record};
      final sample = (await rootBundle.load(
        'assets/monitor/equipment.png',
      )).buffer.asUint8List();
      api.responses['$materialsBase/assets/receipt1'] = {
        'data': base64Encode(sample),
      };
      api.responses['$materialsBase/assets/receipt2'] = {
        'data': base64Encode(sample),
      };
      final boundary = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: workspaceTheme(),
            home: MaterialDetail(
              api: api,
              session: session,
              kind: 'document',
              record: record,
              access: {'user_id': 'u1', 'grants': grants},
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.runAsync(
        () => precacheImage(
          MemoryImage(sample),
          t.element(find.byType(MaterialDetail)),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('弯头 · DN200'), findsOneWidget);
      expect(find.text('1 个'), findsOneWidget);
      expect(find.text('¥2.32'), findsNWidgets(2));
      expect(find.text('已确认'), findsOneWidget);
      expect(
        t.getSize(find.byType(MaterialAssetView).first).width,
        lessThanOrEqualTo(160),
      );
      expect(t.takeException(), isNull);
      if (directory != null) {
        await t.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(directory).create(recursive: true);
          await File(
            '$directory/detail-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await t.ensureVisible(find.byType(MaterialAssetView).first);
      await t.tap(find.byType(MaterialAssetView).first);
      await t.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await t.tap(find.byTooltip('关闭图片'));
      await t.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
      // Missing prices remain unknown rather than being displayed as zero.
      record['missing_prices'] = 1;
      (record['lines'] as List).first['amount'] = '';
      await t.tap(find.byTooltip('刷新详情'));
      await t.pumpAndSettle();
      expect(find.text('未计价'), findsOneWidget);
      expect(find.text('已知金额小计'), findsOneWidget);
      expect(find.text('缺价 1 行，未计入合计'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}
