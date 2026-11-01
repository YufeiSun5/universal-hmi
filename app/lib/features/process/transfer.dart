import 'dart:convert';
import 'package:flutter/material.dart';
import '../../platform/process_files.dart';
import '../../platform/save.dart';
import '../../shared/api.dart';
import 'model.dart';
import 'diagram.dart';

Future<void> showProcessTransfer(
  BuildContext context,
  PlatformApi api, {
  String station = '',
  List<String> stations = const [],
  List<Json> variables = const [],
  VoidCallback? onCommitted,
}) => showDialog<void>(
  context: context,
  builder: (_) => ProcessTransferDialog(
    api: api,
    station: station,
    stations: stations,
    variables: variables,
    onCommitted: onCommitted,
  ),
);

class ProcessTransferDialog extends StatefulWidget {
  const ProcessTransferDialog({
    super.key,
    required this.api,
    this.station = '',
    this.stations = const [],
    this.variables = const [],
    this.pickFile,
    this.onCommitted,
  });
  final Future<ProcessFile?> Function()? pickFile;
  final VoidCallback? onCommitted;
  final PlatformApi api;
  final String station;
  final List<String> stations;
  final List<Json> variables;
  @override
  State<ProcessTransferDialog> createState() => _ProcessTransferDialogState();
}

class _ProcessTransferDialogState extends State<ProcessTransferDialog> {
  bool exporting = false,
      busy = false,
      createStations = false,
      expandShared = false;
  bool includeScreens = true, includeVariables = false, includeBindings = true;
  int step = 0;
  String kind = 'bundle', format = 'json', error = '', filter = '';
  int page = 0, screenPage = 0;
  String screenFilter = '';
  String importIdentity = 'process-transfer-v1';
  String originalImportIdentity = 'process-transfer-v1';
  bool newCopy = false;
  String navigationMode = 'skip';
  Json? currentNavigation;
  Json? bundle, preview, result;
  List<Json> screens = [];
  final selectedScreens = <String>{}, selectedVariables = <String>{};
  final stationMap = <String, String>{}, sourceMap = <String, String>{};
  final screenTargets = <String, Json>{}, variableTargets = <String, Json>{};
  List<Json> sources = [], catalogVariables = [];
  @override
  void initState() {
    super.initState();
    loadCatalog();
  }

