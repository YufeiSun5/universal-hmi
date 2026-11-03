import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../platform/process_files.dart';
import '../../platform/save.dart';
import '../../shared/desktop_dialog.dart';
import 'gis_station_transfer.dart';
import '../../shared/transfer_rows.dart';
import '../../platform/gis_view.dart';
import '../../shared/api.dart';
import 'model.dart';
import 'gis_bindings.dart';
import 'diagram.dart';
import 'subscriptions.dart';

List<Json> gisFields(Json? section) => section?['fields'] is List
    ? [
        for (final field in objects(section?['fields'])) {...field},
      ]
    : [
        for (final entry in gisMetrics.entries)
          {'id': entry.key, 'name': entry.value},
      ];

List<Widget> gisBindingFields(
  BuildContext dialog,
  StateSetter update,
  Json bindings,
  Map<String, Json> definitions,
  List<Json> fields,
) => [
  for (var i = 0; i < fields.length; i++)
    Container(
      key: ValueKey(fields[i]['id']),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: DesktopDialogStyle.line),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            initialValue: fields[i]['name'] as String,
            decoration: const InputDecoration(
              labelText: '信息名称',
              counterText: '',
            ),
            maxLength: 80,
            validator: (v) => GisStationFile.validName(v) ? null : '请输入有效信息名称',
            onChanged: (v) => fields[i]['name'] = v.trim(),
          ),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.link, size: 20),
            title: Text(
              bindings[fields[i]['id']] == null
                  ? '选择变量'
                  : definitions[bindings[fields[i]['id']]] == null
                  ? '变量已不可用，请重新绑定'
                  : '${definitions[bindings[fields[i]['id']]]!['station']} / ${definitions[bindings[fields[i]['id']]]!['name']}',
              style: const TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              bindings[fields[i]['id']] == null ? '尚未绑定' : '点击更换变量',
            ),
            trailing: bindings[fields[i]['id']] == null
                ? const Icon(Icons.chevron_right, size: 20)
                : IconButton(
                    tooltip: '清除绑定',
                    icon: const Icon(Icons.link_off, size: 20),
                    onPressed: () =>
                        update(() => bindings.remove(fields[i]['id'])),
                  ),
            onTap: () async {
              final id = await showDialog<String>(
                context: dialog,
                builder: (_) => GisPointPicker(definitions: definitions),
              );
              if (id != null && dialog.mounted) {
                update(() => bindings[fields[i]['id']] = id);
              }
            },
          ),
          Wrap(
            spacing: 8,
            children: [
              Tooltip(
                message: '上移信息',
                child: TextButton.icon(
                  onPressed: i == 0
                      ? null
                      : () => update(() {
                          final field = fields.removeAt(i);
                          fields.insert(i - 1, field);
                        }),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  label: const Text('上移信息'),
                ),
              ),
              Tooltip(
                message: '下移信息',
                child: TextButton.icon(
                  onPressed: i == fields.length - 1
                      ? null
                      : () => update(() {
                          final field = fields.removeAt(i);
                          fields.insert(i + 1, field);
                        }),
                  icon: const Icon(Icons.arrow_downward, size: 18),
                  label: const Text('下移信息'),
                ),
              ),
              Tooltip(
                message: '删除信息',
                child: TextButton.icon(
                  onPressed: () => update(() {
                    bindings.remove(fields[i]['id']);
                    fields.removeAt(i);
                  }),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('删除信息'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  TextButton.icon(
    onPressed: fields.length >= 32
        ? null
        : () =>
              update(() => fields.add({'id': screenIdentity(), 'name': '新信息'})),
    icon: const Icon(Icons.add, size: 18),
    label: const Text('添加信息'),
  ),
  if (fields.isEmpty) const Text('未配置展示信息'),
];

ThemeData gisEditorTheme(ThemeData base) => base.copyWith(
  visualDensity: VisualDensity.standard,
  inputDecorationTheme: InputDecorationTheme(
    isDense: false,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: DesktopDialogStyle.line),
    ),
    floatingLabelBehavior: FloatingLabelBehavior.always,
    labelStyle: const TextStyle(fontSize: 14),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(minimumSize: const Size(64, 44)),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
  ),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
  ),
);

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

  Future<void> transferStations(bool importing) async {
    if (!widget.editing ||
        !widget.canWrite ||
        preview ||
        saving ||
        dialogOpen) {
      return;
    }
    final current = draft!;
    final config = current.config;
    final rows = objects(config?['stations']);
    setState(() => dialogOpen = true);
    try {
      List<Json> candidates = rows;
      final issues = <String, String>{};
      final existing = {for (final row in rows) row['id']: row};
      if (importing) {
        final picked = await pickProcessFile(
          image: false,
          jsonLabel: 'GIS 站点列表 JSON',
        );
        if (picked == null || !mounted) return;
        candidates = GisStationListFile.decode(picked.bytes);
        final targets = <String, bool>{};
        for (final row in candidates) {
          final id = row['id'] as String;
          final file = GisStationFile.fromStation(row);
          final missing = {
            ...file.pointIDs('common'),
            ...file.pointIDs('zones'),
          }.where((p) => !widget.definitions.containsKey(p)).length;
          if (missing > 0) {
            issues[id] = '缺少 $missing 个引用变量';
            continue;
          }
          if (rows.any((r) => r['name'] == row['name'] && r['id'] != id)) {
            issues[id] = '当前画面有同名、不同标识的站点，请核对';
            continue;
          }
          final target = row['target_screen_id'] as String;
          if (target.isNotEmpty) {
            if (!targets.containsKey(target)) {
              try {
                final screen = await widget.api.request(
                  'GET',
                  '/api/v1/screens/$target',
                );
                targets[target] =
                    screen['id'] == target && screen['kind'] != 'gis';
              } catch (_) {
                targets[target] = false;
              }
            }
            if (targets[target] != true) issues[id] = '跳转画面不可用，请核对';
          }
        }
      }
      if (!mounted || draft != current) return;
      final chosen = await selectTransferRows(
        context,
        rows: candidates,
        title: importing ? '预览导入 GIS 站点' : '导出 GIS 站点',
        description: importing
            ? '按标识更新或新增所选站点，其他站点保留。确认后仍需保存画面。'
            : '包含所选站点的坐标、跳转画面、公共数据与分区绑定。',
        action: importing ? '合并到草稿' : '导出 JSON',
        issues: issues,
        label: (r) => r['name'] as String,
        detail: (r) =>
            "${importing ? (existing.containsKey(r['id']) ? '更新 · ' : '新增 · ') : ''}${r['id']} · ${r['longitude']}, ${r['latitude']}",
      );
      if (chosen == null || !mounted || draft != current) return;
      if (importing) {
        if (!identical(current.config, config)) {
          throw const FormatException('地图草稿已变更，请重新预览');
        }
        change({
          ...?config,
          'stations': GisStationListFile.merge(rows, chosen),
        });
      } else {
        final saved = await saveFile(
          GisStationListFile.encode(chosen),
          'gis-stations.json',
        );
        if (saved && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(kIsWeb ? '已发起站点列表下载' : '已导出所选站点')),
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = '${importing ? "导入" : "导出"}站点失败：$e');
    } finally {
      if (mounted) setState(() => dialogOpen = false);
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
    if (targetScreenID.isNotEmpty) {
      try {
        final target = await widget.api.request(
          'GET',
          '/api/v1/screens/$targetScreenID',
        );
        targetLabel = target['kind'] == 'gis'
            ? '目标画面不可用，请重新选择'
            : '${target['station'] == '' ? '公共' : target['station']} / ${target['name']}';
      } catch (_) {
        targetLabel = '目标画面暂不可用，请检查或重新选择';
      }
      if (!mounted) return;
    }
    final bindings = Map<String, dynamic>.from(
      existing?['bindings'] as Map? ?? {},
    );
    final fields = gisFields(existing);
    final zones = [
      for (final zone in objects(existing?['zones']))
        <String, dynamic>{
          ...zone,
          'fields': gisFields(zone),
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
    var formVersion = 0;
    bool transferring = false;
    String? transferNotice;
    final sectionKeys = List.generate(3, (_) => GlobalKey());
    Json stationDraft() => <String, dynamic>{
      ...?existing,
      'id': existing?['id'] ?? screenIdentity(),
      'name': name.text.trim(),
      'longitude': double.tryParse(lon.text),
      'latitude': double.tryParse(lat.text),
      'target_screen_id': targetScreenID,
      'fields': fields,
      'bindings': bindings,
      'zones': zones,
    };
    Future<void> transfer(
      BuildContext dialog,
      StateSetter update,
      bool importing,
    ) async {
      if (transferring) return;
      if (!importing && !form.currentState!.validate()) return;
      update(() {
        transferring = true;
        transferNotice = null;
      });
      try {
        final currentFile = GisStationFile.fromStation(stationDraft());
        GisStationFile file;
        final issues = <String, String>{};
        if (importing) {
          final picked = await pickProcessFile(
            image: false,
            jsonLabel: 'GIS 站点配置 JSON',
          );
          if (picked == null || !dialog.mounted) return;
          file = GisStationFile.decode(picked.bytes);
          for (final key in ['common', 'zones']) {
            if (!file.parts.containsKey(key)) continue;
            final missing = file
                .pointIDs(key)
                .where((id) => !widget.definitions.containsKey(id))
                .toList();
            if (missing.isNotEmpty) {
              issues[key] = '${missing.length} 个变量在当前工程不可用，不按同名猜测绑定。';
            }
          }
          final target = file.parts['target'];
          if (target is String && target.isNotEmpty) {
            try {
              final screen = await widget.api.request(
                'GET',
                '/api/v1/screens/$target',
              );
              if (screen['id'] != target || screen['kind'] == 'gis') {
                throw const FormatException('目标不是工艺画面');
              }
            } catch (_) {
              issues['target'] = '当前工程无法访问该工艺画面。';
            }
          }
        } else {
          file = currentFile;
          for (final key in file.parts.keys) {
            file.validatePart(key);
          }
        }
        if (!dialog.mounted) return;
        final selected = await showDialog<Set<String>>(
          context: dialog,
          builder: (_) => GisStationTransferDialog(
            file: file,
            importing: importing,
            issues: issues,
            current: importing ? currentFile : null,
          ),
        );
        if (selected == null || !dialog.mounted) return;
        if (importing) {
          final next = file.apply(stationDraft(), selected);
          update(() {
            name.text = next['name'] as String;
            lon.text = '${next['longitude']}';
            lat.text = '${next['latitude']}';
            targetScreenID = next['target_screen_id'] as String;
            if (selected.contains('target')) {
              targetLabel = targetScreenID.isEmpty
                  ? null
                  : '已导入工艺画面跳转 · 点击查看或更换';
            }
            fields
              ..clear()
              ..addAll(gisFields(next));
            bindings
              ..clear()
              ..addAll(Map<String, dynamic>.from(next['bindings'] as Map));
            zones
              ..clear()
              ..addAll([
                for (final z in objects(next['zones']))
                  <String, dynamic>{
                    ...z,
                    'fields': gisFields(z),
                    'bindings': Map<String, dynamic>.from(
                      z['bindings'] as Map? ?? {},
                    ),
                  },
              ]);
            formVersion++;
            transferNotice = '已替换所选编辑内容；请核对后确定，再保存画面。';
          });
        } else {
          final saved = await saveFile(
            file.encode(selected),
            'gis-station-config.json',
          );
          if (dialog.mounted) {
            update(
              () => transferNotice = saved
                  ? (kIsWeb ? '已发起站点配置下载，请在浏览器中检查。' : '站点配置已导出。')
                  : '已取消导出。',
            );
          }
        }
      } catch (e) {
        if (dialog.mounted) {
          update(() => transferNotice = '${importing ? '导入' : '导出'}失败：$e');
        }
      } finally {
        if (dialog.mounted) update(() => transferring = false);
      }
    }

    final result = await showDialog<Json>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => Theme(
          data: gisEditorTheme(Theme.of(dialog)),
          child: PopScope(
            canPop: !transferring,
            child: AlertDialog(
              shape: DesktopDialogStyle.shape,
              backgroundColor: DesktopDialogStyle.background,
              insetPadding: DesktopDialogStyle.insetPadding,
              title: Text(existing == null ? '添加站点' : '编辑站点'),
              content: SizedBox(
                width: 800,
                height: 560,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: transferring
                              ? null
                              : () => transfer(dialog, update, true),
                          icon: const Icon(Icons.file_open_outlined, size: 18),
                          label: const Text('导入配置'),
                        ),
                        OutlinedButton.icon(
                          onPressed: transferring
                              ? null
                              : () => transfer(dialog, update, false),
                          icon: const Icon(
                            Icons.file_download_outlined,
                            size: 18,
                          ),
                          label: const Text('导出配置'),
                        ),
                        for (
                          var section = 0;
                          section < sectionKeys.length;
                          section++
                        )
                          TextButton(
                            onPressed: transferring
                                ? null
                                : () => Scrollable.ensureVisible(
                                    sectionKeys[section].currentContext!,
                                    duration: const Duration(milliseconds: 180),
                                  ),
                            child: Text(['基本信息', '公共数据', '分区数据'][section]),
                          ),
                      ],
                    ),
                    if (transferNotice != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(transferNotice!),
                      ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: AbsorbPointer(
                        absorbing: transferring,
                        child: SingleChildScrollView(
                          child: Form(
                            key: form,
                            child: Column(
                              key: ValueKey(formVersion),
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  key: sectionKeys[0],
                                  padding: const EdgeInsets.only(bottom: 20),
                                  child: const Text(
                                    '基本信息',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                TextFormField(
                                  controller: name,
                                  decoration: const InputDecoration(
                                    labelText: '站点名称',
                                    counterText: '',
                                  ),
                                  maxLength: 80,
                                  validator: (v) => GisStationFile.validName(v)
                                      ? null
                                      : '请输入有效名称',
                                ),
                                const SizedBox(height: 20),
                                LayoutBuilder(
                                  builder: (context, constraints) => Wrap(
                                    spacing: 16,
                                    runSpacing: 16,
                                    children: [
                                      for (final field in [
                                        (lon, '经度', -180.0, 180.0),
                                        (lat, '纬度', -85.0, 85.0),
                                      ])
                                        SizedBox(
                                          width: constraints.maxWidth >= 500
                                              ? (constraints.maxWidth - 16) / 2
                                              : constraints.maxWidth,
                                          child: TextFormField(
                                            controller: field.$1,
                                            decoration: InputDecoration(
                                              labelText: field.$2,
                                            ),
                                            keyboardType:
                                                const TextInputType.numberWithOptions(
                                                  decimal: true,
                                                  signed: true,
                                                ),
                                            validator: (v) {
                                              final n = double.tryParse(
                                                v ?? '',
                                              );
                                              return n == null ||
                                                      !n.isFinite ||
                                                      n < field.$3 ||
                                                      n > field.$4
                                                  ? '请输入 ${field.$3} 至 ${field.$4} 的坐标'
                                                  : null;
                                            },
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                const Divider(),
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('点击图标跳转到工艺画面'),
                                  subtitle: Text(
                                    targetLabel ??
                                        (targetScreenID.isEmpty
                                            ? '未设置 · 点击选择画面'
                                            : '已设置工艺画面 · 点击查看或更换'),
                                  ),
                                  trailing: targetScreenID.isEmpty
                                      ? const Icon(Icons.open_in_new, size: 18)
                                      : IconButton(
                                          tooltip: '取消画面跳转',
                                          icon: const Icon(
                                            Icons.link_off,
                                            size: 18,
                                          ),
                                          onPressed: () => update(() {
                                            targetScreenID = '';
                                            targetLabel = null;
                                          }),
                                        ),
                                  onTap: () async {
                                    final selected = await showDialog<Json>(
                                      context: dialog,
                                      builder: (_) =>
                                          GisScreenPicker(api: widget.api),
                                    );
                                    if (selected != null && dialog.mounted) {
                                      update(() {
                                        targetScreenID =
                                            selected['id'] as String;
                                        targetLabel =
                                            '${selected['station'] == '' ? '公共' : selected['station']} / ${selected['name']}';
                                      });
                                    }
                                  },
                                ),
                                const Divider(),
                                Align(
                                  key: sectionKeys[1],
                                  alignment: Alignment.centerLeft,
                                  child: const Text(
                                    '站公共数据',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  '添加要显示的信息，再选择对应变量。删除信息不会删除变量。',
                                  style: TextStyle(fontSize: 13),
                                ),

                                const SizedBox(height: 16),
                                ...gisBindingFields(
                                  dialog,
                                  update,
                                  bindings,
                                  widget.definitions,
                                  fields,
                                ),
                                const Divider(height: 32),
                                Row(
                                  key: sectionKeys[2],
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        '分区数据 · 按下方顺序展示',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: zones.length >= 16
                                          ? null
                                          : () => update(
                                              () => zones.add({
                                                'id': screenIdentity(),
                                                'name':
                                                    '分区 ${zones.length + 1}',
                                                'fields': <Json>[],
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
                                    margin: const EdgeInsets.symmetric(
                                      vertical: 4,
                                    ),
                                    child: ExpansionTile(
                                      title: Text(
                                        '${i + 1}. ${zones[i]['name']}',
                                      ),
                                      subtitle: Text(
                                        '已绑定 ${(zones[i]['bindings'] as Map).length} 项',
                                      ),
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.all(16),
                                          child: Column(
                                            children: [
                                              TextFormField(
                                                initialValue:
                                                    zones[i]['name'] as String,
                                                decoration:
                                                    const InputDecoration(
                                                      labelText: '分区名称',
                                                      counterText: '',
                                                    ),
                                                maxLength: 80,
                                                validator: (v) =>
                                                    v == null ||
                                                        v.trim().isEmpty
                                                    ? '请输入分区名称'
                                                    : null,
                                                onChanged: (v) => update(
                                                  () => zones[i]['name'] = v
                                                      .trim(),
                                                ),
                                              ),
                                              Wrap(
                                                spacing: 8,
                                                children: [
                                                  TextButton.icon(
                                                    onPressed: i == 0
                                                        ? null
                                                        : () => update(() {
                                                            final zone = zones
                                                                .removeAt(i);
                                                            zones.insert(
                                                              i - 1,
                                                              zone,
                                                            );
                                                          }),
                                                    icon: const Icon(
                                                      Icons.arrow_upward,
                                                      size: 16,
                                                    ),
                                                    label: const Text('上移'),
                                                  ),
                                                  TextButton.icon(
                                                    onPressed:
                                                        i == zones.length - 1
                                                        ? null
                                                        : () => update(() {
                                                            final zone = zones
                                                                .removeAt(i);
                                                            zones.insert(
                                                              i + 1,
                                                              zone,
                                                            );
                                                          }),
                                                    icon: const Icon(
                                                      Icons.arrow_downward,
                                                      size: 16,
                                                    ),
                                                    label: const Text('下移'),
                                                  ),
                                                  TextButton.icon(
                                                    onPressed: () => update(
                                                      () => zones.removeAt(i),
                                                    ),
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
                                                zones[i]['fields']
                                                    as List<Json>,
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
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: transferring ? null : () => Navigator.pop(dialog),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: transferring
                      ? null
                      : () {
                          if (!form.currentState!.validate()) return;
                          Navigator.pop(dialog, <String, dynamic>{
                            ...?existing,
                            'id': existing?['id'] ?? screenIdentity(),
                            'name': name.text.trim(),
                            'longitude': double.parse(lon.text),
                            'latitude': double.parse(lat.text),
                            'bindings': bindings,
                            'fields': fields,
                            'zones': zones,
                            'target_screen_id': targetScreenID,
                          });
                        },
                  child: const Text('确定'),
                ),
              ],
            ),
          ),
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
                              tooltip: '导入站点',
                              onPressed: editable && !dialogOpen
                                  ? () => transferStations(true)
                                  : null,
                              icon: const Icon(Icons.file_open, size: 18),
                            ),
                            IconButton(
                              tooltip: '导出站点',
                              onPressed:
                                  editable && !dialogOpen && rows.isNotEmpty
                                  ? () => transferStations(false)
                                  : null,
                              icon: const Icon(Icons.save_alt, size: 18),
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
