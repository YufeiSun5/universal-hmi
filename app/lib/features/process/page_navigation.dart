import 'dart:convert';
import 'dart:typed_data';
import '../../platform/process_files.dart';
import '../../platform/save.dart';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import 'model.dart';

List<Json> navigationChildren(Json node) =>
    (node['children'] as List? ?? const []).cast<Json>();
Iterable<Json> navigationWalk(List<Json> nodes) sync* {
  for (final node in nodes) {
    yield node;
    yield* navigationWalk(navigationChildren(node));
  }
}

Json decodeNavigationFile(Uint8List bytes) {
  if (bytes.length > 8 * 1024 * 1024) {
    throw const FormatException('菜单文件超过 8 MiB');
  }
  final file = jsonDecode(utf8.decode(bytes));
  if (file is! Json ||
      file['format'] != 'universal-hmi-page-navigation' ||
      file['version'] != 1 ||
      file['enabled'] is! bool ||
      file['nodes'] is! List) {
    throw const FormatException('请选择导出的页面导航 JSON');
  }
  final ids = <String>{};
  final nodeId = RegExp(r'^[a-zA-Z0-9_-]{1,80}$');
  final targetId = RegExp(r'^[a-zA-Z0-9_-]{1,96}$');
  void validate(List items, int depth) {
    for (final n in items) {
      if (n is! Json ||
          n['id'] is! String ||
          !nodeId.hasMatch(n['id']) ||
          !ids.add(n['id']) ||
          depth > 4 ||
          ids.length > 256 ||
          n['label'] is! String ||
          n['label'].trim().isEmpty ||
          utf8.encode(n['label']).length > 256) {
        throw const FormatException('菜单节点无效，请检查名称、唯一 ID、4 层和 256 项限制');
      }
      final children = n['children'] ?? [];
      final target = n['screen_id'] ?? '';
      if (children is! List ||
          target is! String ||
          (target.isNotEmpty &&
              (!targetId.hasMatch(target) || children.isNotEmpty))) {
        throw const FormatException('画面引用或子菜单结构无效');
      }
      validate(children, depth + 1);
    }
  }

  validate(file['nodes'], 1);
  return file;
}

Json? firstNavigationScreen(Json node, Map<String, Json> screens) {
  final id = node['screen_id'];
  if (id != null && screens[id] != null) return screens[id];
  for (final child in navigationChildren(node)) {
    final found = firstNavigationScreen(child, screens);
    if (found != null) return found;
  }
  return null;
}

/// A menu is presentation only. Targets retain their own station and identity.
class PageNavigationTree extends StatefulWidget {
  const PageNavigationTree({
    super.key,
    required this.nodes,
    required this.screens,
    required this.onOpen,
    this.selectedID,
    this.query = '',
  });
  final List<Json> nodes, screens;
  final ValueChanged<Json> onOpen;
  final String? selectedID;
  final String query;
  @override
  State<PageNavigationTree> createState() => _PageNavigationTreeState();
}

