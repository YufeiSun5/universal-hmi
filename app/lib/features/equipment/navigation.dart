import 'dart:convert';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/desktop_sidebar.dart';
import '../process/model.dart' show screenIdentity;

List<Json> equipmentChildren(Json n) =>
    (n['children'] as List? ?? const []).cast<Json>();
Iterable<Json> equipmentWalk(List<Json> nodes) sync* {
  for (final n in nodes) {
    yield n;
    yield* equipmentWalk(equipmentChildren(n));
  }
}

class EquipmentNavigation extends StatefulWidget {
  const EquipmentNavigation({
    super.key,
    required this.nodes,
    required this.station,
    required this.site,
    required this.onOpen,
    this.query = '',
  });
  final List<Json> nodes;
  final String station, site;
  final String query;
  final void Function(String, String) onOpen;
  @override
  State<EquipmentNavigation> createState() => _EquipmentNavigationState();
}

class _EquipmentNavigationState extends State<EquipmentNavigation> {
  final collapsed = <String>{};
  Widget row(Json n, int depth, [bool parentMatches = false]) {
    if (!parentMatches &&
        widget.query.isNotEmpty &&
        !equipmentWalk([n]).any(
          (child) =>
              '${child['label']} ${child['station'] ?? ''} ${child['site'] ?? ''}'
                  .toLowerCase()
                  .contains(widget.query),
        )) {
      return const SizedBox.shrink();
    }
    final group = (n['station'] as String? ?? '').isEmpty;
    final ownMatch =
        parentMatches ||
        widget.query.isEmpty ||
        (n['label'] as String? ?? '').toLowerCase().contains(widget.query);
    final expanded = widget.query.isNotEmpty || !collapsed.contains(n['id']);
    final active =
        !group &&
        n['station'] == widget.station &&
        (n['site'] ?? '') == widget.site;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.only(left: depth * 12.0),
          child: Material(
            color: active ? DesktopSidebar.selection : Colors.transparent,
            child: Row(
              children: [
                if (group)
                  IconButton(
                    tooltip: expanded ? '折叠菜单' : '展开菜单',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(
                      () => expanded
                          ? collapsed.add(n['id'] as String)
                          : collapsed.remove(n['id']),
                    ),
                    icon: Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 18,
                    ),
                  )
                else
                  const SizedBox(width: 20),
                Expanded(
                  child: InkWell(
                    onTap: group
                        ? () => setState(
                            () => expanded
                                ? collapsed.add(n['id'] as String)
                                : collapsed.remove(n['id']),
                          )
                        : () => widget.onOpen(
                            n['station'] as String,
                            n['site'] as String? ?? '',
                          ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 9,
                        horizontal: 6,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            group
                                ? Icons.folder_outlined
                                : Icons.apartment_outlined,
                            size: 16,
                            color: DesktopSidebar.muted,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              n['label'] as String? ?? '',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: DesktopSidebar.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (group && expanded)
          for (final child in equipmentChildren(n))
            row(child, depth + 1, ownMatch),
      ],
    );
  }

  @override
  Widget build(BuildContext context) =>
      ListView(children: [for (final n in widget.nodes) row(n, 0)]);
}

class EquipmentNavigationEditor extends StatefulWidget {
  const EquipmentNavigationEditor({
    super.key,
    required this.api,
    required this.stations,
    required this.places,
  });
  final PlatformApi api;
  final List<String> stations;
  final List<Json> places;
  @override
  State<EquipmentNavigationEditor> createState() =>
      _EquipmentNavigationEditorState();
}

class _EquipmentNavigationEditorState extends State<EquipmentNavigationEditor> {
  List<Json> nodes = [];
  int revision = 0;
  bool loading = true, saving = false, loaded = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final c = await widget.api.request('GET', '/api/v1/equipment-navigation');
      if (!mounted) return;
      setState(() {
        nodes = objects(jsonDecode(jsonEncode(c['nodes'] ?? [])));
        revision = c['revision'] as int? ?? 0;
        loading = false;
        loaded = true;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  List<Json>? parentOf(String id, List<Json> list) {
    if (list.any((n) => n['id'] == id)) return list;
    for (final n in list) {
      final found = parentOf(id, equipmentChildren(n));
      if (found != null) return found;
    }
    return null;
  }

  void move(Json node, int delta) {
    final list = parentOf(node['id'] as String, nodes)!;
    final i = list.indexWhere((n) => n['id'] == node['id']);
    if (i + delta < 0 || i + delta >= list.length) return;
    setState(() {
      final n = list.removeAt(i);
      list.insert(i + delta, n);
    });
  }

  Future<void> edit({Json? node, required bool group}) async {
    final name = TextEditingController(text: node?['label'] as String? ?? '');
    var station = node?['station'] as String? ?? '';
    var site = node?['site'] as String? ?? '';
    var parent = '';
    for (final n in equipmentWalk(nodes)) {
      if (equipmentChildren(n).any((c) => c['id'] == node?['id'])) {
        parent = n['id'] as String;
      }
    }
    final excluded = node == null
        ? <String>{}
        : equipmentWalk([node]).map((n) => n['id'] as String).toSet();
    final groups = equipmentWalk(nodes)
        .where((n) => (n['station'] ?? '') == '' && !excluded.contains(n['id']))
        .toList();
    String? failure;
    final result = await showDialog<Json>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(group ? '菜单分组' : '站区菜单项'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '菜单名称'),
                    maxLength: 80,
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: parent,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '上级分组'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('顶层')),
                      for (final n in groups)
                        DropdownMenuItem(
                          value: n['id'] as String,
                          child: Text(n['label'] as String),
                        ),
                    ],
                    onChanged: (v) => update(() => parent = v!),
                  ),
                  if (!group) ...[
                    DropdownButtonFormField<String>(
                      initialValue: station.isEmpty ? null : station,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '目标站区'),
                      items: [
                        for (final s in {
                          ...widget.stations,
                          if (station.isNotEmpty) station,
                        })
                          DropdownMenuItem(value: s, child: Text(s)),
                      ],
                      onChanged: (v) => update(() {
                        station = v ?? '';
                        site = '';
                      }),
                    ),
                    DropdownButtonFormField<String>(
                      key: ValueKey(station),
                      initialValue: site,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '目标小站'),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('整个站区')),
                        for (final s in {
                          ...widget.places
                              .where((p) => p['station'] == station)
                              .map((p) => p['site'] as String? ?? '')
                              .where((s) => s.isNotEmpty),
                          if (site.isNotEmpty) site,
                        })
                          DropdownMenuItem(value: s, child: Text(s)),
                      ],
                      onChanged: (v) => update(() => site = v ?? ''),
                    ),
                  ],
                  if (failure != null)
                    Text(failure!, style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty || (!group && station.isEmpty)) {
                  update(() => failure = '请填写名称并选择目标站区');
                  return;
                }
                Navigator.pop(dialog, <String, dynamic>{
                  'parent': parent,
                  'label': name.text.trim(),
                  'station': group ? '' : station,
                  'site': site,
                });
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    name.dispose();
    if (!mounted || result == null) return;
    setState(() {
      final next = <String, dynamic>{
        'id': node?['id'] ?? screenIdentity(),
        'label': result['label'],
        if (!group) 'station': result['station'],
        if (!group && result['site'] != '') 'site': result['site'],
        if (group) 'children': node?['children'] ?? <Json>[],
      };
      final old = node == null ? null : parentOf(node['id'] as String, nodes);
      final index = old?.indexWhere((n) => n['id'] == next['id']) ?? -1;
      final destination = result['parent'] == ''
          ? nodes
          : (equipmentWalk(nodes)
                        .firstWhere((n) => n['id'] == result['parent'])
                        .putIfAbsent('children', () => <Json>[])
                    as List)
                .cast<Json>();
      final same =
          identical(old, destination) ||
          old != null &&
              old.any((n) => n['id'] == next['id']) &&
              destination.any((n) => n['id'] == next['id']);
      old?.removeWhere((n) => n['id'] == next['id']);
      if (same) {
        destination.insert(index, next);
      } else {
        destination.add(next);
      }
    });
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.api.request(
        'PUT',
        '/api/v1/equipment-navigation',
        body: {'revision': revision, 'nodes': nodes},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$e';
        });
      }
    }
  }

  List<Widget> rows(List<Json> items, int depth) => [
    for (final n in items) ...[
      Padding(
        padding: EdgeInsets.only(left: depth * 18.0),
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            (n['station'] ?? '') == ''
                ? Icons.folder_outlined
                : Icons.apartment_outlined,
            size: 18,
          ),
          title: Text(n['label'] as String),
          subtitle: (n['station'] ?? '') == ''
              ? null
              : Text('${n['station']} / ${n['site'] ?? '全部'}'),
          onTap: saving
              ? null
              : () => edit(node: n, group: (n['station'] ?? '') == ''),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '上移',
                onPressed: saving ? null : () => move(n, -1),
                icon: const Icon(Icons.arrow_upward, size: 16),
              ),
              IconButton(
                tooltip: '下移',
                onPressed: saving ? null : () => move(n, 1),
                icon: const Icon(Icons.arrow_downward, size: 16),
              ),
              IconButton(
                tooltip: '删除菜单项及子项',
                onPressed: saving
                    ? null
                    : () => setState(
                        () => parentOf(
                          n['id'] as String,
                          nodes,
                        )!.removeWhere((v) => v['id'] == n['id']),
                      ),
                icon: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
        ),
      ),
      ...rows(equipmentChildren(n), depth + 1),
    ],
  ];
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('设备目录配置'),
    content: SizedBox(
      width: 720,
      height: 500,
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('分组只影响菜单，不改变设备所属站区。清空菜单时恢复默认站区目录。'),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: saving ? null : () => edit(group: true),
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('添加分组'),
                      ),
                      OutlinedButton.icon(
                        onPressed: saving ? null : () => edit(group: false),
                        icon: const Icon(Icons.add),
                        label: const Text('添加站区'),
                      ),
                    ],
                  ),
                  ...rows(nodes, 0),
                  if (error != null)
                    SelectableText(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  if (!loaded && error != null)
                    TextButton(
                      onPressed: () {
                        setState(() {
                          loading = true;
                          error = null;
                        });
                        load();
                      },
                      child: const Text('重试加载目录'),
                    ),
                ],
              ),
            ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: !loaded || saving ? null : save,
        child: Text(saving ? '正在保存…' : '保存菜单'),
      ),
    ],
  );
}
