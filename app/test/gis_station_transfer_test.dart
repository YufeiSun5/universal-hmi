import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/gis_station_transfer.dart';
import 'package:universal_hmi/features/process/gis_screen.dart';
import 'package:universal_hmi/features/process/model.dart';
import 'package:universal_hmi/platform/gis_view.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/shared/theme.dart';
import 'process_test.dart' show ScreenApi;
import 'process_transfer_export_feedback_test.dart' show ExportSelector;
import 'support/ui_lint.dart';

Json station(String name, String point) => {
  'id': 'station-stable',
  'name': name,
  'longitude': 122.9,
  'latitude': 39.7,
  'target_screen_id': '',
  'fields': [
    {'id': 'temperature', 'name': '供水温度'},
  ],
  'bindings': {'temperature': point},
  'zones': [
    {
      'id': 'zone-stable',
      'name': '一区',
      'fields': <Json>[],
      'bindings': <String, dynamic>{},
    },
  ],
};

class StationSelector extends ExportSelector {
  Uint8List bytes = GisStationFile.fromStation(
    station('文件站点', 'point'),
  ).encode(gisStationParts.keys.toSet());
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => XFile.fromData(bytes, name: 'station.json');
}

void main() {
  test(
    'partial round trip preserves identity and unselected content without aliasing',
    () {
      final original = station('原站点', 'old');
      final file = GisStationFile.decode(
        GisStationFile.fromStation(
          station('新站点', 'point'),
        ).encode({'common', 'zones'}),
      );
      final next = file.apply(original, {'common'});
      expect(next['id'], 'station-stable');
      expect(next['name'], '原站点');
      expect(next['bindings'], {'temperature': 'point'});
      next['zones'][0]['name'] = '更改';
      expect(original['zones'][0]['name'], '一区');
      expect(original['bindings'], {'temperature': 'old'});
      expect(file.pointIDs('common'), {'point'});
    },
  );
  test(
    'invalid format coordinates duplicate fields and dangling bindings rejected',
    () {
      for (final broken in [
        {
          'basic': {'name': '站', 'longitude': 181, 'latitude': 0},
        },
        {
          'common': {
            'fields': [
              {'id': 'a', 'name': 'A'},
              {'id': 'a', 'name': 'B'},
            ],
            'bindings': {},
          },
        },
        {
          'common': {
            'fields': <Json>[],
            'bindings': {'absent': 'point'},
          },
        },
        {
          'zones': [
            {'id': 'a', 'name': 'A'},
            {'id': 'a', 'name': 'B'},
          ],
        },
      ]) {
        final bytes = Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'format': 'universal-hmi-gis-station',
              'version': 1,
              'parts': broken,
            }),
          ),
        );
        expect(() => GisStationFile.decode(bytes), throwsFormatException);
      }
      expect(
        () => GisStationFile.decode(Uint8List.fromList(utf8.encode('{}'))),
        throwsFormatException,
      );
    },
  );

  for (final size in [
    const Size(1200, 900),
    const Size(640, 480),
    const Size(420, 360),
  ]) {
    testWidgets('GIS import preview cancel draft save and export at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final screenshotDir = Platform.environment['HMI_GIS_EDITOR_SCREENSHOTS'];
      final boundary = GlobalKey();
      if (screenshotDir != null) {
        await (FontLoader('HmiCJK')..addFont(
              rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
            ))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      }
      Future<void> shot(String name) async {
        if (screenshotDir == null) return;
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(screenshotDir).create(recursive: true);
          await File(
            '$screenshotDir/${size.width.toInt()}-$name.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      final selector = StationSelector();
      final previous = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = selector;
      addTearDown(() => FileSelectorPlatform.instance = previous);
      final directory = Directory.systemTemp.createTempSync('hmi-gis-test-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final destination = File('${directory.path}/station.json');
      selector.location = FileSaveLocation(destination.path);
      final api = ScreenApi();
      final source = ScreenDocument(
        id: 'gis-transfer',
        name: '地图',
        station: '',
        kind: 'gis',
        gis: {
          'stations': [station('原站点', 'point')],
        },
      ).toJson();
      api.screens['gis-transfer'] = source;
      final drafts = <String, GisDraft>{};
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            theme: workspaceTheme(),
            home: Scaffold(
              body: GisScreen(
                api: api,
                summary: source,
                editing: true,
                canWrite: true,
                drafts: drafts,
                definitions: const {
                  'point': {'name': '温度', 'station': 'IO-01'},
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> tap(String text) async {
        final target = find.text(text).last;
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      Future<void> edit() async {
        tester.widget<GisView>(find.byType(GisView)).onEditStation!(
          'station-stable',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(lintUI(tester), isEmpty);
      }

      await edit();
      await shot('basic');
      await tap('公共数据');
      expect(lintUI(tester), isEmpty);
      await shot('common');
      await tap('导入配置');
      expect(find.text('预览导入站点配置'), findsOneWidget);
      await shot('import');
      await tap('清空选择');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '替换所选内容'))
            .onPressed,
        isNull,
      );
      await tap('全选');
      await tap('替换所选内容');
      await tap('取消');
      expect(drafts['gis-transfer']!.config!['stations'][0]['name'], '原站点');
      expect(api.savedScreen, isNull);
      await edit();
      await tap('导入配置');
      await tap('替换所选内容');
      await tap('确定');
      expect(drafts['gis-transfer']!.config!['stations'][0]['name'], '文件站点');
      expect(api.savedScreen, isNull);
      await tap('保存画面');
      expect(api.savedScreen!['gis']['stations'][0]['id'], 'station-stable');
      expect(api.savedScreen!['gis']['stations'][0]['bindings'], {
        'temperature': 'point',
      });
      await edit();
      await tap('导出配置');
      await tap('导出 JSON');
      for (
        var i = 0;
        i < 100 && find.text('站点配置已导出。').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pumpAndSettle();
      }
      expect(find.text('站点配置已导出。'), findsOneWidget);
      expect(destination.existsSync(), isTrue);
      expect(
        GisStationFile.decode(
          destination.readAsBytesSync(),
        ).parts['basic']['name'],
        '文件站点',
      );
      selector.bytes = GisStationFile.fromStation(
        station('失效引用', 'missing'),
      ).encode({'common'});
      await tap('导入配置');
      expect(find.textContaining('1 个变量在当前工程不可用'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '替换所选内容'))
            .onPressed,
        isNull,
      );
      await tap('取消');
      await tap('取消');
      expect(api.savedScreen!['gis']['stations'][0]['bindings'], {
        'temperature': 'point',
      });
    });
  }
}