class _PageNavigationTreeState extends State<PageNavigationTree> {
  final collapsed = <String>{};
  Map<String, Json> get index => {
    for (final s in widget.screens) s['id'] as String: s,
  };
  @override
  void didUpdateWidget(covariant PageNavigationTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedID != widget.selectedID) {
      for (final n in navigationWalk(widget.nodes)) {
        if (containsSelected(n)) collapsed.remove(n['id']);
      }
    }
  }

  bool containsSelected(Json n) => navigationWalk([
    n,
  ]).any((c) => c['screen_id'] != null && c['screen_id'] == widget.selectedID);
  bool matches(Json n) => navigationWalk([n]).any((c) {
    final s = index[c['screen_id']];
    return '${c['label']} ${s?['name'] ?? ''} ${s?['station'] ?? ''}'
        .toLowerCase()
        .contains(widget.query);
  });
  void open(Json node) {
    final target = firstNavigationScreen(node, index);
    if (target == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('此菜单没有可用画面，请在开发端检查配置')));
      return;
    }
    setState(() {
      for (final n in navigationWalk([node])) {
        if (navigationWalk([n]).any((c) => c['screen_id'] == target['id'])) {
          collapsed.remove(n['id']);
        }
      }
    });
    widget.onOpen(target);
  }

  Widget row(Json n, int depth, bool ancestorMatches) {
    if (!ancestorMatches && !matches(n)) return const SizedBox.shrink();
    final children = navigationChildren(n);
    final group = (n['screen_id'] ?? '') == '';
    final expanded = !collapsed.contains(n['id']) || widget.query.isNotEmpty;
    final selected = containsSelected(n);
    final missing = !group && index[n['screen_id']] == null;
    final colors = Theme.of(context).colorScheme;
    final ownMatch =
        ancestorMatches ||
        n['label'].toString().toLowerCase().contains(widget.query);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(left: depth * 12.0, bottom: 1),
          child: Material(
            color: selected && !group
                ? colors.primaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(2),
            child: Row(
              children: [
                if (group)
                  SizedBox(
                    width: 30,
                    child: IconButton(
                      key: Key('navigation-toggle-${n['id']}'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 34,
                      ),
                      color: selected
                          ? colors.primary
                          : colors.onSurfaceVariant,
                      tooltip: expanded ? '折叠菜单' : '展开菜单',
                      iconSize: 18,
                      onPressed: () => setState(
                        () => expanded
                            ? collapsed.add(n['id'] as String)
                            : collapsed.remove(n['id']),
                      ),
                      icon: Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                      ),
                    ),
                  )
                else
                  const SizedBox(width: 14),
                Expanded(
                  child: InkWell(
                    key: Key('navigation-open-${n['id']}'),
                    onTap: () => open(n),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 8,
                        horizontal: 6,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            missing
                                ? Icons.broken_image_outlined
                                : group
                                ? Icons.folder_open
                                : Icons.account_tree_outlined,
                            size: 16,
                            color: missing
                                ? Colors.orange
                                : selected
                                ? colors.primary
                                : colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              '${n['label']}${missing ? ' · 画面已失效' : ''}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: selected
                                    ? colors.onPrimaryContainer
                                    : colors.onSurface,
                                fontWeight: selected || group
                                    ? FontWeight.w600
                                    : FontWeight.normal,
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
        if (group && expanded) ...[
          if (children.isEmpty)
            Padding(
              padding: EdgeInsets.only(left: depth * 12.0 + 36, bottom: 8),
              child: const Text(
                '暂无画面',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          for (final child in children) row(child, depth + 1, ownMatch),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    children: [
      if (widget.nodes.isEmpty)
        const Padding(padding: EdgeInsets.all(16), child: Text('尚未配置菜单')),
      for (final n in widget.nodes) row(n, 0, false),
    ],
  );
}

Future<bool?> editPageNavigation(
  BuildContext context,
  PlatformApi api,
  List<Json> screens,
) => showDialog<bool>(
  context: context,
  builder: (_) => PageNavigationEditor(api: api, screens: screens),
);

class PageNavigationEditor extends StatefulWidget {
  const PageNavigationEditor({
    super.key,
    required this.api,
    required this.screens,
    this.readFile = pickProcessFile,
    this.writeFile = saveFile,
  });
  final Future<ProcessFile?> Function({required bool image, String? jsonLabel})
  readFile;
  final Future<bool> Function(Uint8List, String) writeFile;
  final PlatformApi api;
  final List<Json> screens;
  @override
  State<PageNavigationEditor> createState() => _PageNavigationEditorState();
}

class _PageNavigationEditorState extends State<PageNavigationEditor> {
  List<Json> nodes = [];
  int revision = 0;
  bool loading = true, saving = false, enabled = false;
  bool loaded = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final c = await widget.api.request('GET', '/api/v1/navigation');
      if (!mounted) return;
      setState(() {
        nodes = objects(jsonDecode(jsonEncode(c['nodes'] ?? [])));
        revision = c['revision'] as int? ?? 0;
        enabled = c['enabled'] == true;
        if (revision == 0 && nodes.isEmpty) {
          final scopes =
              widget.screens.map((s) => s['station'] as String).toSet().toList()
                ..sort();
          nodes = [
            for (final scope in scopes)
              {
                'id': screenIdentity(),
                'label': scope.isEmpty ? '公共画面' : scope,
                'children': <Json>[
                  for (final s in widget.screens.where(
                    (s) => s['station'] == scope,
                  ))
                    {
                      'id': screenIdentity(),
                      'label': s['name'],
                      'screen_id': s['id'],
                    },
                ],
              },
          ];
        }
        loading = false;
        loaded = true;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    }
  }

  List<Json>? parentOf(String id, List<Json> items) {
    if (items.any((n) => n['id'] == id)) return items;
    for (final n in items) {
      final found = parentOf(id, (n['children'] as List?)?.cast<Json>() ?? []);
      if (found != null) return found;
    }
    return null;
  }

  void move(Json n, int delta) {
    final list = parentOf(n['id'] as String, nodes)!;
    final i = list.indexWhere((v) => v['id'] == n['id']);
    if (i + delta < 0 || i + delta >= list.length) return;
    setState(() {
      final item = list.removeAt(i);
      list.insert(i + delta, item);
    });
  }

  Future<void> edit({Json? node, required bool group}) async {
    final name = TextEditingController(text: node?['label'] as String? ?? '');
    var target = node?['screen_id'] as String? ?? '';
    var parent = '';
    for (final n in navigationWalk(nodes)) {
      if (navigationChildren(n).any((c) => c['id'] == node?['id'])) {
        parent = n['id'] as String;
      }
    }
    final excluded = node == null
        ? <String>{}
        : navigationWalk([node]).map((n) => n['id'] as String).toSet();
    final groups = navigationWalk(nodes)
        .where(
          (n) => (n['screen_id'] ?? '') == '' && !excluded.contains(n['id']),
        )
        .toList();
    String? failure;
    final result = await showDialog<Json>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(group ? '菜单分组' : '画面菜单项'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 12,
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
                          child: Text(
                            n['label'] as String,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => update(() => parent = v!),
                  ),
                  if (!group)
                    DropdownButtonFormField<String>(
                      initialValue: target,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '目标画面（归属站点 / 名称）',
                      ),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('请选择画面')),
                        if (target.isNotEmpty &&
                            !widget.screens.any((s) => s['id'] == target))
                          DropdownMenuItem(
                            value: target,
                            child: Text('画面已失效：$target'),
                          ),
                        for (final s in widget.screens)
                          DropdownMenuItem(
                            value: s['id'] as String,
                            child: Text(
                              '${s['station'] == '' ? '公共' : s['station']} / ${s['name']}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => update(() {
                        target = v!;
                        if (name.text.trim().isEmpty && target.isNotEmpty) {
                          name.text =
                              widget.screens.firstWhere(
                                    (s) => s['id'] == target,
                                  )['name']
                                  as String;
                        }
                      }),
                    ),
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
                if (name.text.trim().isEmpty || (!group && target.isEmpty)) {
                  update(() => failure = '请填写名称并选择目标画面');
                  return;
                }
                Navigator.pop(dialog, <String, dynamic>{
                  'parent': parent,
                  'label': name.text.trim(),
                  'screen_id': group ? '' : target,
                });
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    if (!mounted || result == null) return;
    setState(() {
      final next = <String, dynamic>{
        'id': node?['id'] ?? screenIdentity(),
        'label': result['label'],
        if (!group) 'screen_id': result['screen_id'],
        if (group) 'children': node?['children'] ?? <Json>[],
      };
      final oldList = node == null
          ? null
          : parentOf(node['id'] as String, nodes);
      final oldIndex = oldList?.indexWhere((n) => n['id'] == node!['id']) ?? -1;
      List<Json> destination;
      if (result['parent'] == '') {
        destination = nodes;
      } else {
        final p = navigationWalk(
          nodes,
        ).firstWhere((n) => n['id'] == result['parent']);
        destination = (p.putIfAbsent('children', () => <Json>[]) as List)
            .cast<Json>();
      }
      final sameParent =
          oldList != null &&
          oldList.any((n) => n['id'] == next['id']) &&
          destination.any((n) => n['id'] == next['id']);
      oldList?.removeWhere((n) => n['id'] == next['id']);
      if (sameParent) {
        destination.insert(oldIndex, next);
      } else {
        destination.add(next);
      }
    });
  }

  Future<void> transferMenu(bool importing) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      if (!importing) {
        final bytes = utf8.encode(
          const JsonEncoder.withIndent('  ').convert({
            'format': 'universal-hmi-page-navigation',
            'version': 1,
            'enabled': enabled,
            'nodes': nodes,
          }),
        );
        if (await widget.writeFile(bytes, '页面导航配置.json') && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('已导出菜单 JSON')));
        }
        return;
      }
      final file = await widget.readFile(
        image: false,
        jsonLabel: '页面导航配置 JSON',
      );
      if (file == null || !mounted) return;
      final menu = decodeNavigationFile(file.bytes);
      final imported = (menu['nodes'] as List).cast<Json>();
      final targets = {for (final s in widget.screens) s['id']: s};
      final missing = navigationWalk(imported)
          .where(
            (n) =>
                (n['screen_id'] ?? '') != '' &&
                !targets.containsKey(n['screen_id']),
          )
          .length;
      List<Widget> preview(List<Json> items, int depth) => [
        for (final n in items) ...[
          Padding(
            padding: EdgeInsets.only(left: depth * 14.0),
            child: Text(
              [
                n['label'],
                if ((n['screen_id'] ?? '') != '')
                  targets[n['screen_id']]?['name'] ?? '目标不存在或无权访问',
              ].join(' · '),
            ),
          ),
          ...preview(navigationChildren(n), depth + 1),
        ],
      ];
      final apply = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('预览导入页面导航'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '共 ${navigationWalk(imported).length} 项 · 自定义菜单${menu['enabled'] ? '启用' : '关闭'}',
                  ),
                  Text(
                    missing == 0
                        ? '导入将替换当前草稿，点击「保存菜单」后生效。'
                        : '有 $missing 项目标不存在或无权访问，请核对当前工程。',
                  ),
                  const SizedBox(height: 8),
                  ...preview(imported, 0),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: missing > 0 ? null : () => Navigator.pop(dialog, true),
              child: const Text('替换菜单草稿'),
            ),
          ],
        ),
      );
      if (apply == true && mounted) {
        setState(() {
          nodes = imported;
          enabled = menu['enabled'] as bool;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.api.request(
        'PUT',
        '/api/v1/navigation',
        body: {'revision': revision, 'enabled': enabled, 'nodes': nodes},
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = e.toString();
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
            (n['screen_id'] ?? '') == ''
                ? Icons.folder_outlined
                : Icons.description_outlined,
            size: 18,
          ),
          title: Text(n['label'] as String, overflow: TextOverflow.ellipsis),
          subtitle: (n['screen_id'] ?? '') == ''
              ? null
              : Text(
                  widget.screens
                          .where((s) => s['id'] == n['screen_id'])
                          .map(
                            (s) =>
                                '${s['station'] == '' ? '公共' : s['station']} / ${s['name']}',
                          )
                          .firstOrNull ??
                      '目标画面已失效',
                  overflow: TextOverflow.ellipsis,
                ),
          onTap: saving
              ? null
              : () => edit(node: n, group: (n['screen_id'] ?? '') == ''),
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
      ...rows(navigationChildren(n), depth + 1),
    ],
  ];
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('页面导航配置'),
    content: SizedBox(
      width: 720,
      height: 500,
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用自定义菜单'),
                    subtitle: const Text('关闭时按站点生成；分组不改变画面和变量归属。'),
                    value: enabled,
                    onChanged: saving
                        ? null
                        : (v) => setState(() => enabled = v),
                  ),
                  const Text(
                    '点击组名展开并打开第一张有效画面；箭头仅展开/收起。最多4层、256项。',
                    style: TextStyle(fontSize: 12),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final importing in [true, false])
                        OutlinedButton.icon(
                          onPressed: !loaded || saving
                              ? null
                              : () => transferMenu(importing),
                          icon: Icon(
                            importing
                                ? Icons.file_open_outlined
                                : Icons.save_alt,
                            size: 17,
                          ),
                          label: Text(importing ? '导入菜单' : '导出菜单'),
                        ),
                      OutlinedButton.icon(
                        onPressed: saving ? null : () => edit(group: true),
                        icon: const Icon(
                          Icons.create_new_folder_outlined,
                          size: 17,
                        ),
                        label: const Text('添加分组'),
                      ),
                      OutlinedButton.icon(
                        onPressed: saving ? null : () => edit(group: false),
                        icon: const Icon(Icons.add, size: 17),
                        label: const Text('添加画面'),
                      ),
                    ],
                  ),
                  ...rows(nodes, 0),
                  if (error != null)
                    SelectableText(
                      error!,
                      style: const TextStyle(color: Colors.red),
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
        onPressed: !loaded || loading || saving ? null : save,
        child: Text(saving ? '正在保存…' : '保存菜单'),
      ),
    ],
  );
}
