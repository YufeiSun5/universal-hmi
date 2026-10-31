import 'package:flutter/material.dart';
import '../../platform/gis_view.dart';
import '../../shared/api.dart';
import 'model.dart';
import 'gis_bindings.dart';
import 'diagram.dart';
import 'subscriptions.dart';

List<Widget> gisBindingFields(
  BuildContext dialog,
  StateSetter update,
  Json bindings,
  Map<String, Json> definitions,
) => [
  for (final metric in gisMetrics.entries)
    ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(metric.value, style: const TextStyle(fontSize: 12)),
      subtitle: Text(
        bindings[metric.key] == null
            ? '未绑定 · 点击选择变量'
            : definitions[bindings[metric.key]] == null
            ? '变量已缺失：${bindings[metric.key]}'
            : '${definitions[bindings[metric.key]]!['station']} / ${definitions[bindings[metric.key]]!['name']} · ${bindings[metric.key]}',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: bindings[metric.key] == null
          ? const Icon(Icons.link, size: 18)
          : IconButton(
              tooltip: '清除${metric.value}绑定',
              icon: const Icon(Icons.link_off, size: 18),
              onPressed: () => update(() => bindings.remove(metric.key)),
            ),
      onTap: () async {
        final id = await showDialog<String>(
          context: dialog,
          builder: (_) => GisPointPicker(definitions: definitions),
        );
        if (id != null && dialog.mounted) {
          update(() => bindings[metric.key] = id);
        }
      },
    ),
];

class GisDraft {
  GisDraft(this.document);
  Json document;
  Json? loadedConfig;
  bool dirty = false;
  bool saving = false;
  bool preview = false;
  String? saveError;
  Json? get config => document['gis'] as Json? ?? loadedConfig;
}

class GisScreenPicker extends StatefulWidget {
  const GisScreenPicker({super.key, required this.api});
  final PlatformApi api;
  @override
  State<GisScreenPicker> createState() => _GisScreenPickerState();
}

