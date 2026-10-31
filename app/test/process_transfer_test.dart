import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/transfer.dart';
import 'package:universal_hmi/shared/api.dart';
import 'package:universal_hmi/platform/process_files.dart';
import 'fixtures/process_transfer_retry.dart';

class TransferTestApi implements PlatformApi, ProcessTransferApi {
  TransferTestApi({this.bindingOnly = false, this.decoded, this.previewItems});
  final bool bindingOnly;
  final Json? decoded;
  final List<Json>? previewItems;
  Json? lastPreview;
  @override
  Future<Json> request(
    String method,
    String path, {
    Object? body,
    Json? query,
  }) async {
    if (path == '/api/v1/process-transfer/catalog') {
      return {
        'screens': [
          {'id': 's1', 'name': '泵房', 'station': '站一', 'revision': 1},
        ],
        'variables': [
          {'id': 'v1', 'name': '温度', 'station': '站一', 'revision': 'abc'},
        ],
        'sources': <Json>[],
        'navigation': {'revision': 7, 'enabled': true, 'nodes': <Json>[]},
      };
    }
    if (path == '/api/v1/process-transfer/preview') {
      lastPreview = Map<String, dynamic>.from(body as Map);
      return {
        'preview_token': 't',
        'items':
            previewItems ??
            <Json>[
              {
                'kind': 'screen',
                'key': 'screenA',
                'status': 'ready',
                'before': {'id': ''},
              },
            ],
        'remaining': <Json>[],
      };
    }
    if (path == '/api/v1/process-transfer/commit') {
      return {
        'items': [
          {'kind': 'screen', 'key': 'screenA', 'status': 'saved'},
          {
            'kind': 'binding',
            'key': 'screenA/n1/point_id',
            'status': 'failed',
            'message': '未匹配',
          },
        ],
        'remaining': [
          {'kind': 'binding', 'key': 'screenA/n1/point_id', 'status': 'failed'},
        ],
        'retry_request': Map<String, dynamic>.from(body as Map),
      };
    }
    throw StateError(path);
  }

  @override
  Future<Json> decodeProcessTransfer(String name, Uint8List bytes) async =>
      decoded ??
      {
        'bundle': {
          'format': 'universal-hmi-process-bundle',
          'version': 1,
          'screens': bindingOnly
              ? <Json>[]
              : [
                  {
                    'key': 'screenA',
                    'document': {'station': 'A', 'name': '泵房画面'},
                  },
                ],
          'variables': <Json>[],
          'bindings': bindingOnly
              ? [
                  {
                    'screen_key': 'screenA',
                    'node_id': 'n1',
                    'property': 'point_id',
                    'variable_key': 'vA',
                    'operation': 'set',
                  },
                ]
              : <Json>[],
        },
      };
  @override
  Future<Uint8List> exportProcessTransfer(Json body) async => Uint8List(0);
  @override
  Future<Json> upload(String name, Uint8List bytes) async => {};
  @override
  Future<Uint8List> download(String id) async => Uint8List(0);
  @override
  void close() {}
}