  Future<void> loadCatalog() async {
    try {
      final values = await widget.api.request(
        'GET',
        '/api/v1/process-transfer/catalog',
      );
      if (mounted) {
        setState(() {
          screens = objects(values['screens']);
          sources = objects(values['sources']);
          catalogVariables = objects(values['variables']);
          currentNavigation = values['navigation'] is Map
              ? Map<String, dynamic>.from(values['navigation'] as Map)
              : null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '目录读取失败：$e');
    }
  }

  List<Json> entries(String name) => objects(bundle?[name]);
  String keyOf(Json entry) => entry['key']?.toString() ?? '';
  String entryName(Json entry, bool screen) {
    final data = entry[screen ? 'document' : 'definition'];
    return data is Map ? (data['name']?.toString() ?? '') : '';
  }

  List<Json> screenEntries() {
    final found = {for (final e in entries('screens')) keyOf(e): e};
    for (final b in entries('bindings')) {
      final key = b['screen_key']?.toString() ?? '';
      if (key.isNotEmpty) found.putIfAbsent(key, () => {'key': key});
    }
    return found.values.toList();
  }

  List<Json> variableEntries() {
    final found = {for (final e in entries('variables')) keyOf(e): e};
    for (final b in entries('bindings')) {
      final key = b['variable_key']?.toString() ?? '';
      if (key.isNotEmpty) found.putIfAbsent(key, () => {'key': key});
    }
    return found.values.toList();
  }

  Json get request => {
    'import_identity': importIdentity,
    'bundle': {
      ...?bundle,
      'screens': includeScreens ? entries('screens') : <Json>[],
      'variables': (includeVariables || includeBindings)
          ? entries('variables')
          : <Json>[],
      'bindings': includeBindings ? entries('bindings') : <Json>[],
    },
    'screen_targets': {
      if (includeScreens)
        for (final entry in entries('screens'))
          keyOf(entry): screenTargets[keyOf(entry)] ?? {'mode': 'create'},
      ...screenTargets,
    },
    'variable_targets': {
      for (final entry in variableTargets.entries)
        if (includeVariables ||
            entry.value['mode'] == 'reference' ||
            entry.value['mode'] == 'match_existing')
          entry.key: entry.value,
    },
    'station_map': stationMap,
    'create_stations': createStations
        ? stationMap.values
              .where((v) => v.isNotEmpty && !widget.stations.contains(v))
              .toSet()
              .toList()
        : <String>[],
    'source_map': sourceMap,
    if (bundle?['navigation'] is Map)
      'navigation_target': {
        'mode': navigationMode,
        if (navigationMode != 'skip')
          'revision': currentNavigation?['revision'],
      },
  };
  Future<void> choose() async {
    if (widget.api is! ProcessTransferApi) {
      setState(() => error = '当前连接不支持工艺资料传输');
      return;
    }
    try {
      final file = await (widget.pickFile ?? pickProcessTransferFile)();
      if (file == null) return;
      setState(() {
        busy = true;
        error = '';
      });
      final data = await (widget.api as ProcessTransferApi)
          .decodeProcessTransfer(file.name, file.bytes);
      if (!mounted) return;
      setState(() {
        bundle = Map<String, dynamic>.from(data['bundle'] as Map);
        preview = null;
        result = null;
        createStations = false;
        importIdentity = 'process-transfer-v1';
        originalImportIdentity = importIdentity;
        newCopy = false;
        navigationMode = 'skip';
        stationMap.clear();
        sourceMap.clear();
        screenTargets.clear();
        variableTargets.clear();
        includeScreens = true;
        includeVariables =
            entries('screens').isEmpty && entries('bindings').isEmpty;
        includeBindings = true;
        final retry = data['retry_request'];
        if (retry is Map) {
          final retryTargets = retry['variable_targets'] as Map? ?? {};
          if (retryTargets.values.any(
            (v) => v is Map && (v['mode'] == 'create' || v['mode'] == 'update'),
          )) {
            includeVariables = true;
          }
          importIdentity =
              retry['import_identity']?.toString() ?? 'process-transfer-v1';
          originalImportIdentity = importIdentity;
          createStations = (retry['create_stations'] as List? ?? []).isNotEmpty;
          stationMap.addAll(
            Map<String, String>.from(retry['station_map'] ?? {}),
          );
          sourceMap.addAll(Map<String, String>.from(retry['source_map'] ?? {}));
          screenTargets.addAll(
            (retry['screen_targets'] as Map? ?? {}).map(
              (k, v) =>
                  MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)),
            ),
          );
          variableTargets.addAll(
            (retry['variable_targets'] as Map? ?? {}).map(
              (k, v) =>
                  MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)),
            ),
          );
        }
        filter = '';
        page = 0;
        screenPage = 0;
        screenFilter = '';
        step = 1;
      });
    } catch (e) {
      if (mounted) setState(() => error = '解析失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> inspect() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final data = await widget.api.request(
        'POST',
        '/api/v1/process-transfer/preview',
        body: request,
      );
      if (mounted) {
        setState(() {
          preview = data;
          step = 2;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '预览失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> selectNavigationMode(String mode) async {
    if (mode != 'skip' && currentNavigation?['revision'] is! int) {
      setState(() => error = '无法读取当前菜单版本，请关闭后重试。');
      return;
    }
    if (mode == 'replace') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('替换现有客户端菜单？'),
          content: const Text('替换会改变现有菜单结构。系统将按当前版本检查冲突；画面本身不会删除。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认替换菜单'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      navigationMode = mode;
      error = '';
    });
  }

  Future<void> commit() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final data = await widget.api.request(
        'POST',
        '/api/v1/process-transfer/commit',
        body: {...request, 'preview_token': preview?['preview_token']},
      );
      if (mounted) {
        setState(() {
          result = data;
          step = 3;
        });
        if (objects(data['items']).any((item) => item['status'] == 'saved')) {
          widget.onCommitted?.call();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          preview = null;
          step = 1;
          error = '未能确认提交结果：$e。请重新预览并核对实际变更后保存；不会自动重试。';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export() async {
    if (widget.api is! ProcessTransferApi) {
      setState(() => error = '当前连接不支持工艺资料传输');
      return;
    }
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final bytes = await (widget.api as ProcessTransferApi)
          .exportProcessTransfer({
            'screen_ids': selectedScreens.toList(),
            'variable_ids': selectedVariables.toList(),
            'format': format,
            'kind': kind,
            'expand_shared': expandShared,
          });
      await saveFile(bytes, 'process-$kind.$format');
    } catch (e) {
      if (mounted) setState(() => error = '导出失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> saveRemaining() async {
    final retry = result?['retry_request'] ?? preview?['retry_request'];
    if (retry == null) {
      if (mounted) setState(() => error = '服务器未提供可重试的剩余清单');
      return;
    }
    await saveFile(
      utf8.encode(
        const JsonEncoder.withIndent('  ').convert({'retry_request': retry}),
      ),
      'process-transfer-remaining.json',
    );
  }

  Widget select(
    String label,
    String value,
    List<String> options,
    ValueChanged<String> changed, {
    Map<String, String> labels = const {},
  }) => Row(
    children: [
      SizedBox(width: 110, child: Text(label)),
      Expanded(
        child: DropdownButton<String>(
          isExpanded: true,
          value: options.contains(value) ? value : options.first,
          items: [
            for (final option in options)
              DropdownMenuItem(
                value: option,
                child: Text(
                  option.isEmpty ? '未选择' : (labels[option] ?? option),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: busy ? null : (v) => setState(() => changed(v ?? '')),
        ),
      ),
    ],
  );
  Widget target(Json entry, bool screen) {
    final key = keyOf(entry),
        targets = screen ? screenTargets : variableTargets;
    final target =
        targets[key] ??
        {
          'mode': screen
              ? (includeScreens &&
                        entries('screens').any((e) => keyOf(e) == key)
                    ? 'create'
                    : 'update')
              : (entries('variables').any((e) => keyOf(e) == key)
                    ? 'auto'
                    : 'reference'),
        };
    final available = screen ? screens : catalogVariables;
    final storedMode = target['mode']?.toString() ?? 'create';
    final mode =
        !screen &&
            !includeVariables &&
            (storedMode == 'create' || storedMode == 'update')
        ? 'auto'
        : storedMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${screen ? '画面' : '变量'}：${entryName(entry, screen).isEmpty ? key : '${entryName(entry, screen)} · $key'}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        select(
          '处理方式',
          mode,
          [
            '',
            if (screen ? includeScreens : includeVariables) 'create',
            if (screen && includeScreens) 'update_imported',
            if (screen || includeVariables) 'update',
            if (!screen) 'reference',
            if (!screen && entries('variables').any((e) => keyOf(e) == key))
              'match_existing',
            if (!screen && entries('variables').any((e) => keyOf(e) == key))
              'auto',
          ],
          (v) {
            if (v == 'auto' || v.isEmpty) {
              targets.remove(key);
            } else {
              targets[key] = {'mode': v};
            }
          },
          labels: {
            'create': '新建副本',
            'update': screen && !includeScreens ? '绑定到已有画面' : '更新已有',
            'update_imported': '更新同一导入身份的画面',
            'reference': '引用已有',
            'auto': '按完整来源身份自动匹配',
            'match_existing': '匹配已有变量',
          },
        ),
        if (mode == 'update' || mode == 'reference')
          select(
            '目标',
            target['id']?.toString() ?? '',
            ['', ...available.map((v) => v['id'].toString())],
            (v) {
              final item = available
                  .where((e) => e['id'].toString() == v)
                  .firstOrNull;
              targets[key] = {
                'mode': mode,
                'id': v,
                if (item?['revision'] != null) 'revision': item!['revision'],
              };
            },
            labels: {
              for (final item in available)
                item['id'].toString():
                    '${item['name'] ?? item['id']} · ${item['station'] ?? '公共'}',
            },
          ),
        const Divider(height: 12),
      ],
    );
  }

  Widget mapping() {
    final stationAliases = <String>{}, sourceAliases = <String>{};
    for (final item in entries('screens')) {
      final doc = item['document'];
      if (doc is Map) {
        stationAliases.add(doc['station']?.toString() ?? '');
      }
    }
    for (final item in entries('variables')) {
      final d = item['definition'];
      if (d is Map) {
        if ('${d['station'] ?? ''}'.isNotEmpty) {
          stationAliases.add('${d['station']}');
        }
        if ('${d['source_id'] ?? ''}'.isNotEmpty) {
          sourceAliases.add('${d['source_id']}');
        }
        if ('${d['write_source_id'] ?? ''}'.isNotEmpty) {
          sourceAliases.add('${d['write_source_id']}');
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('选择导入内容及目标；空白保留已有值，清除须在文件中显式指定。保存变量不会自动应用运行配置。'),
        if (bundle?['navigation'] is Map) ...[
          const Text('客户端父子菜单：菜单只组织画面入口，不改变站点归属。默认跳过；替换需要明确确认。'),
          Wrap(
            spacing: 8,
            children: [
              for (final option in const {
                'skip': '跳过菜单',
                'create': '创建菜单',
                'replace': '替换现有菜单',
              }.entries)
                ChoiceChip(
                  label: Text(option.value),
                  selected: navigationMode == option.key,
                  onSelected: busy
                      ? null
                      : (_) => selectNavigationMode(option.key),
                ),
            ],
          ),
          Text('当前菜单版本：${currentNavigation?['revision'] ?? '未读取'}'),
        ],
        CheckboxListTile(
          dense: true,
          title: const Text('创建另一组新副本（再次导入同一文件时使用）'),
          value: newCopy,
          onChanged: (v) => setState(() {
            newCopy = v == true;
            importIdentity = newCopy
                ? screenIdentity()
                : originalImportIdentity;
          }),
        ),
        CheckboxListTile(
          dense: true,
          title: const Text('画面布局及素材'),
          value: includeScreens,
          onChanged: (v) => setState(() {
            includeScreens = v == true;
            screenTargets.clear();
          }),
        ),
        CheckboxListTile(
          dense: true,
          title: const Text('变量定义'),
          value: includeVariables,
          onChanged: (v) => setState(() {
            includeVariables = v == true;
          }),
        ),
        CheckboxListTile(
          dense: true,
          title: const Text('变量绑定'),
          value: includeBindings,
          onChanged: (v) => setState(() => includeBindings = v == true),
        ),
        CheckboxListTile(
          dense: true,
          title: const Text('按文件站名批量映射，不存在时创建站点'),
          value: createStations,
          onChanged: (v) => setState(() {
            createStations = v == true;
            if (createStations) {
              for (final alias in stationAliases) {
                stationMap[alias] = alias;
              }
            }
          }),
        ),
        for (final alias in stationAliases)
          select(
            alias.isEmpty ? '公共范围' : '站点 $alias',
            stationMap.containsKey(alias)
                ? (stationMap[alias]!.isEmpty
                      ? '__public__'
                      : stationMap[alias]!)
                : '',
            [
              '',
              '__public__',
              ...widget.stations.where((s) => s.isNotEmpty),
              if (createStations &&
                  alias.isNotEmpty &&
                  !widget.stations.contains(alias))
                alias,
            ],
            (v) {
              if (v.isEmpty) {
                stationMap.remove(alias);
              } else {
                stationMap[alias] = v == '__public__' ? '' : v;
              }
            },
            labels: const {'__public__': '公共画面'},
          ),
        for (final alias in sourceAliases)
          select(
            '来源 $alias',
            sourceMap[alias] ?? '',
            ['', ...sources.map((s) => s['id'].toString())],
            (v) {
              if (v.isEmpty) {
                sourceMap.remove(alias);
              } else {
                sourceMap[alias] = v;
              }
            },
            labels: {
              for (final source in sources)
                source['id'].toString(): (source['name'] ?? source['id'])
                    .toString(),
            },
          ),
        if (entries('variables').isNotEmpty)
          TextButton.icon(
            onPressed: busy
                ? null
                : () => setState(() {
                    for (final variable in entries('variables')) {
                      variableTargets[keyOf(variable)] = {
                        'mode': 'match_existing',
                      };
                    }
                  }),
            icon: const Icon(Icons.link),
            label: const Text('批量匹配已有变量（保留已有配置和归属）'),
          ),
        if (entries('variables').isNotEmpty && includeVariables)
          TextButton.icon(
            onPressed: busy
                ? null
                : () => setState(() {
                    for (final variable in entries('variables')) {
                      variableTargets[keyOf(variable)] = {'mode': 'create'};
                    }
                  }),
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('批量新建变量（不自动应用运行配置）'),
          ),
        if (includeScreens || includeBindings) ...[
          if (includeScreens && entries('screens').isNotEmpty)
            TextButton.icon(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      for (final entry in entries('screens')) {
                        screenTargets[keyOf(entry)] = {
                          'mode': 'update_imported',
                        };
                      }
                    }),
              icon: const Icon(Icons.find_replace),
              label: const Text('批量更新同一导入身份的画面'),
            ),
          if (includeScreens && entries('screens').isNotEmpty)
            const Text('按文件导入身份、画面键和目标站精确查找；找不到会报冲突，不按名称匹配或新建。请在预览中核对画面变更。'),
          TextField(
            decoration: const InputDecoration(labelText: '搜索导入画面'),
            onChanged: (v) => setState(() {
              screenFilter = v.trim().toLowerCase();
              screenPage = 0;
            }),
          ),
          for (final entry
              in screenEntries()
                  .where(
                    (e) => '${entryName(e, true)} ${keyOf(e)}'
                        .toLowerCase()
                        .contains(screenFilter),
                  )
                  .skip(screenPage * 20)
                  .take(20))
            target(entry, true),
          Row(
            children: [
              TextButton(
                onPressed: screenPage > 0
                    ? () => setState(() => screenPage--)
                    : null,
                child: const Text('画面上一页'),
              ),
              Text('第 ${screenPage + 1} 页'),
              TextButton(
                onPressed:
                    screenEntries()
                            .where(
                              (e) => '${entryName(e, true)} ${keyOf(e)}'
                                  .toLowerCase()
                                  .contains(screenFilter),
                            )
                            .length >
                        (screenPage + 1) * 20
                    ? () => setState(() => screenPage++)
                    : null,
                child: const Text('画面下一页'),
              ),
            ],
          ),
        ],
        if (includeVariables || includeBindings) ...[
          TextField(
            decoration: const InputDecoration(labelText: '搜索导入变量'),
            onChanged: (v) => setState(() {
              filter = v;
              page = 0;
            }),
          ),
          for (final entry
              in variableEntries()
                  .where((e) => keyOf(e).contains(filter))
                  .skip(page * 50)
                  .take(50))
            target(entry, false),
          Row(
            children: [
              TextButton(
                onPressed: page > 0 ? () => setState(() => page--) : null,
                child: const Text('上一页'),
              ),
              Text('第 ${page + 1} 页'),
              TextButton(
                onPressed:
                    variableEntries()
                            .where((e) => keyOf(e).contains(filter))
                            .length >
                        (page + 1) * 50
                    ? () => setState(() => page++)
                    : null,
                child: const Text('下一页'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> locate(Json item) async {
    try {
      final key = item['key']?.toString() ?? '';
      final binding = entries('bindings')
          .where(
            (b) =>
                [b['screen_key'], b['node_id'], b['property']].join('/') == key,
          )
          .firstOrNull;
      if (binding == null) throw const FormatException('未找到绑定位置');
      final screenKey = binding['screen_key'].toString();
      final entry = entries(
        'screens',
      ).where((s) => keyOf(s) == screenKey).firstOrNull;
      Json raw;
      if (entry?['document'] is Map) {
        raw = Map<String, dynamic>.from(entry!['document'] as Map);
      } else {
        final id = screenTargets[screenKey]?['id']?.toString() ?? '';
        if (id.isEmpty) throw const FormatException('请先选择目标画面');
        raw = await widget.api.request('GET', '/api/v1/screens/$id');
      }
      final document = ScreenDocument.fromJson(raw);
      final node = document.nodes
          .where((n) => n.id == binding['node_id'])
          .firstOrNull;
      if (node == null) throw const FormatException('目标画面没有此节点');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('绑定位置 · ${document.name}'),
          content: SizedBox(
            width: 600,
            height: 360,
            child: LayoutBuilder(
              builder: (_, box) {
                final scale =
                    (box.maxWidth / document.width <
                        box.maxHeight / document.height)
                    ? box.maxWidth / document.width
                    : box.maxHeight / document.height;
                final width = document.width * scale,
                    height = document.height * scale;
                return Center(
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ProcessDiagram(
                            document: document,
                            definitions: const {},
                            live: const {},
                            online: false,
                          ),
                        ),
                        Positioned(
                          left: node.x * scale,
                          top: node.y * scale,
                          width: node.width * scale,
                          height: node.height * scale,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.red, width: 3),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '无法定位：$e');
    }
  }

  String itemKind(dynamic value) => switch ('$value') {
    'screen' => '画面',
    'variable' => '变量',
    'binding' => '绑定',
    'station' => '站点',
    'navigation' => '客户端菜单',
    _ => '$value',
  };
  String status(dynamic value) => switch ('$value') {
    'ready' => '可保存',
    'unchanged' => '复用 / 无变化',
    'error' => '冲突',
    'unresolved' => '未匹配',
    'saved' => '已保存',
    'failed' => '失败',
    'skipped' => '已跳过',
    _ => '$value',
  };
  String message(dynamic value) {
    final raw = value?.toString() ?? '';
    if (raw.isEmpty) return '';
    final explanation = switch (raw) {
      'source mapping required' => '请选择目标数据来源',
      'navigation revision conflict' => '菜单已被其他操作修改，请重新打开导入并再次预览',
      'existing navigation requires explicit replace' => '已有菜单，请明确选择替换现有菜单',
      'navigation explicitly skipped' => '已选择保留现有菜单',
      'identical navigation' => '菜单内容相同，无需更改',
      'navigation screen permission denied' => '没有菜单目标画面的访问权限',
      'navigation service unavailable' => '菜单服务不可用',
      'import identity or exact imported target required' => '需要原导入身份及明确目标站',
      'exact imported screen missing; no automatic create' =>
        '未找到该导入身份的画面，未自动新建',
      'imported screen station or kind conflict' => '既有画面的站点或类型与文件不一致',
      'navigation leaf cannot have children' => '画面菜单项不能包含子菜单',
      _ when raw.startsWith('navigation screen key ') => '菜单所引用的画面未准备好，请检查画面目标',
      'station mapping required' => '请选择目标站点',
      'target station missing; explicitly create station' => '目标站点不存在，请明确选择创建',
      'reference not accessible' => '引用的变量不存在或无权访问',
      'source target not found' => '目标来源不存在',
      'data type/source type is not confirmed' => '变量类型或来源类型未确认',
      'unique existing source path reference; configuration preserved' =>
        '已匹配已有变量，保留其配置和归属',
      'match_existing requires confirmed mqtt source path and data type' =>
        '匹配已有变量需要确认 MQTT 来源路径和数据类型',
      'cannot resolve accessible unique match' => '无法确定唯一的可访问变量',
      'match_existing requires one exact source path candidate' =>
        '来源路径没有唯一候选，请检查来源及路径',
      'existing variable metadata conflicts with explicit definition' =>
        '已有变量的类型、单位或换算参数与文件冲突',
      _
          when raw.startsWith(
            'explicit create/update/reference target required',
          ) =>
        '未找到唯一匹配变量，请选择匹配已有变量或明确指定目标',
      _ => '',
    };
    return explanation.isEmpty ? raw : '$explanation（原始信息：$raw）';
  }

  String metadata(dynamic value) {
    if (value is! Map) return summary(value);
    return [
          'name',
          'station',
          'source_id',
          'source_path',
          'topic',
          'data_type',
          'unit',
          'scale_factor',
          'offset',
        ]
        .where((key) => value[key] != null && '${value[key]}'.isNotEmpty)
        .map(
          (key) =>
              '${{'name': '名称', 'station': '站点', 'source_id': '来源', 'source_path': '路径', 'topic': '主题', 'data_type': '类型', 'unit': '单位', 'scale_factor': '倍率', 'offset': '偏移'}[key]}：${value[key]}',
        )
        .join(' · ');
  }

  String fieldNames(dynamic value) {
    if (value is! List || value.isEmpty) return '无';
    const names = {
      'data_type': '类型',
      'unit': '单位',
      'station': '站点',
      'topic': '主题',
      'scale_factor': '倍率',
      'offset': '偏移',
      'scale_factor_unspecified': '文件未指定倍率',
      'offset_unspecified': '文件未指定偏移',
    };
    return value.map((v) => names[v] ?? '$v').join('、');
  }

  String summary(dynamic value) {
    if (value == null) return '无';
    if (value is Map) {
      final copy = Map<String, dynamic>.from(value);
      copy.remove('nodes');
      copy.remove('assets');
      copy.remove('background');
      return jsonEncode(copy);
    }
    return value.toString();
  }

  String navigationSummary(dynamic value) {
    if (value is! Map) return '无';
    final lines = <String>[];
    void walk(dynamic raw, int depth) {
      if (raw is! List) return;
      for (final node in raw) {
        if (node is! Map) continue;
        final target = node['screen_id'] ?? node['screen_key'];
        lines.add(
          '${'  ' * depth}${node['label'] ?? ''}${target == null || '$target'.isEmpty ? '' : ' → $target'}',
        );
        walk(node['children'], depth + 1);
      }
    }

    walk(value['nodes'], 0);
    return '版本 ${value['revision'] ?? '新菜单'} · ${value['enabled'] == true ? '启用' : '停用'}\n${lines.isEmpty ? '空菜单' : lines.join('\n')}';
  }

  String itemStatus(Json item) {
    if (item['status'] == 'ready' &&
        (item['kind'] == 'screen' ||
            item['kind'] == 'variable' ||
            item['kind'] == 'station')) {
      final before = item['before'];
      final absent =
          before == null ||
          (before is Map &&
              (before['id'] == null || '${before['id']}'.isEmpty));
      return absent ? '新增' : '修改';
    }
    return status(item['status']);
  }

  String itemName(Json item) {
    final kind = item['kind'];
    if (kind == 'navigation') return '页面导航';
    final key = '${item['key']}';
    if (kind == 'screen' || kind == 'variable') {
      final matching = entries(
        kind == 'screen' ? 'screens' : 'variables',
      ).where((entry) => keyOf(entry) == key);
      if (matching.isNotEmpty) {
        final name = entryName(matching.first, kind == 'screen');
        if (name.isNotEmpty) return '$name · $key';
      }
    }
    return key;
  }

  bool matchedVariable(Json item) {
    if (item['kind'] != 'variable' || item['status'] != 'unchanged') {
      return false;
    }
    final mode = variableTargets['${item['key']}']?['mode'];
    return mode == 'match_existing' ||
        mode == 'reference' ||
        item['message'] == 'unique source identity reference';
  }

  bool get navigationBlocked => objects(preview?['items']).any(
    (item) =>
        item['kind'] == 'navigation' &&
        const {'error', 'unresolved', 'failed'}.contains(item['status']),
  );

  Widget rows(Json? data) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (data != null)
        Text(
          '共 ${objects(data['items']).length} 项 · 变量已匹配 ${objects(data['items']).where(matchedVariable).length} 项 · 变量需处理 ${objects(data['items']).where((item) => item['kind'] == 'variable' && (item['status'] == 'unresolved' || item['status'] == 'error' || item['status'] == 'failed')).length} 项',
        ),
      for (final item in objects(data?['items']))
        ExpansionTile(
          dense: true,
          title: Text(
            '${itemKind(item['kind'])} · ${itemName(item)} · ${itemStatus(item)}',
          ),
          subtitle: Text(message(item['message'])),
          children: [
            if (item['kind'] == 'variable' && item['after'] is Map)
              SelectableText('目标变量：${metadata(item['after'])}'),
            for (final candidate in objects(item['candidates']))
              SelectableText(
                '候选：${metadata(candidate['definition'])} · ${candidate['compatible'] == true ? '兼容' : '不兼容'} · 差异：${fieldNames(candidate['differences'])} · 冲突：${fieldNames(candidate['conflicts'])}',
              ),
            if (item['kind'] == 'binding')
              TextButton.icon(
                onPressed: () => locate(item),
                icon: const Icon(Icons.center_focus_strong),
                label: const Text('定位画面位置'),
              ),
            SelectableText(
              item['kind'] == 'navigation'
                  ? '变更前：\n${navigationSummary(item['before'])}\n变更后：\n${navigationSummary(item['after'])}'
                  : '变更前：${summary(item['before'])}\n变更后：${summary(item['after'])}',
            ),
          ],
        ),
      if (objects(data?['remaining']).isNotEmpty)
        Text('剩余 ${objects(data?['remaining']).length} 项'),
    ],
  );
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('工艺资料导入 / 导出'),
      content: SizedBox(
        width: 700,
        height: 500,
        child: Column(
          children: [
            Row(
              children: [
                ChoiceChip(
                  label: const Text('导入'),
                  selected: !exporting,
                  onSelected: busy
                      ? null
                      : (_) => setState(() {
                          exporting = false;
                          step = 0;
                        }),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('导出'),
                  selected: exporting,
                  onSelected: busy
                      ? null
                      : (_) => setState(() => exporting = true),
                ),
              ],
            ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(error, style: const TextStyle(color: Colors.red)),
              ),
            Expanded(
              child: SingleChildScrollView(
                child: exporting
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          select(
                            '内容',
                            kind,
                            ['screens', 'variables', 'bindings', 'bundle'],
                            (v) {
                              kind = v;
                              if (format == 'csv' &&
                                  v != 'variables' &&
                                  v != 'bindings') {
                                format = 'json';
                              }
                            },
                            labels: const {
                              'screens': '画面布局',
                              'variables': '变量定义',
                              'bindings': '变量绑定',
                              'bundle': '完整包',
                            },
                          ),
                          select('格式', format, [
                            'json',
                            'xlsx',
                            if (kind == 'variables' || kind == 'bindings')
                              'csv',
                          ], (v) => format = v),
                          const Text('CSV 仅支持变量或绑定；画面布局和图片使用 JSON 或 XLSX。'),
                          CheckboxListTile(
                            dense: true,
                            title: const Text('公共实例导出为独立副本（不保留同步关联）'),
                            value: expandShared,
                            onChanged: (v) =>
                                setState(() => expandShared = v == true),
                          ),
                          const Text('选择工艺画面（可多选）'),
                          for (final s in screens)
                            CheckboxListTile(
                              dense: true,
                              title: Text(
                                '${s['name']} · ${s['station'] ?? '公共'}',
                              ),
                              value: selectedScreens.contains('${s['id']}'),
                              onChanged: (v) => setState(() {
                                if (v == true) {
                                  selectedScreens.add('${s['id']}');
                                } else {
                                  selectedScreens.remove('${s['id']}');
                                }
                              }),
                            ),
                          const Text('选择变量（每页最多 50 项）'),
                          TextField(
                            decoration: const InputDecoration(
                              labelText: '搜索导出变量',
                            ),
                            onChanged: (v) => setState(() {
                              filter = v;
                              page = 0;
                            }),
                          ),
                          for (final v
                              in widget.variables
                                  .where(
                                    (v) => '${v['name']} ${v['station']}'
                                        .contains(filter),
                                  )
                                  .skip(page * 50)
                                  .take(50))
                            CheckboxListTile(
                              dense: true,
                              title: Text('${v['name']} · ${v['station']}'),
                              value: selectedVariables.contains('${v['id']}'),
                              onChanged: (value) => setState(() {
                                if (value == true) {
                                  selectedVariables.add('${v['id']}');
                                } else {
                                  selectedVariables.remove('${v['id']}');
                                }
                              }),
                            ),
                          Row(
                            children: [
                              TextButton(
                                onPressed: page > 0
                                    ? () => setState(() => page--)
                                    : null,
                                child: const Text('上一页'),
                              ),
                              Text('第 ${page + 1} 页'),
                              TextButton(
                                onPressed:
                                    widget.variables
                                            .where(
                                              (v) =>
                                                  '${v['name']} ${v['station']}'
                                                      .contains(filter),
                                            )
                                            .length >
                                        (page + 1) * 50
                                    ? () => setState(() => page++)
                                    : null,
                                child: const Text('下一页'),
                              ),
                            ],
                          ),
                        ],
                      )
                    : step == 0
                    ? const Text('选择工艺资料文件，支持 JSON、XLSX 和 CSV。')
                    : step == 1
                    ? mapping()
                    : rows(step == 2 ? preview : result),
              ),
            ),
          ],
        ),
      ),
      actions: [
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            if (!exporting && step > 0 && step < 3)
              TextButton(
                onPressed: busy ? null : () => setState(() => step--),
                child: const Text('上一步'),
              ),
            if (!exporting && step >= 2)
              TextButton(
                onPressed: busy ? null : saveRemaining,
                child: const Text('导出剩余清单'),
              ),
            FilledButton(
              onPressed: busy || (!exporting && step == 2 && navigationBlocked)
                  ? null
                  : exporting
                  ? export
                  : step == 0
                  ? choose
                  : step == 1
                  ? inspect
                  : step == 2
                  ? commit
                  : null,
              child: Text(
                busy
                    ? '处理中…'
                    : exporting
                    ? '导出'
                    : step == 0
                    ? '选择文件'
                    : step == 1
                    ? '预览'
                    : step == 2
                    ? '确认保存'
                    : '已完成',
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
