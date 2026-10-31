import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/variable_search.dart';

String deletionStatus(dynamic status) => switch ('$status') {
  'ready' => '可删除',
  'blocked' => '存在引用',
  'conflict' => '版本冲突',
  _ => '$status',
};
String deletionReferences(dynamic value) {
  final refs = objects(value);
  if (refs.isEmpty) return '无';
  const kinds = {
    'screen': '画面',
    'screens': '画面',
    'point': '变量',
    'variable': '变量',
    'station': '站点',
    'gis': 'GIS',
    'rule': '规则',
    'rules': '规则',
    'policy': '存储策略',
    'station_policies': '站点策略',
    'equipment_register': '设备台账',
    'storage': '存储',
  };
  return refs
      .map(
        (r) => r['kind'] == 'runtime'
            ? '运行配置仍归属此站，请先应用已保存的归属，再重新检查删除'
            : '${kinds[r['kind']] ?? r['kind']}：${r['id'] ?? ''} ${r['property'] ?? ''}',
      )
      .join('\n');
}

class PointDeleteDialog extends StatefulWidget {
  const PointDeleteDialog({
    super.key,
    required this.api,
    this.initialIDs = const {},
  });
  final PlatformApi api;
  final Set<String> initialIDs;
  @override
  State<PointDeleteDialog> createState() => _PointDeleteDialogState();
}

class _PointDeleteDialogState extends State<PointDeleteDialog> {
  List<Json> points = [];
  final selected = <String>{};
  String filter = '', error = '';
  bool busy = true;
  Json? preview;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final catalog = await widget.api.request(
        'GET',
        '/api/v1/process-transfer/catalog',
      );
      if (mounted) {
        setState(() {
          points = objects(catalog['variables']);
          selected.addAll(
            widget.initialIDs.intersection(
              points.map((p) => '${p['id']}').toSet(),
            ),
          );
          busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '读取变量失败：$e';
          busy = false;
        });
      }
    }
  }

  List<Json> get visible =>
      points.where(VariableSearch(filter).matchesPoint).toList();
  List<Json> get targets => [
    for (final p in points)
      if (selected.contains('${p['id']}'))
        {'id': p['id'], 'revision': p['revision']},
  ];
  Future<void> inspect() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final value = await widget.api.request(
        'POST',
        '/api/v1/points/delete-preview',
        body: {'targets': targets},
      );
      if (mounted) setState(() => preview = value);
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
      await widget.api.request(
        'POST',
        '/api/v1/points/delete-commit',
        body: {'targets': targets, 'preview_token': preview!['preview_token']},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '删除失败，请重新预览：$e';
          preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = visible;
    final pointById = {for (final point in points) '${point['id']}': point};
    return AlertDialog(
      title: const Text('批量删除变量配置'),
      content: SizedBox(
        width: 650,
        height: 460,
        child: Column(
          children: [
            const Text('仅删除所选变量定义；引用或版本冲突会阻止整批删除。不会自动应用运行配置。'),
            if (error.isNotEmpty) Text(error),
            if (preview == null) ...[
              TextField(
                decoration: const InputDecoration(labelText: '搜索变量、站点或 ID'),
                onChanged: (v) => setState(() => filter = v),
              ),
              Row(
                children: [
                  Text('已选择 ${selected.length} 项'),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            selected.addAll(rows.map((e) => '${e['id']}'));
                          }),
                    child: const Text('选择当前筛选'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => setState(selected.clear),
                    child: const Text('清空选择'),
                  ),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final p = rows[index], id = '${p['id']}';
                    return CheckboxListTile(
                      dense: true,
                      title: Text('${p['name']} · ${p['station']}'),
                      subtitle: Text(id),
                      value: selected.contains(id),
                      onChanged: busy
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                selected.add(id);
                              } else {
                                selected.remove(id);
                              }
                            }),
                    );
                  },
                ),
              ),
            ] else ...[
              Text(
                '已选择 ${selected.length} 项 · ${preview!['can_commit'] == true ? '可删除' : '存在阻断，不能删除'}',
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final item in objects(preview!['items']))
                      ListTile(
                        dense: true,
                        title: Text(
                          '${pointById['${item['id']}']?['name'] ?? '未知变量'} · ${pointById['${item['id']}']?['station'] ?? '未知归属'} · ${item['id']} · ${deletionStatus(item['status'])}',
                        ),
                        subtitle: Text(
                          '引用：${deletionReferences(item['references'])}',
                        ),
                      ),
                  ],
                ),
              ),
            ],
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
                    Navigator.pop(context, false);
                  }
                },
          child: Text(preview == null ? '取消' : '返回修改'),
        ),
        if (preview == null)
          FilledButton(
            onPressed: busy || selected.isEmpty ? null : inspect,
            child: const Text('预览删除'),
          )
        else
          FilledButton(
            onPressed: busy || preview!['can_commit'] != true ? null : commit,
            child: const Text('确认删除'),
          ),
      ],
    );
  }
}

class StationDeleteDialog extends StatefulWidget {
  const StationDeleteDialog({
    super.key,
    required this.api,
    required this.station,
  });
  final PlatformApi api;
  final String station;
  @override
  State<StationDeleteDialog> createState() => _StationDeleteDialogState();
}

class _StationDeleteDialogState extends State<StationDeleteDialog> {
  bool busy = true;
  String error = '';
  String confirmation = '';
  Json? preview;
  List<Json> get targets => [
    {'name': widget.station},
  ];
  @override
  void initState() {
    super.initState();
    inspect();
  }

  Future<void> inspect() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final data = await widget.api.request(
        'POST',
        '/api/v1/stations/delete-preview',
        body: {'targets': targets},
      );
      if (mounted) setState(() => preview = data);
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
      await widget.api.request(
        'POST',
        '/api/v1/stations/delete-commit',
        body: {'targets': targets, 'preview_token': preview!['preview_token']},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          preview = null;
          error = '删除失败，请重新预览：$e';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('删除站点 ${widget.station}'),
    content: SizedBox(
      width: 580,
      height: 300,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('存在变量、画面等引用时无法删除；历史数据保留，不会级联删除。'),
          if (error.isNotEmpty) Text(error),
          if (busy) const CircularProgressIndicator(),
          if (preview != null) ...[
            Text(preview!['can_commit'] == true ? '可以删除' : '存在依赖，不能删除'),
            if (preview!['can_commit'] == true)
              TextField(
                decoration: InputDecoration(
                  labelText: '请输入站点名称 ${widget.station} 以确认',
                ),
                onChanged: (value) => setState(() => confirmation = value),
              ),
            Expanded(
              child: ListView(
                children: [
                  for (final item in objects(preview!['items']))
                    ListTile(
                      title: Text(
                        '${item['name']} · ${deletionStatus(item['status'])}',
                      ),
                      subtitle: Text(
                        '依赖：${deletionReferences(item['references'])}',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      if (preview == null)
        TextButton(onPressed: busy ? null : inspect, child: const Text('重新预览'))
      else
        FilledButton(
          onPressed:
              busy ||
                  preview!['can_commit'] != true ||
                  confirmation != widget.station
              ? null
              : commit,
          child: const Text('确认删除'),
        ),
    ],
  );
}