void main() {
  test('synthetic retry fixture keeps independent coherent batch inputs', () {
    final first = syntheticProcessTransferRetry()['retry_request'] as Map;
    final second = syntheticProcessTransferRetry()['retry_request'] as Map;
    final bundle = first['bundle'] as Map;
    final variables = bundle['variables'] as List;
    final keys = variables.map((v) => v['key']).toSet();
    expect(keys.length, 385);
    expect(keys, isNot(contains('')));
    expect((first['variable_targets'] as Map).keys.toSet(), keys);
    final screens = (bundle['screens'] as List).map((s) => s['key']).toSet();
    expect(screens, isNotEmpty);
    expect(bundle['bindings'], isNotEmpty);
    for (final binding in bundle['bindings'] as List) {
      expect(keys, contains(binding['variable_key']));
      expect(screens, contains(binding['screen_key']));
    }
    variables.first['definition']['name'] = 'mutated';
    (first['variable_targets'] as Map).clear();
    expect((second['variable_targets'] as Map).length, 385);
    expect(
      ((second['bundle'] as Map)['variables'] as List)
          .first['definition']['name'],
      '模拟变量0',
    );
  });

  testWidgets('批量更新使用导入身份而不猜画面名称', (tester) async {
    final api = TransferTestApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: api,
            pickFile: () async => ProcessFile('screens.json', Uint8List(0)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('批量更新同一导入身份的画面'));
    await tester.tap(find.text('批量更新同一导入身份的画面'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(api.lastPreview!['screen_targets'], {
      'screenA': {'mode': 'update_imported'},
    });
    expect(api.lastPreview!['import_identity'], 'process-transfer-v1');
  });
  testWidgets('菜单默认跳过，替换须确认并携带版本，新文件重置选择', (tester) async {
    final api = TransferTestApi(
      decoded: {
        'bundle': {
          'screens': <Json>[],
          'variables': <Json>[],
          'bindings': <Json>[],
          'navigation': {
            'enabled': true,
            'nodes': [
              {
                'id': 'g',
                'label': '区域',
                'children': [
                  {'id': 'n', 'label': '泵房', 'screen_key': 'screenA'},
                ],
              },
            ],
          },
        },
      },
      previewItems: [
        {
          'kind': 'navigation',
          'key': 'page_navigation',
          'status': 'error',
          'message': '版本冲突',
          'before': {
            'revision': 7,
            'enabled': true,
            'nodes': [
              {'id': 'old', 'label': '旧菜单'},
            ],
          },
          'after': {
            'enabled': true,
            'nodes': [
              {'id': 'g', 'label': '区域'},
            ],
          },
        },
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: api,
            pickFile: () async => ProcessFile('nav.json', Uint8List(0)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(api.lastPreview!['navigation_target'], {'mode': 'skip'});
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建菜单'));
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(api.lastPreview!['navigation_target'], {
      'mode': 'create',
      'revision': 7,
    });
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳过菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('替换现有菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(api.lastPreview!['navigation_target'], {'mode': 'skip'});
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('替换现有菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认替换菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(api.lastPreview!['navigation_target'], {
      'mode': 'replace',
      'revision': 7,
    });
    expect(find.textContaining('客户端菜单 · 页面导航 · 冲突'), findsOneWidget);
    await tester.tap(find.textContaining('客户端菜单 · 页面导航 · 冲突'));
    await tester.pumpAndSettle();
    expect(find.textContaining('旧菜单'), findsOneWidget);
    expect(find.textContaining('区域'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认保存'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(api.lastPreview!['navigation_target'], {'mode': 'skip'});
  });
  testWidgets('普通变量包可明确批量新建', (tester) async {
    final retry = syntheticProcessTransferRetry();
    final bundle = Map<String, dynamic>.from(
      (retry['retry_request'] as Map)['bundle'] as Map,
    );
    bundle['screens'] = <Json>[];
    bundle['bindings'] = <Json>[];
    final api = TransferTestApi(decoded: {'bundle': bundle});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: api,
            pickFile: () async => ProcessFile('variables.json', Uint8List(0)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('批量新建变量（不自动应用运行配置）'));
    await tester.tap(find.text('批量新建变量（不自动应用运行配置）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    final targets = api.lastPreview!['variable_targets'] as Map;
    expect(targets.length, 385);
    expect(targets.values.every((v) => v['mode'] == 'create'), isTrue);
  });
  testWidgets('剩余清单保留原导入身份和已有画面目标并可批量匹配', (tester) async {
    final retry = syntheticProcessTransferRetry();
    final request = retry['retry_request'] as Map<String, dynamic>;
    final bundle = Map<String, dynamic>.from(request['bundle'] as Map);
    bundle['screens'] = <Json>[];
    request['bundle'] = bundle;
    request['import_identity'] = 'original-custom-identity';
    request['screen_targets'] = {
      'existing': {'mode': 'update', 'id': 'existing-id', 'revision': 3},
    };
    final api = TransferTestApi(
      decoded: {'bundle': bundle, 'retry_request': request},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: api,
            pickFile: () async => ProcessFile('remaining.json', Uint8List(0)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, '创建另一组新副本（再次导入同一文件时使用）'),
          )
          .value,
      isFalse,
    );
    await tester.ensureVisible(find.text('批量匹配已有变量（保留已有配置和归属）'));
    await tester.tap(find.text('批量匹配已有变量（保留已有配置和归属）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(api.lastPreview!['import_identity'], 'original-custom-identity');
    expect((api.lastPreview!['variable_targets'] as Map).length, 385);
    expect(api.lastPreview!['screen_targets'], {
      'existing': {'mode': 'update', 'id': 'existing-id', 'revision': 3},
    });
    expect(
      (api.lastPreview!['variable_targets'] as Map).values.every(
        (v) => v['mode'] == 'match_existing',
      ),
      isTrue,
    );
  });
  testWidgets('批量匹配只引用已有变量并展示匹配和歧义', (tester) async {
    final retry = syntheticProcessTransferRetry();
    final request = retry['retry_request'] as Map<String, dynamic>;
    final variables = (request['bundle'] as Map)['variables'] as List;
    final firstKey = variables[0]['key'];
    final secondKey = variables[1]['key'];
    final api = TransferTestApi(
      decoded: {'bundle': request['bundle'], 'retry_request': request},
      previewItems: [
        {
          'kind': 'variable',
          'key': firstKey,
          'status': 'unchanged',
          'after': {
            'name': '已有温度',
            'station': '原站',
            'topic': '实际主题',
            'data_type': 'FLOAT',
          },
        },
        {
          'kind': 'variable',
          'key': secondKey,
          'status': 'unresolved',
          'message': '多个候选',
          'candidates': [
            {
              'definition': {
                'name': '候选点',
                'station': '另一站',
                'scale_factor': 2,
                'offset': 3,
              },
              'compatible': true,
              'conflicts': ['scale_factor'],
              'differences': ['offset'],
            },
          ],
        },
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: api,
            pickFile: () async =>
                ProcessFile('import-request.json', Uint8List(0)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('批量匹配已有变量（保留已有配置和归属）'));
    await tester.tap(find.text('批量匹配已有变量（保留已有配置和归属）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    final targets = api.lastPreview!['variable_targets'] as Map;
    expect(targets.length, 385);
    expect(targets.values.every((v) => v['mode'] == 'match_existing'), isTrue);
    expect(find.textContaining('变量已匹配 1 项 · 变量需处理 1 项'), findsOneWidget);
    await tester.tap(find.textContaining('复用 / 无变化').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('目标变量：名称：已有温度'), findsOneWidget);
    await tester.tap(find.textContaining('未匹配').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('候选点'), findsOneWidget);
    expect(find.textContaining('倍率：2 · 偏移：3'), findsOneWidget);
    expect(find.textContaining('差异：偏移 · 冲突：倍率'), findsOneWidget);
  });
  testWidgets('模拟重试请求恢复新建目标，切换变量定义保留目标', (tester) async {
    final retry = syntheticProcessTransferRetry();
    final request = retry['retry_request'] as Map<String, dynamic>;
    final api = TransferTestApi(
      decoded: {'bundle': request['bundle'], 'retry_request': request},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: api,
            pickFile: () async =>
                ProcessFile('import-request.json', Uint8List(0)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    final checkbox = find.widgetWithText(CheckboxListTile, '变量定义');
    expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
    await tester.tap(find.text('变量定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(api.lastPreview!['variable_targets'], isEmpty);
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('变量定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect((api.lastPreview!['variable_targets'] as Map).length, 385);
    expect(api.lastPreview!['variable_targets'], request['variable_targets']);
    expect(
      (api.lastPreview!['variable_targets'] as Map).values.every(
        (v) => v['mode'] == 'create',
      ),
      isTrue,
    );
  });
  testWidgets('批量站名及稳定新建目标随预览提交', (tester) async {
    final api = TransferTestApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: api,
            stations: const ['站一'],
            pickFile: () async => ProcessFile('a.json', Uint8List(0)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按文件站名批量映射，不存在时创建站点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(find.text('画面 · 泵房画面 · screenA · 新增'), findsOneWidget);
    expect(api.lastPreview!['station_map'], {'A': 'A'});
    expect(api.lastPreview!['create_stations'], ['A']);
    expect(api.lastPreview!['import_identity'], 'process-transfer-v1');
    expect(api.lastPreview!['screen_targets'], {
      'screenA': {'mode': 'create'},
    });
  });
  testWidgets('仅绑定导入映射已有画面和变量', (tester) async {
    final api = TransferTestApi(bindingOnly: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: api,
            pickFile: () async => ProcessFile('b.csv', Uint8List(0)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(DropdownButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('泵房 · 站一').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('变量：vA'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(DropdownButton<String>).at(3));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>).at(3));
    await tester.pumpAndSettle();
    await tester.tap(find.text('温度 · 站一').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(api.lastPreview!['screen_targets'], {
      'screenA': {'mode': 'update', 'id': 's1', 'revision': 1},
    });
    expect(api.lastPreview!['variable_targets'], {
      'vA': {'mode': 'reference', 'id': 'v1', 'revision': 'abc'},
    });
    expect((api.lastPreview!['bundle'] as Map)['screens'], isEmpty);
  });
  testWidgets('重新选择文件清除旧映射', (tester) async {
    final api = TransferTestApi(bindingOnly: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: api,
            pickFile: () async => ProcessFile('b.csv', Uint8List(0)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(DropdownButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('泵房 · 站一').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(api.lastPreview!['screen_targets'], isEmpty);
  });
  testWidgets('预览退回后需重新预览且部分失败单独显示', (tester) async {
    final api = TransferTestApi();
    var refreshCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: api,
            onCommitted: () => refreshCount++,
            stations: const ['站一'],
            pickFile: () async => ProcessFile('a.json', Uint8List(0)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按文件站名批量映射，不存在时创建站点'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    expect(find.text('确认保存'), findsOneWidget);
    await tester.tap(find.text('上一步'));
    await tester.pumpAndSettle();
    expect(find.text('确认保存'), findsNothing);
    await tester.tap(find.text('预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已保存'), findsOneWidget);
    expect(find.textContaining('失败'), findsOneWidget);
    expect(find.text('剩余 1 项'), findsOneWidget);
    expect(refreshCount, 1);
  });
  testWidgets('五千变量在窄窗分页呈现', (tester) async {
    tester.view.physicalSize = const Size(800, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final vars = List<Json>.generate(
      5000,
      (i) => {'id': 'v$i', 'name': '变量$i', 'station': '站'},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(api: TransferTestApi(), variables: vars),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出').first);
    await tester.pumpAndSettle();
    expect(
      find.byType(CheckboxListTile).evaluate().length,
      lessThanOrEqualTo(52),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('工艺导出选择显示画面且限制 CSV 内容', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessTransferDialog(
            api: TransferTestApi(),
            variables: const [
              {'id': 'v1', 'name': '温度', 'station': '站一'},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('泵房'), findsOneWidget);
    expect(find.text('CSV 仅支持变量或绑定；画面布局和图片使用 JSON 或 XLSX。'), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    expect(
      tester
          .widget<CheckboxListTile>(find.byType(CheckboxListTile).first)
          .value,
      isTrue,
    );
  });
}