class _GisScreenPickerState extends State<GisScreenPicker> {
  List<Json>? screens;
  String query = '';
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.api.request(
        'GET',
        '/api/v1/screens',
        query: {'all': true},
      );
      if (mounted) {
        setState(
          () => screens = objects(
            result['items'],
          ).where((s) => s['kind'] != 'gis').toList(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('选择目标工艺画面'),
    content: SizedBox(
      width: 520,
      height: 360,
      child: Column(
        children: [
          TextField(
            autofocus: true,
            decoration: const InputDecoration(labelText: '搜索站点 / 画面'),
            onChanged: (v) => setState(() => query = v.trim().toLowerCase()),
          ),
          if (error != null)
            TextButton(onPressed: load, child: Text('$error · 重试')),
          Expanded(
            child: screens == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: [
                      if (screens!.isEmpty)
                        const ListTile(title: Text('尚无已保存的工艺画面')),
                      for (final s in screens!.where(
                        (s) => '${s['station']} ${s['name']}'
                            .toLowerCase()
                            .contains(query),
                      ))
                        ListTile(
                          dense: true,
                          title: Text(s['name'] as String),
                          subtitle: Text(
                            s['station'] == ''
                                ? '公共画面'
                                : s['station'] as String,
                          ),
                          onTap: () => Navigator.pop(context, s),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}

/// The editor owns drafts and authenticated saves. The frame only exchanges
/// bounded presentation configuration and never receives credentials.
class GisScreen extends StatefulWidget {
  const GisScreen({
    super.key,
    required this.api,
    this.summary,
    this.editing = false,
    this.canWrite = false,
    this.drafts,
    this.onSaved,
    this.onChanged,
    this.onOpenScreen,
    this.onSubscriptionChanged,
    this.definitions = const {},
    this.live = const {},
    this.online = false,
  });
  final PlatformApi api;
  final Json? summary;
  final bool editing, canWrite;
  final Map<String, GisDraft>? drafts;
  final ValueChanged<Json>? onSaved;
  final VoidCallback? onChanged;
  final ValueChanged<Json>? onOpenScreen;
  final ValueChanged<Set<String>>? onSubscriptionChanged;
  final Map<String, Json> definitions, live;
  final bool online;
  @override
  State<GisScreen> createState() => _GisScreenState();
}

class _GisScreenState extends State<GisScreen> {
  GisDraft? draft;
  String? error;
  bool get preview => draft?.preview ?? false;
  bool dialogOpen = false;
  bool opening = false;

  Future<void> openStation(String id) async {
    if (opening || dialogOpen || (widget.editing && !preview)) return;
    final row = objects(
      draft?.config?['stations'],
    ).where((r) => r['id'] == id).firstOrNull;
    final target = row?['target_screen_id'] as String? ?? '';
    if (target.isEmpty) return;
    opening = true;
    try {
      final data = await widget.api.request('GET', '/api/v1/screens/$target');
      if (!mounted) return;
      if (data['id'] != target || data['kind'] == 'gis') {
        throw const FormatException('目标不是工艺画面');
      }
      if (!widget.editing && widget.onOpenScreen != null) {
        widget.onOpenScreen!(data);
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialog) => Dialog(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('${data['station']} / ${data['name']}'),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭画面预览',
                    onPressed: () => Navigator.pop(dialog),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Expanded(
                child: ProcessDiagram(
                  document: ScreenDocument.fromJson(data),
                  definitions: widget.definitions,
                  live: widget.live,
                  online: widget.online,
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法打开目标工艺画面，请检查跳转配置：$e')));
      }
    } finally {
      opening = false;
    }
  }

  bool get saving => draft?.saving ?? false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      var summary = widget.summary;
      if ((summary?['id'] ?? '') == '') {
        final items = objects(
          (await widget.api.request(
            'GET',
            '/api/v1/screens',
            query: {'station': ''},
          ))['items'],
        );
        summary = items.where((d) => d['kind'] == 'gis').firstOrNull;
      }
      final id = summary?['id'] as String? ?? '';
      final cached = widget.editing ? (widget.drafts?[id]) : null;
      final next =
          cached ??
          GisDraft(
            id.isEmpty
                ? ScreenDocument(
                    id: screenIdentity(),
                    name: '首页 GIS',
                    station: '',
                    kind: 'gis',
                  ).toJson()
                : await widget.api.request('GET', '/api/v1/screens/$id'),
          );
      if (next.document['kind'] != 'gis') {
        throw const FormatException('画面类型不是 GIS');
      }
      if (!mounted) return;
      if (widget.editing) widget.drafts?[id] = next;
      setState(() {
        draft = next;
        error = next.saveError;
      });
      widget.onSubscriptionChanged?.call(gisSubscriptionIDs(next.config));
    } catch (e) {
      if (mounted) setState(() => error = '地图读取失败：$e');
    }
  }

  void change(Json config) {
    if (!widget.editing || !widget.canWrite || preview || saving) return;
    setState(() {
      draft!.document = {...draft!.document, 'gis': config};
      draft!.dirty = true;
      draft!.saveError = null;
      error = null;
    });
    widget.onChanged?.call();
  }

  Future<void> save() async {
    final current = draft!;
    if (current.saving) return;
    setState(() {
      current.saving = true;
      current.saveError = null;
      error = null;
    });
    try {
      final sent = {
        ...current.document,
        'gis': current.config ?? {'stations': <Json>[]},
      };
      final result = await widget.api.request(
        'PUT',
        '/api/v1/screens/${sent['id']}',
        body: sent,
      );
      current.document = result;
      current.dirty = false;
      current.saving = false;
      if (mounted) setState(() {});
      widget.drafts?[result['id'] as String] = current;
      widget.onSaved?.call(result);
    } catch (e) {
      current.saving = false;
      current.saveError = '保存失败，草稿已保留：$e';
      if (mounted) {
        setState(() {
          error = current.saveError;
        });
      }
      widget.onChanged?.call();
    }
  }

  Future<void> editStation([Json? existing]) async {
    if (!widget.editing ||
        !widget.canWrite ||
        preview ||
        saving ||
        dialogOpen) {
      return;
    }
    setState(() => dialogOpen = true);
    var targetScreenID = existing?['target_screen_id'] as String? ?? '';
    String? targetLabel;
    final bindings = Map<String, dynamic>.from(
      existing?['bindings'] as Map? ?? {},
    );
    final zones = [
      for (final zone in objects(existing?['zones']))
        <String, dynamic>{
          ...zone,
          'bindings': Map<String, dynamic>.from(zone['bindings'] as Map? ?? {}),
        },
    ];
    final name = TextEditingController(
      text: existing?['name'] as String? ?? '',
    );
    final lon = TextEditingController(
      text: '${existing?['longitude'] ?? 122.967}',
    );
    final lat = TextEditingController(text: '${existing?['latitude'] ?? 39.7}');
    final form = GlobalKey<FormState>();
    final result = await showDialog<Json>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: Text(existing == null ? '添加站点' : '编辑站点'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: name,
                      decoration: const InputDecoration(labelText: '站点名称'),
                      maxLength: 80,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? '请输入名称' : null,
                    ),
                    const SizedBox(height: 12),
                    for (final field in [
                      (lon, '经度', -180.0, 180.0),
                      (lat, '纬度', -85.0, 85.0),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: TextFormField(
                          controller: field.$1,
                          decoration: InputDecoration(labelText: field.$2),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          validator: (v) {
                            final n = double.tryParse(v ?? '');
                            return n == null ||
                                    !n.isFinite ||
                                    n < field.$3 ||
                                    n > field.$4
                                ? '请输入 ${field.$3} 至 ${field.$4} 的坐标'
                                : null;
                          },
                        ),
                      ),
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('点击图标跳转到工艺画面'),
                      subtitle: Text(
                        targetLabel ??
                            (targetScreenID.isEmpty
                                ? '未设置 · 点击选择画面'
                                : '已设置：$targetScreenID'),
                      ),
                      trailing: targetScreenID.isEmpty
                          ? const Icon(Icons.open_in_new, size: 18)
                          : IconButton(
                              tooltip: '取消画面跳转',
                              icon: const Icon(Icons.link_off, size: 18),
                              onPressed: () => update(() {
                                targetScreenID = '';
                                targetLabel = null;
                              }),
                            ),
                      onTap: () async {
                        final selected = await showDialog<Json>(
                          context: dialog,
                          builder: (_) => GisScreenPicker(api: widget.api),
                        );
                        if (selected != null && dialog.mounted) {
                          update(() {
                            targetScreenID = selected['id'] as String;
                            targetLabel =
                                '${selected['station'] == '' ? '公共' : selected['station']} / ${selected['name']}';
                          });
                        }
                      },
                    ),
                    const Divider(),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '站公共数据',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '从集中变量库选择；按变量 ID 引用，不复制变量。',
                      style: TextStyle(fontSize: 11),
                    ),

                    ...gisBindingFields(
                      dialog,
                      update,
                      bindings,
                      widget.definitions,
                    ),
                    const Divider(),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '分区数据 · 按下方顺序展示',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: zones.length >= 16
                              ? null
                              : () => update(
                                  () => zones.add({
                                    'id': screenIdentity(),
                                    'name': '分区 ${zones.length + 1}',
                                    'bindings': <String, dynamic>{},
                                  }),
                                ),
                          icon: const Icon(Icons.add, size: 17),
                          label: const Text('添加分区'),
                        ),
                      ],
                    ),
                    if (zones.isEmpty)
                      const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('尚无分区，可添加单区或多个分区。'),
                      ),
                    for (var i = 0; i < zones.length; i++)
                      Card(
                        key: ValueKey(zones[i]['id']),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ExpansionTile(
                          title: Text('${i + 1}. ${zones[i]['name']}'),
                          subtitle: Text(
                            '已绑定 ${(zones[i]['bindings'] as Map).length} 项',
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Column(
                                children: [
                                  TextFormField(
                                    initialValue: zones[i]['name'] as String,
                                    decoration: const InputDecoration(
                                      labelText: '分区名称',
                                    ),
                                    maxLength: 80,
                                    validator: (v) =>
                                        v == null || v.trim().isEmpty
                                        ? '请输入分区名称'
                                        : null,
                                    onChanged: (v) =>
                                        zones[i]['name'] = v.trim(),
                                  ),
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      TextButton.icon(
                                        onPressed: i == 0
                                            ? null
                                            : () => update(() {
                                                final zone = zones.removeAt(i);
                                                zones.insert(i - 1, zone);
                                              }),
                                        icon: const Icon(
                                          Icons.arrow_upward,
                                          size: 16,
                                        ),
                                        label: const Text('上移'),
                                      ),
                                      TextButton.icon(
                                        onPressed: i == zones.length - 1
                                            ? null
                                            : () => update(() {
                                                final zone = zones.removeAt(i);
                                                zones.insert(i + 1, zone);
                                              }),
                                        icon: const Icon(
                                          Icons.arrow_downward,
                                          size: 16,
                                        ),
                                        label: const Text('下移'),
                                      ),
                                      TextButton.icon(
                                        onPressed: () =>
                                            update(() => zones.removeAt(i)),
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          size: 16,
                                        ),
                                        label: const Text('删除分区'),
                                      ),
                                    ],
                                  ),
                                  ...gisBindingFields(
                                    dialog,
                                    update,
                                    zones[i]['bindings'] as Json,
                                    widget.definitions,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
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
                if (!form.currentState!.validate()) return;
                Navigator.pop(dialog, <String, dynamic>{
                  ...?existing,
                  'id': existing?['id'] ?? screenIdentity(),
                  'name': name.text.trim(),
                  'longitude': double.parse(lon.text),
                  'latitude': double.parse(lat.text),
                  'bindings': bindings,
                  'zones': zones,
                  'target_screen_id': targetScreenID,
                });
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() => dialogOpen = false);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    lon.dispose();
    lat.dispose();
    if (!mounted || result == null) return;
    final rows = objects(draft!.config?['stations']);
    change({
      'stations': [
        for (final row in rows)
          if (row['id'] == result['id']) result else row,
        if (existing == null) result,
      ],
    });
  }

  @override
  Widget build(BuildContext context) {
    if (draft == null) {
      return Center(
        child: error == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error!),
                  TextButton(
                    onPressed: () {
                      setState(() => error = null);
                      load();
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
      );
    }
    final current = draft!, rows = objects(current.config?['stations']);
    final editable = widget.editing && widget.canWrite && !preview && !saving;
    final map = GisView(
      title: current.document['name'] as String,
      station: current.document['station'] as String,
      editable: editable,
      // Dialogs and popup menus can be opened by any ancestor, not just the
      // station editor. Only the map in the current route may receive input.
      interactive: !dialogOpen && (ModalRoute.isCurrentOf(context) ?? true),
      config: current.config,
      readings: gisReadings(
        current.config,
        widget.definitions,
        widget.live,
        widget.online,
      ),
      onEditStation: (id) {
        final row = rows.where((row) => row['id'] == id).firstOrNull;
        if (row != null) editStation(row);
      },
      onOpenStation: openStation,
      onLoaded: (config) {
        if (!widget.editing) return;
        current.loadedConfig = config;
        if (mounted && widget.editing) setState(() {});
      },
      onChanged: change,
    );
    if (!widget.editing) return map;
    return Column(
      children: [
        SizedBox(
          height: 42,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${current.document['name']}${current.dirty ? ' · 未保存' : ''}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              TextButton.icon(
                onPressed: saving
                    ? null
                    : () => setState(() => current.preview = !preview),
                icon: Icon(
                  preview ? Icons.edit_outlined : Icons.visibility_outlined,
                  size: 17,
                ),
                label: Text(preview ? '返回编辑' : '预览'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: widget.canWrite && current.dirty && !saving
                    ? save
                    : null,
                child: Text(saving ? '保存中…' : '保存画面'),
              ),
              const SizedBox(width: 12),
            ],
          ),
        ),
        if (error != null || current.saveError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              error ?? current.saveError!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        Expanded(
          child: Row(
            children: [
              Expanded(child: map),
              if (!preview)
                SizedBox(
                  width: 230,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '地图站点',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            IconButton(
                              tooltip: '添加站点',
                              onPressed: editable && rows.length < 100
                                  ? editStation
                                  : null,
                              icon: const Icon(Icons.add, size: 18),
                            ),
                          ],
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '按住站点图标拖动位置；单击图标或列表绑定浮窗变量。修改后保存画面。',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final row in rows)
                              ListTile(
                                dense: true,
                                title: Text(
                                  row['name'] as String,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                subtitle: Text(
                                  '${(row['longitude'] as num).toStringAsFixed(5)}, ${(row['latitude'] as num).toStringAsFixed(5)}',
                                  style: const TextStyle(fontSize: 10),
                                ),
                                onTap: editable ? () => editStation(row) : null,
                                trailing: IconButton(
                                  tooltip: '移除站点',
                                  onPressed: editable
                                      ? () => change({
                                          'stations': rows
                                              .where(
                                                (r) => r['id'] != row['id'],
                                              )
                                              .toList(),
                                        })
                                      : null,
                                  icon: const Icon(Icons.close, size: 14),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
