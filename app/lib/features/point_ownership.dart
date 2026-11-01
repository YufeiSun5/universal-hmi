import 'dart:convert';
import 'dart:typed_data';
import '../platform/save.dart';
import '../platform/process_files.dart';
import 'package:flutter/material.dart';
import '../shared/api.dart';

class PointOwnershipDialog extends StatefulWidget {
  const PointOwnershipDialog({
    super.key,
    required this.api,
    required this.stations,
    this.pickRecovery,
  });
  final PlatformApi api;
  final Future<ProcessFile?> Function()? pickRecovery;
  final List<String> stations;
  @override
  State<PointOwnershipDialog> createState() => _PointOwnershipDialogState();
}

class _PointOwnershipDialogState extends State<PointOwnershipDialog> {
  List<Json> items = [];
  final Map<String, String> selected = {};
  String filter = '', category = 'all', batchStation = '', error = '';
  bool busy = true;
  Json? preview, savedResult;
  List<Json>? recoveryTargets;
  List<Json> get visible => items
      .where(
        (p) =>
            (category == 'all' || p['classification'] == category) &&
            '${p['name']} ${p['id']} ${p['station']}'.toLowerCase().contains(
              filter.toLowerCase(),
            ),
      )
      .toList();
  List<Json> get targets =>
      recoveryTargets ??
      [
        for (final p in items)
          if (selected.containsKey('${p['id']}'))
            {
              'id': p['id'],
              'revision': p['revision'],
              'station': selected['${p['id']}'],
            },
      ];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.api.request(
        'POST',
        '/api/v1/points/ownership-preview',
        body: {'targets': <Json>[]},
      );
      if (mounted) {
        setState(() {
          items = objects(result['items']);
          busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '读取归属分析失败：$e';
          busy = false;
        });
      }
    }
  }

  Future<void> loadRecovery() async {
    try {
      final file =
          await (widget.pickRecovery?.call() ?? pickProcessFile(image: false));
      if (file == null) return;
      final data = jsonDecode(utf8.decode(file.bytes));
      if (data is! Map ||
          data['schema'] != 'universal-hmi-point-ownership-recovery-v1' ||
          data['rollback_targets'] is! List) {
        throw const FormatException('回退清单格式不正确');
      }
      final parsed = <Json>[];
      final ids = <String>{};
      for (final raw in data['rollback_targets'] as List) {
        if (raw is! Map ||
            raw['id'] is! String ||
            raw['revision'] is! String ||
            raw['station'] is! String ||
            (raw['id'] as String).isEmpty ||
            (raw['revision'] as String).isEmpty ||
            (raw['station'] as String).isEmpty ||
            !ids.add(raw['id'] as String)) {
          throw const FormatException('回退目标无效或重复');
        }
        parsed.add({
          'id': raw['id'],
          'revision': raw['revision'],
          'station': raw['station'],
        });
      }
      if (parsed.isEmpty) throw const FormatException('回退清单没有目标');
      if (mounted) {
        setState(() {
          recoveryTargets = parsed;
          selected.clear();
          for (final p in parsed) {
            selected[p['id'] as String] = p['station'] as String;
          }
          error = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '读取回退清单失败：$e');
    }
  }

  Future<void> inspect() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.api.request(
        'POST',
        '/api/v1/points/ownership-preview',
        body: {'targets': targets},
      );
      if (mounted) setState(() => preview = result);
    } catch (e) {
      if (mounted) setState(() => error = '预览失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> commit() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final result = await widget.api.request(
        'POST',
        '/api/v1/points/ownership-commit',
        body: {'targets': targets, 'preview_token': preview!['preview_token']},
      );
      if (result['saved'] != true) throw StateError('服务未确认保存');
      if (mounted) setState(() => savedResult = result);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '保存失败，请重新预览：$e';
          preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String reason(dynamic code) => switch (code) {
    'revision-conflict' => '变量版本已变化',
    'target-station-missing' => '目标站不存在',
    'target-name-collision' => '目标站变量名称重复',
    'station-storage-policy' => '站点存储策略引用',
    'enabled-whole-station-storage-policy' => '启用的全站存储策略引用',
    'scoped-automation-rule' => '站点自动化规则引用',
    'automation-rule' => '自动化规则引用',
    'derived-dependent' => '被派生变量引用',
    'derived-inputs' => '包含派生输入',
    _ => '$code',
  };
  String label(dynamic c) => switch (c) {
    'single' => '单站引用',
    'shared' => '多站共享',
    'unreferenced' => '未引用',
    _ => '$c',
  };
  @override
  Widget build(BuildContext context) {
    final stations = widget.stations.where((s) => s.isNotEmpty).toSet().toList()
      ..sort();
    final rows = preview == null
        ? visible
        : objects(
            preview!['items'],
          ).where((p) => selected.containsKey('${p['id']}')).toList();
    final single = items.where((p) => p['classification'] == 'single').length;
    final shared = items.where((p) => p['classification'] == 'shared').length;
    final missing = items
        .where((p) => p['classification'] == 'unreferenced')
        .length;
    if (savedResult != null) {
      return AlertDialog(
        title: const Text('归属已保存'),
        content: const Text('当前实时数据保持不变。请保存回退清单；先应用配置，再检查并删除空旧站。应用后实时值会重新采集。'),
        actions: [
          OutlinedButton(
            onPressed: () async {
              try {
                final backup = savedResult!['backup'];
                if (backup is! Map) throw StateError('服务未返回回退清单');
                await saveFile(
                  Uint8List.fromList(
                    utf8.encode(
                      const JsonEncoder.withIndent('  ').convert(backup),
                    ),
                  ),
                  'variable-ownership-rollback.json',
                );
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('保存回退清单失败：$e')));
                }
              }
            },
            child: const Text('保存回退清单'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('完成'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: const Text('按工艺画面整理变量归属'),
      content: SizedBox(
        width: 760,
        height: (MediaQuery.sizeOf(context).height - 260).clamp(180.0, 510.0),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                children: [
                  const Text(
                    '建议仅依据已授权工艺画面引用，并非物理归属判断。多站共享和未引用变量默认保留原站。保存只修改归属，需另行应用配置。',
                  ),
                  Text(
                    '总计 ${items.length} · 单站引用 $single · 多站共享 $shared · 未引用 $missing · 已选择 ${selected.length}',
                  ),
                  if (error.isNotEmpty)
                    Text(error, style: const TextStyle(color: Colors.red)),
                  if (preview == null) ...[
                    if (recoveryTargets != null)
                      const Text('已载入回退清单；原站必须存在，版本过期将阻断保存。'),
                    TextField(
                      decoration: const InputDecoration(
                        labelText: '搜索变量、原站或 ID',
                      ),
                      onChanged: (v) => setState(() => filter = v),
                    ),
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        TextButton(
                          onPressed: busy ? null : loadRecovery,
                          child: const Text('载入回退清单'),
                        ),
                        DropdownButton<String>(
                          value: category,
                          items: const [
                            DropdownMenuItem(value: 'all', child: Text('全部')),
                            DropdownMenuItem(
                              value: 'single',
                              child: Text('单站引用'),
                            ),
                            DropdownMenuItem(
                              value: 'shared',
                              child: Text('多站共享'),
                            ),
                            DropdownMenuItem(
                              value: 'unreferenced',
                              child: Text('未引用'),
                            ),
                          ],
                          onChanged: busy
                              ? null
                              : (v) => setState(() => category = v!),
                        ),
                        TextButton(
                          onPressed: busy || recoveryTargets != null
                              ? null
                              : () => setState(() {
                                  for (final p in visible) {
                                    final s = '${p['suggested_station'] ?? ''}';
                                    if (p['classification'] == 'single' &&
                                        stations.contains(s) &&
                                        s != p['station']) {
                                      selected['${p['id']}'] = s;
                                    }
                                  }
                                }),
                          child: const Text('选择筛选内单站建议'),
                        ),
                        DropdownButton<String>(
                          key: const Key('ownership-batch-station'),
                          hint: const Text('批量目标站'),
                          value: stations.contains(batchStation)
                              ? batchStation
                              : null,
                          items: [
                            for (final s in stations)
                              DropdownMenuItem(value: s, child: Text(s)),
                          ],
                          onChanged: busy
                              ? null
                              : (v) => setState(() => batchStation = v ?? ''),
                        ),
                        TextButton(
                          onPressed:
                              busy ||
                                  recoveryTargets != null ||
                                  batchStation.isEmpty
                              ? null
                              : () => setState(() {
                                  recoveryTargets = null;
                                  for (final p in visible) {
                                    if (p['station'] != batchStation) {
                                      selected['${p['id']}'] = batchStation;
                                    } else {
                                      selected.remove('${p['id']}');
                                    }
                                  }
                                }),
                          child: const Text('设置筛选结果目标'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  selected.clear();
                                  recoveryTargets = null;
                                }),
                          child: const Text('清空选择'),
                        ),
                      ],
                    ),
                  ] else
                    Text(
                      preview!['can_commit'] == true
                          ? '请核对以下实际归属变更'
                          : '存在冲突，整批不能保存；请返回调整。',
                    ),
                ],
              ),
            ),
            SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final p = rows[i], id = '${p['id']}', target = selected[id];
                final refs = objects(p['references'])
                    .map(
                      (r) =>
                          '${r['station']} / ${r['screen_name']} (${r['property']})',
                    )
                    .join('、');
                final blockers = (p['blockers'] as List? ?? [])
                    .map(reason)
                    .join('、');
                final dependencies = (p['dependencies'] as List? ?? [])
                    .map(reason)
                    .join('、');
                if (preview != null) {
                  return ListTile(
                    dense: true,
                    title: Text(
                      '${p['name']}：${p['station']} → ${p['target_station']}',
                    ),
                    subtitle: Text(
                      '${label(p['classification'])} · $refs\n${blockers.isEmpty ? '可保存' : blockers}${dependencies.isEmpty ? '' : ' · 依赖：$dependencies'}',
                    ),
                  );
                }
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final narrow = constraints.maxWidth < 480;
                    final targetDropdown = SizedBox(
                      width: 170,
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: stations.contains(target) ? target : null,
                        hint: const Text('保持原站'),
                        items: [
                          for (final s in stations)
                            DropdownMenuItem(
                              value: s,
                              child: Text(s, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: busy || recoveryTargets != null
                            ? null
                            : (v) => setState(() {
                                recoveryTargets = null;
                                if (v == null || v == p['station']) {
                                  selected.remove(id);
                                } else {
                                  selected[id] = v;
                                }
                              }),
                      ),
                    );
                    return ListTile(
                      dense: true,
                      title: Text(
                        '${p['name']} · ${p['station']} → ${target ?? '保持原站'}',
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${label(p['classification'])} · ${refs.isEmpty ? '无画面引用' : refs}\n$id',
                          ),
                          if (narrow) targetDropdown,
                        ],
                      ),
                      trailing: narrow ? null : targetDropdown,
                      onTap: busy || recoveryTargets != null || target == null
                          ? null
                          : () => setState(() {
                              recoveryTargets = null;
                              selected.remove(id);
                            }),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy
              ? null
              : () {
                  if (preview != null) {
                    setState(() => preview = null);
                  } else {
                    Navigator.pop(context);
                  }
                },
          child: Text(preview == null ? '取消' : '返回修改'),
        ),
        if (preview == null)
          FilledButton(
            onPressed: busy || selected.isEmpty ? null : inspect,
            child: const Text('预览变更'),
          )
        else
          FilledButton(
            onPressed: busy || preview!['can_commit'] != true ? null : commit,
            child: const Text('确认保存归属'),
          ),
      ],
    );
  }
}
