import 'dart:convert';
import 'package:flutter/material.dart';
import 'symbol_artwork.dart';
import '../../platform/process_files.dart';
import '../../platform/save.dart';
import '../../shared/api.dart';
import '../../shared/variable_search.dart';
import '../../shared/theme.dart';
import 'canvas.dart';
import 'pipe_drawing.dart';
import 'arrow_rule_editor.dart';
import 'pipe_flow.dart';
import 'catalog.dart';
import 'controller.dart';
import 'model.dart';
import 'materials.dart';
import 'session.dart';
import 'create_screen.dart';
import 'copy_screen.dart';
import 'background_editor.dart';
import 'bindings_panel.dart';
import 'preview.dart';
import 'diagram.dart';
import 'transfer.dart';
export 'session.dart';

class ProcessWorkspace extends StatefulWidget {
  const ProcessWorkspace({
    super.key,
    required this.api,
    required this.session,
    required this.station,
    required this.definitions,
    required this.live,
    required this.online,
    required this.canWrite,
    this.development = true,
    this.onOpenDevelopment,
    this.stations = const [],
    this.materials,
    this.onOpenScreen,
    this.onCreateDocument,
    this.onDeleted,
    this.onTransferCommitted,
  });
  final PlatformApi api;
  final ProcessMaterialLibrary? materials;
  final ProcessSession session;
  final String station;
  final Map<String, Json> definitions, live;
  final bool online, canWrite, development;
  final VoidCallback? onOpenDevelopment;
  final List<String> stations;
  final ValueChanged<String>? onOpenScreen;
  final void Function(ScreenDocument, bool)? onCreateDocument;
  final VoidCallback? onDeleted;
  final VoidCallback? onTransferCommitted;
  @override
  State<ProcessWorkspace> createState() => _ProcessWorkspaceState();
}

class _ProcessWorkspaceState extends State<ProcessWorkspace> {
  late final readings = ValueNotifier(
    ProcessReadings(widget.definitions, widget.live, widget.online),
  );
  final canvas = GlobalKey<ProcessCanvasState>();
  final propertyCommits = <VoidCallback>{};
  List<ProcessSymbol> symbols = [];
  Map<String, ProcessSymbol> symbolIndex = {};
  String tool = 'select', search = '', category = '全部';
  ProcessSymbol? chosenSymbol;
  ProcessMaterialSummary? chosenMaterial;
  late final ProcessMaterialLibrary materialLibrary;
  bool mine = false;
  bool busy = false, libraryVisible = true, propertiesVisible = true;
  String? message;
  ProcessController get editor => widget.session.controller;
  ScreenDocument get document => editor.document;
  bool get canDevelop => widget.canWrite && widget.development;
  @override
  void initState() {
    super.initState();
    editor.editing = canDevelop;
    libraryVisible = widget.development;
    propertiesVisible = widget.development;
    editor.addListener(changed);
    widget.session.flushPending = commitProperties;
    materialLibrary = widget.materials ?? ProcessMaterialLibrary(widget.api);
    materialLibrary.addListener(changed);
    loadSymbols();
    if (!widget.session.loaded) loadInitial();
    if (widget.session.saveOnOpen) {
      widget.session.saveOnOpen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) save();
      });
    }
  }

  @override
  void dispose() {
    if (widget.session.flushPending == commitProperties) {
      widget.session.flushPending = null;
    }
    readings.dispose();
    editor.removeListener(changed);
    materialLibrary.removeListener(changed);
    if (widget.materials == null) materialLibrary.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ProcessWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A preview lives on a separate dialog route. Notify it after the host build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        readings.value = ProcessReadings(
          widget.definitions,
          widget.live,
          widget.online,
        );
      }
    });
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void commitProperties() {
    for (final commit in propertyCommits.toList()) {
      commit();
    }
  }

  Future<void> loadSymbols() async {
    try {
      final list = await processSymbols;
      if (mounted) {
        setState(() {
          symbols = list;
          symbolIndex = {for (final s in list) s.id: s};
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = '素材库读取失败：$e');
    }
  }

  Future<void> loadInitial() async {
    setState(() => busy = true);
    try {
      await widget.session.ensureLoaded(widget.api);
    } catch (e) {
      if (mounted) setState(() => message = '画面读取失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> save() async {
    if (busy || !canDevelop) return false;
    commitProperties();
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);
    if (!mounted || busy) return false;
    final editMode = editor.editing;
    final snapshot = document;
    widget.session.saving = true;
    setState(() {
      busy = true;
      editor.editing = false;
      message = null;
    });
    try {
      snapshot.checkGeometry();
      final saved = await widget.api.request(
        'PUT',
        '/api/v1/screens/${snapshot.id}',
        body: snapshot.toJson(),
      );
      if (widget.session.disposed) return false;
      final revision = (saved['revision'] as num).toInt();
      editor.saved(revision, snapshot: snapshot);
      final summary = <String, dynamic>{
        'id': snapshot.id,
        'name': snapshot.name,
        'station': snapshot.station,
        'revision': revision,
      };
      widget.session.screens = [
        ...widget.session.screens.where((s) => s['id'] != snapshot.id),
        summary,
      ];
      if (mounted) setState(() => message = '已保存 · 版本 $revision');
      return true;
    } catch (e) {
      if (mounted) setState(() => message = '保存失败：$e；当前修改仍保留');
      return false;
    } finally {
      widget.session.saving = false;
      if (!widget.session.disposed) editor.editing = editMode;
      if (mounted) {
        setState(() {
          busy = false;
          editor.editing = editMode;
        });
      }
    }
  }

  Future<bool> leaveDocument() async {
    commitProperties();
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return false;
    if (!editor.dirty || document.nodes.isEmpty && document.revision == 0) {
      return true;
    }
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('当前画面有未保存的修改'),
        content: const Text('先保存，或放弃当前修改后切换。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('放弃修改'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, canDevelop ? 'save' : 'develop'),
            child: Text(canDevelop ? '保存' : '返回开发页'),
          ),
        ],
      ),
    );
    if (choice == 'develop') widget.onOpenDevelopment?.call();
    return choice == 'discard' || choice == 'save' && await save();
  }

  Future<void> open(String id) async {
    if (!busy && id != document.id && widget.onOpenScreen != null) {
      commitProperties();
      FocusManager.instance.primaryFocus?.unfocus();
      widget.onOpenScreen!(id);
      return;
    }
    if (busy || id == document.id || !await leaveDocument() || !mounted) return;
    setState(() => busy = true);
    try {
      final result = await widget.api.request('GET', '/api/v1/screens/$id');
      if (!mounted) return;
      final next = ScreenDocument.fromJson(result);
      if (next.station != widget.station) {
        throw const FormatException('画面不属于当前站点');
      }
      editor.open(next);
      setState(() {
        tool = 'select';
        message = null;
      });
    } catch (e) {
      if (mounted) setState(() => message = '打开失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool openNewTab(ScreenDocument next, {bool save = false}) {
    if (widget.onCreateDocument == null) return false;
    commitProperties();
    FocusManager.instance.primaryFocus?.unfocus();
    widget.onCreateDocument!(next, save);
    return true;
  }

  Future<void> create() async {
    if (!canDevelop || busy) return;
    if (widget.onCreateDocument == null && !await leaveDocument()) return;
    if (!mounted) return;
    final saved = await addScreen(context, widget.api, widget.station);
    if (saved == null || !mounted) return;
    final next = ScreenDocument.fromJson(saved);
    if (openNewTab(next)) {
      // The document has already been saved by the creation dialog.
      return;
    }
    editor.open(next);
  }

  Future<void> saveCopy() async {
    if (busy || !canDevelop) return;
    commitProperties();
    FocusManager.instance.primaryFocus?.unfocus();
    await Future<void>.delayed(Duration.zero);
    if (!mounted || busy) return;
    final snapshot = document;
    final next = await copyProcessScreen(
      context,
      widget.api,
      snapshot,
      widget.stations,
    );
    if (next == null || !mounted) return;
    if (openNewTab(next)) return;
    // Hosts without document tabs keep the source draft intact as well.
    if (next.station == widget.station) {
      widget.session.screens = [...widget.session.screens, next.toJson()];
    }
    setState(() => message = '已保存副本「${next.name}」；当前源画面修改仍保留');
  }

  void showBindings() => showDialog<void>(
    context: context,
    builder: (dialog) => Dialog(
      child: SizedBox(
        width: 650,
        height: 620,
        child: Column(
          children: [
            Expanded(
              child: ProcessBindingsPanel(
                controller: editor,
                definitions: widget.definitions,
                enabled: canDevelop && !busy,
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('完成 · 返回画面保存'),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> refreshPublicLayout() async {
    if (busy) return;
    commitProperties();
    final previous = document;
    setState(() => busy = true);
    try {
      final next = ScreenDocument.fromJson(
        await widget.api.request('GET', '/api/v1/screens/${previous.id}'),
      );
      if (!mounted) return;
      if (editor.dirty) {
        // Keep this station's unsaved bindings by element and condition meaning.
        final old = {for (final n in previous.nodes) n.id: n};
        final merged = next.copy(
          name: previous.name,
          nodes: [
            for (final n in next.nodes)
              n.update({
                'point_id': old[n.id]?.pointID ?? n.pointID,
                for (final key in ['arrow_visible_rule', 'arrow_motion_rule'])
                  if (n.data[key] != null)
                    key: {
                      ...n.data[key] as Json,
                      'conditions': [
                        for (final c in objects(
                          (n.data[key] as Json)['conditions'],
                        ))
                          {
                            ...c,
                            'point_id':
                                objects(
                                      (old[n.id]?.data[key]
                                          as Json?)?['conditions'],
                                    )
                                    .where(
                                      (o) =>
                                          o['slot'] == c['slot'] &&
                                          o['operator'] == c['operator'] &&
                                          o['value'] == c['value'],
                                    )
                                    .firstOrNull?['point_id'] ??
                                c['point_id'],
                          },
                      ],
                    },
              }),
          ],
        );
        editor.open(next);
        editor.commit(merged);
      } else {
        editor.open(next);
      }
      setState(
        () => message = '已同步公共布局 · 版本 ${next.templateRevision}；请检查新增或变化的绑定位置',
      );
    } catch (e) {
      if (mounted) setState(() => message = '同步失败：$e；当前修改仍保留');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget instanceWorkspace() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Text('${document.station}${editor.dirty ? " *" : ""}'),
            ),
            SizedBox(
              width: 200,
              child: field(
                '本站画面名称',
                document.name,
                editor.rename,
                canDevelop && !busy,
                'screen-name',
              ),
            ),
            FilledButton.icon(
              onPressed: canDevelop && !busy ? save : null,
              icon: const Icon(Icons.save, size: 16),
              label: Text(busy ? '处理中…' : '保存绑定'),
            ),
            IconButton(
              tooltip: '撤销',
              onPressed: !busy && editor.canUndo ? editor.undo : null,
              icon: const Icon(Icons.undo, size: 18),
            ),
            IconButton(
              tooltip: '重做',
              onPressed: !busy && editor.canRedo ? editor.redo : null,
              icon: const Icon(Icons.redo, size: 18),
            ),
            TextButton(
              onPressed: busy ? null : refreshPublicLayout,
              child: const Text('同步公共布局'),
            ),
            TextButton.icon(
              key: const Key('process-copy-screen'),
              onPressed: canDevelop && !busy ? saveCopy : null,
              icon: const Icon(Icons.copy_outlined, size: 16),
              label: const Text('复制工艺图'),
            ),
            if (canDevelop)
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => showProcessTransfer(
                        context,
                        widget.api,
                        station: widget.station,
                        stations: widget.stations,
                        variables: widget.definitions.values.toList(),
                        onCommitted: widget.onTransferCommitted,
                      ),
                icon: const Icon(Icons.import_export, size: 16),
                label: const Text('工艺资料导入 / 导出'),
              ),
            TextButton(
              onPressed: busy || widget.onOpenScreen == null
                  ? null
                  : () => widget.onOpenScreen!(document.templateID),
              child: const Text('编辑公共画面'),
            ),
            IconButton(
              tooltip: '删除本站画面',
              onPressed: canDevelop && !busy ? remove : null,
              icon: const Icon(Icons.delete_outline, size: 18),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          message ??
              '布局同步公共画面 v${document.templateRevision} · 本站只保存变量绑定，公共布局更新会用于所有引用站点。',
          style: const TextStyle(fontSize: 12),
        ),
      ),
      Expanded(
        child: Row(
          children: [
            Expanded(
              child: ProcessDiagram(
                document: document,
                definitions: widget.definitions,
                live: widget.live,
                online: widget.online,
                title: document.name,
              ),
            ),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 350,
              child: ProcessBindingsPanel(
                controller: editor,
                definitions: widget.definitions,
                enabled: canDevelop && !busy,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Future<void> remove() async {
    if (document.revision == 0 || busy || !canDevelop) return;
    final id = document.id, revision = document.revision;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除“${document.name}”？'),
        content: Text(
          document.linked ? '删除本站对公共画面的引用及变量绑定。公共画面和其他站点保持。' : '删除该画面及其嵌入的图片。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.api.request(
        'DELETE',
        '/api/v1/screens/$id',
        query: {'revision': revision},
      );
      if (!mounted) return;
      widget.session.screens.removeWhere((s) => s['id'] == id);
      if (widget.onDeleted != null) {
        widget.onDeleted!();
        return;
      }
      editor.open(ScreenDocument.empty(widget.station), saved: false);
      setState(() => message = '画面已删除');
    } catch (e) {
      if (mounted) setState(() => message = '删除失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> image() async {
    await uploadMaterial(place: true);
  }

  Future<void> editBackground() async {
    if (busy || !canDevelop || document.linked) return;
    commitProperties();
    final snapshot = document;
    final next = await editProcessBackground(context, snapshot);
    if (!mounted || next == null || document.id != snapshot.id || !canDevelop) {
      return;
    }
    editor.select('');
    editor.commit(next);
    setState(() => message = '背景已应用到草稿；保存后用于所有预览和运行画面');
  }

  Future<void> uploadMaterial({bool place = false}) async {
    if (busy || !canDevelop) return;
    final id = document.id;
    try {
      final file = await pickProcessFile(image: true);
      if (file == null || !mounted || !canDevelop) {
        return;
      }
      final name = TextEditingController(
        text: file.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
      );
      final group = TextEditingController(text: '自定义');
      late final bool? confirmed;
      try {
        confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('上传到我的素材'),
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    autofocus: true,
                    maxLength: 80,
                    decoration: const InputDecoration(labelText: '素材名称'),
                  ),
                  TextField(
                    controller: group,
                    maxLength: 80,
                    decoration: const InputDecoration(labelText: '分类'),
                  ),
                  const Text(
                    'PNG 透明度会保留，上传后可在各站重复使用。单张不超过 2 MiB。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('上传'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted || !canDevelop) return;
        setState(() => busy = true);
        final uploaded = await materialLibrary.upload(
          file,
          name.text,
          group.text,
        );
        if (!mounted) return;
        setState(() {
          mine = true;
          category = '全部';
          search = '';
          busy = false;
          message = '已上传到我的素材，可跨站复用';
        });
        if (place && document.id == id && editor.editing) {
          await placeMaterial(
            uploaded.summary,
            canvas.currentState?.center ?? const Offset(100, 100),
          );
        }
      } finally {
        name.dispose();
        group.dispose();
      }
    } catch (e) {
      if (mounted) setState(() => message = '素材上传失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> placeMaterial(ProcessMaterialSummary item, Offset point) async {
    if (busy || !canDevelop || !editor.editing) return;
    final id = document.id;
    setState(() => busy = true);
    try {
      final material = await materialLibrary.get(item);
      if (!mounted || document.id != id || !canDevelop || !editor.editing) {
        return;
      }
      final assetID = screenIdentity(), asset = material.asset;
      final dimensions = material.summary;
      final scale = [
        320 / dimensions.width,
        document.width / dimensions.width,
        document.height / dimensions.height,
        1.0,
      ].reduce((a, b) => a < b ? a : b);
      final w = (dimensions.width * scale).clamp(8, document.width),
          h = (dimensions.height * scale).clamp(8, document.height);
      final n = ScreenElement.create('image', point, image: assetID).update({
        'width': w,
        'height': h,
        'x': point.dx.clamp(0, document.width - w),
        'y': point.dy.clamp(0, document.height - h),
      });
      if (document.assets.length >= 64 ||
          utf8.encode(jsonEncode(document.toJson())).length +
                  asset.data.length >
              8 * 1024 * 1024) {
        throw const FormatException('画面图片数量/文件总量超出限制');
      }
      editor.add(n, assets: {...document.assets, assetID: asset});
      setState(() {
        tool = 'select';
        message = '已嵌入 ${item.name}';
      });
    } catch (e) {
      if (mounted) setState(() => message = '图片未嵌入：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> deleteMaterial(ProcessMaterialSummary item) async {
    if (busy || !canDevelop) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除素材 ${item.name}？'),
        content: const Text('已放入工艺画面的图片会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await materialLibrary.delete(item);
      if (mounted) {
        setState(() {
          category = '全部';
          chosenMaterial = null;
          tool = 'select';
          message = '素材已删除';
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = '素材删除失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export() async {
    try {
      commitProperties();
      FocusManager.instance.primaryFocus?.unfocus();
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      final saved = await saveFile(
        utf8.encode(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(document.toTemplate().toJson()),
        ),
        'process-screen.json',
      );
      if (mounted && saved) {
        setState(() => message = '模板已导出（包含图片和变量占位，不含实际点位绑定）');
      }
    } catch (e) {
      if (mounted) setState(() => message = '导出失败：$e');
    }
  }

  Future<void> import() async {
    if (busy || !canDevelop) return;
    try {
      final file = await pickProcessFile(image: false);
      if (file == null || !mounted) return;
      final next = ScreenDocument.fromJson(
        Map<String, dynamic>.from(jsonDecode(utf8.decode(file.bytes)) as Map),
      );
      if (openNewTab(next.instantiate(widget.station, suffix: ' 导入'))) return;
      if (!await leaveDocument() || !mounted) return;
      editor.open(
        next.instantiate(widget.station, suffix: ' 导入'),
        saved: false,
      );
      setState(() {
        tool = 'select';
        editor.editing = true;
        message = next.station == widget.station
            ? '已导入独立新画面；请绑定实例变量与条件后保存'
            : '已导入到目标站点；跨站变量绑定已清空，请重新绑定后保存';
      });
    } catch (e) {
      if (mounted) setState(() => message = '导入失败：$e');
    }
  }

  void chooseTool(String next) {
    commitProperties();
    if (busy || !editor.editing && next != 'hand') return;
    setState(() => tool = next);
    canvas.currentState?.cancelPipe();
  }

  Widget button(
    String tooltip,
    IconData icon,
    VoidCallback? onPressed, {
    bool active = false,
    Key? key,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed == null
        ? null
        : () {
            commitProperties();
            onPressed();
          },
    visualDensity: VisualDensity.compact,
    style: IconButton.styleFrom(
      backgroundColor: active ? const Color(0xffdbeafe) : null,
    ),
    icon: Icon(icon, size: 17),
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (document.linked) return instanceWorkspace();
      final editable = canDevelop && editor.editing && !busy;
      final wide = box.maxWidth >= 880;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            decoration: const BoxDecoration(
              color: WorkbenchColors.chrome,
              border: Border(bottom: BorderSide(color: WorkbenchColors.line)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      widget.development
                          ? (document.station.isEmpty
                                ? '公共画面 · 布局编辑'
                                : '独立工艺画面')
                          : '工艺画面',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!widget.development && widget.onOpenDevelopment != null)
                    TextButton.icon(
                      onPressed: widget.onOpenDevelopment,
                      icon: const Icon(
                        Icons.design_services_outlined,
                        size: 15,
                      ),
                      label: const Text('进入开发页'),
                    ),
                  if (widget.development)
                    button(
                      '显示素材库',
                      Icons.widgets_outlined,
                      () => setState(() {
                        libraryVisible = !libraryVisible;
                        if (!wide && libraryVisible) propertiesVisible = false;
                      }),
                      active: libraryVisible,
                    ),
                  if (widget.development)
                    button(
                      '智能参考线',
                      Icons.center_focus_strong,
                      editable
                          ? () => setState(
                              () => editor.smartGuides = !editor.smartGuides,
                            )
                          : null,
                      active: editor.smartGuides,
                    ),
                  if (widget.development)
                    TextButton.icon(
                      key: const Key('process-new-template'),
                      onPressed: canDevelop && !busy ? create : null,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('添加画面'),
                    ),
                  TextButton.icon(
                    key: const Key('process-preview-embedded'),
                    onPressed: busy
                        ? null
                        : () => showDialog<void>(
                            context: context,
                            builder: (_) => ProcessEmbeddedPreview(
                              document: document,
                              symbols: symbolIndex,
                              readings: readings,
                            ),
                          ),
                    icon: const Icon(Icons.view_quilt_outlined, size: 15),
                    label: const Text('嵌入预览'),
                  ),
                  if (widget.development)
                    TextButton.icon(
                      key: const Key('process-copy-screen'),
                      onPressed: canDevelop && !busy ? saveCopy : null,
                      icon: const Icon(Icons.copy_outlined, size: 16),
                      label: const Text('复制工艺图'),
                    ),
                  if (document.station.isNotEmpty)
                    TextButton.icon(
                      onPressed: busy ? null : showBindings,
                      icon: const Icon(Icons.link, size: 16),
                      label: const Text('变量绑定'),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '画面文件',
                    onSelected: (action) {
                      switch (action) {
                        case 'new':
                          create();
                        case 'copy':
                          saveCopy();
                        case 'transfer':
                          showProcessTransfer(
                            context,
                            widget.api,
                            station: widget.station,
                            stations: widget.stations,
                            variables: widget.definitions.values.toList(),
                            onCommitted: widget.onTransferCommitted,
                          );
                        case 'import':
                          import();
                        case 'export':
                          export();
                        case 'delete':
                          remove();
                        case 'reload':
                          if (!busy) {
                            widget.session.loaded = false;
                            loadInitial();
                          }
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'new',
                        enabled: canDevelop && !busy,
                        child: const Text('添加画面'),
                      ),
                      PopupMenuItem(
                        value: 'copy',
                        enabled: canDevelop && !busy,
                        child: const Text('另存副本'),
                      ),

                      PopupMenuItem(
                        value: 'transfer',
                        enabled: canDevelop && !busy,
                        child: const Text('工艺资料导入 / 导出'),
                      ),
                      PopupMenuItem(
                        value: 'import',
                        enabled: canDevelop && !busy,
                        child: const Text('导入模板 JSON'),
                      ),
                      const PopupMenuItem(
                        value: 'export',
                        child: Text('导出模板 JSON'),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        enabled: canDevelop && !busy && document.revision > 0,
                        child: const Text('删除当前画面'),
                      ),
                    ],
                    icon: const Icon(Icons.folder_open, size: 17),
                  ),
                  SizedBox(
                    width: 190,
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        key: const Key('process-screen-selection'),
                        isExpanded: true,
                        value:
                            document.revision > 0 &&
                                widget.session.screens.any(
                                  (s) => s['id'] == document.id,
                                )
                            ? document.id
                            : '',
                        items: [
                          DropdownMenuItem(
                            value: '',
                            child: Text(
                              document.revision == 0 ? document.name : '选择画面',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          for (final s in widget.session.screens)
                            DropdownMenuItem(
                              value: s['id'] as String,
                              child: Text(
                                s['name'] as String,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: busy
                            ? null
                            : (id) {
                                if (id != null && id.isNotEmpty) open(id);
                              },
                        style: const TextStyle(
                          fontSize: 12,
                          color: WorkbenchColors.ink,
                        ),
                      ),
                    ),
                  ),
                  if (widget.development)
                    button(
                      '保存画面 Ctrl+S',
                      Icons.save_outlined,
                      canDevelop && !busy ? save : null,
                      key: const Key('process-save'),
                    ),
                  SizedBox(
                    width: 110,
                    child: Text(
                      editor.dirty
                          ? widget.development
                                ? '● 未保存'
                                : '草稿预览'
                          : '已保存 · v${document.revision}',
                      style: TextStyle(
                        fontSize: 11,
                        color: editor.dirty
                            ? const Color(0xffb7791f)
                            : WorkbenchColors.muted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 22, child: VerticalDivider()),
                  if (widget.development) ...[
                    for (final entry in {
                      'select': ('选择', Icons.near_me_outlined),
                      'hand': ('平移', Icons.pan_tool_outlined),
                      'pipe': ('管道', Icons.polyline),
                      'rect': ('矩形', Icons.crop_square),
                      'ellipse': ('圆/椭圆', Icons.circle_outlined),
                      'text': ('文字', Icons.text_fields),
                      'value': ('实时数据', Icons.numbers),
                    }.entries)
                      button(
                        entry.value.$1,
                        entry.value.$2,
                        editable || entry.key == 'hand'
                            ? () => chooseTool(entry.key)
                            : null,
                        active: tool == entry.key,
                        key: Key('process-tool-${entry.key}'),
                      ),
                    button(
                      '嵌入图片 PNG/JPEG',
                      Icons.add_photo_alternate_outlined,
                      editable ? image : null,
                      key: const Key('process-image'),
                    ),
                    if (tool == 'pipe')
                      TextButton(
                        onPressed: editable
                            ? () => canvas.currentState?.finishPipe()
                            : null,
                        child: const Text('完成管道'),
                      ),
                    if (tool == 'pipe') ...[
                      DropdownButton<PipeDrawingMode>(
                        key: const Key('pipe-drawing-mode'),
                        value: editor.pipeMode,
                        items: const [
                          DropdownMenuItem(
                            value: PipeDrawingMode.orthogonal,
                            child: Text('直角'),
                          ),
                          DropdownMenuItem(
                            value: PipeDrawingMode.free,
                            child: Text('自由角度'),
                          ),
                          DropdownMenuItem(
                            value: PipeDrawingMode.angle,
                            child: Text('角度步长'),
                          ),
                        ],
                        onChanged: editable
                            ? (v) => setState(() => editor.pipeMode = v!)
                            : null,
                      ),
                      if (editor.pipeMode == PipeDrawingMode.angle)
                        DropdownButton<double>(
                          key: const Key('pipe-angle-step'),
                          value: editor.pipeAngleStep,
                          items: [
                            for (final step in [
                              5.0,
                              10.0,
                              15.0,
                              30.0,
                              45.0,
                              90.0,
                            ])
                              DropdownMenuItem(
                                value: step,
                                child: Text('${step.toInt()}°'),
                              ),
                          ],
                          onChanged: editable
                              ? (v) => setState(() => editor.pipeAngleStep = v!)
                              : null,
                        ),
                      TextButton.icon(
                        key: const Key('pipe-undo-step'),
                        onPressed:
                            editable &&
                                (canvas.currentState?.pipeDraft.canUndo ??
                                    false)
                            ? () => canvas.currentState?.undoPipeStep()
                            : null,
                        icon: const Icon(Icons.undo, size: 15),
                        label: const Text('撤销上一步'),
                      ),
                    ],
                    button(
                      '撤销 Ctrl+Z',
                      Icons.undo,
                      editable &&
                              (canvas.currentState?.canUndo ?? editor.canUndo)
                          ? () =>
                                (canvas.currentState?.pipeDraft.canUndo ??
                                    false)
                                ? canvas.currentState?.undoPipeStep()
                                : editor.undo()
                          : null,
                    ),
                    button(
                      '重做 Ctrl+Y',
                      Icons.redo,
                      editable &&
                              (canvas.currentState?.canRedo ?? editor.canRedo)
                          ? () =>
                                (canvas.currentState?.pipeDraft.canRedo ??
                                    false)
                                ? canvas.currentState?.redoPipeStep()
                                : editor.redo()
                          : null,
                    ),
                  ],
                  button(
                    '适合窗口',
                    Icons.fit_screen,
                    () => canvas.currentState?.fit(),
                  ),
                  button(
                    '放大',
                    Icons.zoom_in,
                    () => canvas.currentState?.zoomBy(1.2),
                  ),
                  button(
                    '缩小',
                    Icons.zoom_out,
                    () => canvas.currentState?.zoomBy(1 / 1.2),
                  ),
                  if (widget.development)
                    TextButton.icon(
                      key: const Key('process-preview'),
                      onPressed: canDevelop && !busy
                          ? () {
                              commitProperties();
                              setState(() {
                                editor.editing = !editor.editing;
                                tool = editor.editing ? 'select' : 'hand';
                                canvas.currentState?.cancelPipe();
                              });
                            }
                          : null,
                      icon: Icon(
                        editor.editing ? Icons.play_arrow : Icons.edit_outlined,
                        size: 16,
                      ),
                      label: Text(editor.editing ? '运行预览' : '编辑画面'),
                    ),
                  if (widget.development)
                    button(
                      '显示属性',
                      Icons.tune,
                      () => setState(() {
                        propertiesVisible = !propertiesVisible;
                        if (!wide && propertiesVisible) libraryVisible = false;
                      }),
                      active: propertiesVisible,
                    ),
                ],
              ),
            ),
          ),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          if (message != null)
            Container(
              color: const Color(0xfffff8e6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(message!, style: const TextStyle(fontSize: 11)),
                  ),
                  IconButton(
                    tooltip: '关闭提示',
                    onPressed: () => setState(() => message = null),
                    icon: const Icon(Icons.close, size: 13),
                    constraints: const BoxConstraints.tightFor(
                      width: 24,
                      height: 22,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          Expanded(
            child: Row(
              children: [
                if (libraryVisible)
                  SizedBox(width: 190, child: library(editable)),
                Expanded(
                  child: ProcessCanvas(
                    key: canvas,
                    controller: editor,
                    symbols: symbolIndex,
                    definitions: widget.definitions,
                    live: widget.live,
                    online: widget.online,
                    enabled: !busy && canDevelop,
                    tool: tool,
                    symbol: chosenSymbol,
                    material: chosenMaterial,
                    onMaterialPlaced: placeMaterial,
                    onToolDone: () => setState(() => tool = 'select'),
                    onInteractionStart: commitProperties,
                    onPipeChanged: () {
                      if (mounted) setState(() {});
                    },
                    onSave: save,
                    onError: (value) => setState(() => message = value),
                  ),
                ),
                if (propertiesVisible && (wide || !libraryVisible))
                  SizedBox(width: 244, child: properties(editable)),
              ],
            ),
          ),
        ],
      );
    },
  );
  Widget library(bool editable) {
    if (mine) return userLibrary(editable);
    final filtered = symbols
        .where(
          (s) =>
              (category == '全部' || s.category == category) &&
              '${s.name} ${s.category}'.toLowerCase().contains(
                search.toLowerCase(),
              ),
        )
        .toList();
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xfff8fafc),
        border: Border(right: BorderSide(color: WorkbenchColors.line)),
      ),
      child: Column(
        children: [
          libraryTabs(),
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              key: const Key('process-symbol-search'),
              decoration: const InputDecoration(
                hintText: '搜索素材',
                prefixIcon: Icon(Icons.search, size: 16),
              ),
              onChanged: (value) => setState(() => search = value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: DropdownButton<String>(
              isExpanded: true,
              value: category,
              items: [
                for (final c in [
                  '全部',
                  ...symbols.map((s) => s.category).toSet(),
                ])
                  DropdownMenuItem(
                    value: c,
                    child: Text(c, style: const TextStyle(fontSize: 11)),
                  ),
              ],
              onChanged: (c) {
                if (c != null) setState(() => category = c);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(6),
            child: Text(
              '${filtered.length} 个素材 · 点击后放置 / 拖入',
              style: const TextStyle(
                fontSize: 10,
                color: WorkbenchColors.muted,
              ),
            ),
          ),
          Expanded(
            child: GridView.builder(
              itemCount: filtered.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisExtent: 88,
              ),
              itemBuilder: (context, index) {
                final s = filtered[index];
                final tile = Tooltip(
                  message: '${s.category} · ${s.name}',
                  child: InkWell(
                    onTap: editable
                        ? () => setState(() {
                            chosenSymbol = s;
                            tool = 'symbol';
                          })
                        : null,
                    child: Container(
                      margin: const EdgeInsets.all(4),
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: tool == 'symbol' && chosenSymbol?.id == s.id
                            ? const Color(0xffdbeafe)
                            : Colors.white,
                        border: Border.all(color: WorkbenchColors.line),
                      ),
                      child: Column(
                        children: [
                          Expanded(child: ProcessSymbolArtwork(symbol: s)),
                          const SizedBox(height: 3),
                          Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 9),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                return editable
                    ? Draggable<ProcessSymbol>(
                        data: s,
                        feedback: Material(
                          color: Colors.white,
                          child: SizedBox(
                            width: 70,
                            height: 70,
                            child: ProcessSymbolArtwork(symbol: s),
                          ),
                        ),
                        child: tile,
                      )
                    : tile;
              },
            ),
          ),
          TextButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'Universal HMI',
            ),
            child: const Text('素材来源与许可', style: TextStyle(fontSize: 10)),
          ),
        ],
      ),
    );
  }

  Widget libraryTabs() => Row(
    children: [
      Expanded(
        child: TextButton(
          onPressed: () => setState(() {
            mine = false;
            search = '';
            category = '全部';
          }),
          child: const Text('内置素材', style: TextStyle(fontSize: 11)),
        ),
      ),
      Expanded(
        child: TextButton(
          key: const Key('process-my-materials'),
          onPressed: () {
            setState(() {
              mine = true;
              search = '';
              category = '全部';
            });
            if (!materialLibrary.loaded) materialLibrary.refresh();
          },
          child: const Text('我的素材', style: TextStyle(fontSize: 11)),
        ),
      ),
    ],
  );

  Widget materialPreview(ProcessMaterialSummary item) =>
      FutureBuilder<ProcessMaterial>(
        future: materialLibrary.get(item),
        builder: (context, snapshot) => CustomPaint(
          painter: const TransparencyGrid(),
          child: SizedBox.expand(
            child: snapshot.hasData
                ? Image.memory(
                    snapshot.data!.asset.bytes,
                    fit: BoxFit.contain,
                    cacheWidth: 128,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined),
                  )
                : Center(
                    child: snapshot.hasError
                        ? const Icon(Icons.broken_image_outlined)
                        : const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                  ),
          ),
        ),
      );

  Widget userLibrary(bool editable) {
    final categories = {'全部', ...materialLibrary.items.map((m) => m.category)};
    final effectiveCategory = categories.contains(category) ? category : '全部';
    final filtered = materialLibrary.items
        .where(
          (m) =>
              (effectiveCategory == '全部' || effectiveCategory == m.category) &&
              '${m.name} ${m.category}'.toLowerCase().contains(
                search.toLowerCase(),
              ),
        )
        .toList();
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xfff8fafc),
        border: Border(right: BorderSide(color: WorkbenchColors.line)),
      ),
      child: Column(
        children: [
          libraryTabs(),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  key: const Key('process-upload-material'),
                  onPressed: editable ? uploadMaterial : null,
                  icon: const Icon(Icons.upload_file, size: 16),
                  label: const Text('上传图片', style: TextStyle(fontSize: 11)),
                ),
              ),
              IconButton(
                tooltip: '刷新素材',
                onPressed: materialLibrary.loading
                    ? null
                    : materialLibrary.refresh,
                icon: const Icon(Icons.refresh, size: 16),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              key: const Key('process-material-search'),
              decoration: const InputDecoration(hintText: '搜索我的素材'),
              onChanged: (v) => setState(() => search = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: DropdownButton<String>(
              isExpanded: true,
              value: effectiveCategory,
              items: [
                for (final c in categories)
                  DropdownMenuItem(
                    value: c,
                    child: Text(
                      c.isEmpty ? '未分类' : c,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => category = v);
              },
            ),
          ),
          if (materialLibrary.loading) const LinearProgressIndicator(),
          if (materialLibrary.error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                materialLibrary.error!,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          Text(
            '${filtered.length} 个素材 · 跨站复用',
            style: const TextStyle(fontSize: 10),
          ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        '上传透明 PNG 后，点击放置或拖入画布。',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  )
                : GridView.builder(
                    itemCount: filtered.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: 110,
                        ),
                    itemBuilder: (context, index) {
                      final item = filtered[index];
                      final tile = Tooltip(
                        message:
                            '${item.name} · ${item.width} × ${item.height}',
                        child: InkWell(
                          key: ValueKey('material-${item.id}'),
                          onTap: editable
                              ? () => setState(() {
                                  chosenMaterial = item;
                                  tool = 'material';
                                })
                              : null,
                          child: Container(
                            margin: const EdgeInsets.all(4),
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color:
                                    chosenMaterial?.id == item.id &&
                                        tool == 'material'
                                    ? Colors.blue
                                    : WorkbenchColors.line,
                              ),
                            ),
                            child: Column(
                              children: [
                                Expanded(child: materialPreview(item)),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 9),
                                      ),
                                    ),
                                    if (canDevelop)
                                      PopupMenuButton<String>(
                                        tooltip: '素材操作',
                                        padding: EdgeInsets.zero,
                                        iconSize: 13,
                                        onSelected: (_) => deleteMaterial(item),
                                        itemBuilder: (_) => [
                                          const PopupMenuItem(
                                            value: 'delete',
                                            child: Text('删除素材'),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                      return editable
                          ? Draggable<Object>(
                              data: item,
                              feedback: Material(
                                child: SizedBox(
                                  width: 80,
                                  height: 60,
                                  child: materialPreview(item),
                                ),
                              ),
                              child: tile,
                            )
                          : tile;
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget properties(bool editable) {
    final n = editor.selected;
    final multi = editor.selectedIDs.length > 1;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xfff8fafc),
        border: Border(left: BorderSide(color: WorkbenchColors.line)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              multi
                  ? '多选'
                  : n == null
                  ? '画面属性'
                  : '元素属性 · ${n.kind}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            field(
              '画面名称',
              document.name,
              (value) => editor.rename(value),
              editable,
              'screen-name',
            ),
            Text(
              '作用域：${widget.station.isEmpty ? '公共总调度' : widget.station}',
              style: const TextStyle(
                fontSize: 11,
                color: WorkbenchColors.muted,
              ),
            ),
            const SizedBox(height: 8),
            if (multi) ...[
              Text(
                '已选择 ${editor.selectedIDs.length} 个元素',
                key: const Key('process-multi-count'),
              ),
              const SizedBox(height: 8),
              const Text(
                '拖动选中元素或使用方向键整体移动；元素属性请单选编辑。',
                style: TextStyle(fontSize: 11, color: WorkbenchColors.muted),
              ),
              const SizedBox(height: 8),
              Wrap(
                children: [
                  button(
                    '左移',
                    Icons.arrow_back,
                    editable ? () => editor.move(const Offset(-10, 0)) : null,
                  ),
                  button(
                    '右移',
                    Icons.arrow_forward,
                    editable ? () => editor.move(const Offset(10, 0)) : null,
                  ),
                  button(
                    '上移',
                    Icons.arrow_upward,
                    editable ? () => editor.move(const Offset(0, -10)) : null,
                  ),
                  button(
                    '下移',
                    Icons.arrow_downward,
                    editable ? () => editor.move(const Offset(0, 10)) : null,
                  ),
                  button(
                    '复制副本',
                    Icons.copy,
                    editable
                        ? () {
                            try {
                              editor.copy();
                              editor.paste();
                            } catch (e) {
                              setState(() => message = e.toString());
                            }
                          }
                        : null,
                  ),
                  button(
                    '删除元素',
                    Icons.delete_outline,
                    editable ? editor.removeSelected : null,
                  ),
                ],
              ),
            ] else if (n == null) ...[
              OutlinedButton.icon(
                key: const Key('process-background'),
                onPressed: editable && !document.linked ? editBackground : null,
                icon: const Icon(Icons.wallpaper_outlined, size: 16),
                label: const Text('设置画面背景'),
              ),
              numeric(
                '画布宽',
                document.width,
                320,
                8192,
                (v) => resizeCanvas(v, document.height),
                editable,
                'screen-width',
              ),
              numeric(
                '画布高',
                document.height,
                240,
                8192,
                (v) => resizeCanvas(document.width, v),
                editable,
                'screen-height',
              ),
              check(
                '显示网格',
                editor.grid,
                editable ? (v) => setState(() => editor.grid = v) : null,
              ),
              check(
                '网格吸附（10 px）',
                editor.snap,
                editable ? (v) => setState(() => editor.snap = v) : null,
              ),
              check(
                '智能参考线 / 对齐吸附',
                editor.smartGuides,
                editable ? (v) => setState(() => editor.smartGuides = v) : null,
              ),
              const Text(
                '选择工具下从空白处拖动框选；Shift 点击切换选择，Shift 框选追加，Ctrl+A 全选。中键或按住空格拖动平移，滚轮缩放。拖动选中元素可移动，按住 Shift 拖动限制为水平或竖直；单选后拖四边或四角调整尺寸。Ctrl+C/V 复制粘贴，Ctrl+D 复制副本，Delete 删除，Ctrl+Z/Y 撤销重做，方向键微调。\n\n按住左键拖动绘制图形；直角管道每次只延伸水平或竖直一段，单击确认后再转向；靠近设备端口或已有管道可拼接。Enter 完成，Backspace / Ctrl+Z 撤销上一次点击。管道工具栏可选择自由角度或角度步长；拼接时连接点优先。智能参考线对齐设备中心与已有管道轴线；紫色线表示吸附位置。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.7,
                  color: WorkbenchColors.muted,
                ),
              ),
            ] else ...[
              if (n.kind != 'pipe') ...[
                numeric(
                  'X',
                  n.x,
                  0,
                  document.width - n.width,
                  (v) => editor.changeStyle({'x': v}, nodeID: n.id),
                  editable,
                  '${n.id}-x',
                ),
                numeric(
                  'Y',
                  n.y,
                  0,
                  document.height - n.height,
                  (v) => editor.changeStyle({'y': v}, nodeID: n.id),
                  editable,
                  '${n.id}-y',
                ),
                numeric(
                  '宽',
                  n.width,
                  8,
                  document.width - n.x,
                  (v) => editor.changeStyle({'width': v}, nodeID: n.id),
                  editable,
                  '${n.id}-width',
                ),
                numeric(
                  '高',
                  n.height,
                  8,
                  document.height - n.y,
                  (v) => editor.changeStyle({'height': v}, nodeID: n.id),
                  editable,
                  '${n.id}-height',
                ),
                DropdownButtonFormField<int>(
                  key: ValueKey('${n.id}-${n.rotation}'),
                  initialValue: n.rotation,
                  decoration: const InputDecoration(labelText: '旋转'),
                  items: [
                    for (final a in [0, 90, 180, 270])
                      DropdownMenuItem(value: a, child: Text('$a°')),
                  ],
                  onChanged: editable
                      ? (v) => editor.changeStyle({'rotation': v})
                      : null,
                ),
              ],
              if (n.kind == 'pipe') ...[
                check(
                  '圆角折弯',
                  n.pipeRounded,
                  editable
                      ? (v) => editor.changeStyle({
                          'pipe_rounded': v,
                        }, nodeID: n.id)
                      : null,
                ),
                if (n.pipeRounded)
                  numeric(
                    '圆角半径（画布 px）',
                    n.pipeBendRadius,
                    1,
                    128,
                    (v) => editor.changeStyle({
                      'pipe_bend_radius': v,
                    }, nodeID: n.id),
                    editable,
                    '${n.id}-pipe-radius',
                  ),
                check(
                  '显示弯头',
                  n.pipeElbows,
                  editable
                      ? (v) =>
                            editor.changeStyle({'pipe_elbows': v}, nodeID: n.id)
                      : null,
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('${n.id}-${n.pipeStyle}'),
                  initialValue: n.pipeStyle,
                  decoration: const InputDecoration(labelText: '管道外观'),
                  items: const [
                    DropdownMenuItem(value: 'flat', child: Text('平面线条')),
                    DropdownMenuItem(value: 'cylinder', child: Text('伪 3D 圆管')),
                  ],
                  onChanged: editable
                      ? (v) =>
                            editor.changeStyle({'pipe_style': v}, nodeID: n.id)
                      : null,
                ),
                check(
                  '显示流向箭头',
                  n.arrow,
                  editable ? (v) => editor.changeStyle({'arrow': v}) : null,
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('${n.id}-${n.arrowMode}'),
                  initialValue: n.arrowMode,
                  decoration: const InputDecoration(labelText: '箭头分布'),
                  items: const [
                    DropdownMenuItem(value: 'single', child: Text('终点单个')),
                    DropdownMenuItem(value: 'spacing', child: Text('按距离间隔')),
                    DropdownMenuItem(value: 'count', child: Text('箭头总数')),
                  ],
                  onChanged: editable
                      ? (v) =>
                            editor.changeStyle({'arrow_mode': v}, nodeID: n.id)
                      : null,
                ),
                if (n.arrowMode == 'spacing')
                  numeric(
                    '箭头间距（画布 px）',
                    n.arrowSpacing,
                    12,
                    2000,
                    (v) =>
                        editor.changeStyle({'arrow_spacing': v}, nodeID: n.id),
                    editable,
                    '${n.id}-arrow-spacing',
                  ),
                if (n.arrowMode == 'count')
                  numeric(
                    '箭头总数',
                    n.arrowCount.toDouble(),
                    1,
                    64,
                    (v) => editor.changeStyle({
                      'arrow_count': v.round(),
                    }, nodeID: n.id),
                    editable,
                    '${n.id}-arrow-count',
                  ),
                check(
                  '启用箭头动画',
                  n.arrowAnimate,
                  editable
                      ? (v) => editor.changeStyle({
                          'arrow_animate': v,
                        }, nodeID: n.id)
                      : null,
                ),
                check(
                  '反向流动',
                  n.arrowReverse,
                  editable
                      ? (v) => editor.changeStyle({
                          'arrow_reverse': v,
                        }, nodeID: n.id)
                      : null,
                ),
                if (n.arrowAnimate)
                  numeric(
                    '运动速度（px/s）',
                    n.arrowSpeed,
                    1,
                    500,
                    (v) => editor.changeStyle({'arrow_speed': v}, nodeID: n.id),
                    editable,
                    '${n.id}-arrow-speed',
                  ),
                for (final entry in {
                  'arrow_visible_rule': '显示条件',
                  'arrow_motion_rule': '运动条件',
                }.entries)
                  OutlinedButton(
                    key: Key('pipe-${entry.key}'),
                    onPressed: editable
                        ? () => editArrowRule(n, entry.key, entry.value)
                        : null,
                    child: Text(
                      '${entry.value}：${n.data[entry.key] == null ? '始终' : '已设置'}',
                    ),
                  ),
                if (pipeFlowState(
                  n,
                  document,
                  widget.definitions,
                  widget.live,
                  widget.online,
                ).invalid)
                  const Text(
                    '条件未绑定或数据无效：箭头联动已关闭',
                    style: TextStyle(fontSize: 11, color: Color(0xffb7791f)),
                  ),
                Text(
                  '连接：${n.startNode.isEmpty
                      ? '自由起点'
                      : n.startPort.startsWith('path:')
                      ? '管道起点'
                      : '设备起点'} → ${n.endNode.isEmpty
                      ? '自由终点'
                      : n.endPort.startsWith('path:')
                      ? '管道终点'
                      : '设备终点'}\n拖动方块调整转折点。',
                  style: const TextStyle(
                    fontSize: 11,
                    color: WorkbenchColors.muted,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              if (n.kind == 'value')
                field(
                  '变量名称',
                  n.label,
                  (v) => editor.changeStyle({'label': v}, nodeID: n.id),
                  editable,
                  '${n.id}-label',
                ),
              if (n.kind == 'text' || n.kind == 'value')
                field(
                  n.kind == 'text' ? '文字内容' : '数值前缀',
                  n.text,
                  (v) => editor.changeStyle({'text': v}, nodeID: n.id),
                  editable,
                  '${n.id}-text',
                  maxLines: 3,
                ),
              if (n.kind == 'text' || n.kind == 'value')
                numeric(
                  '字号',
                  n.fontSize,
                  8,
                  128,
                  (v) => editor.changeStyle({'font_size': v}, nodeID: n.id),
                  editable,
                  '${n.id}-font',
                ),
              if (n.kind != 'image') ...[
                const Text('颜色', style: TextStyle(fontSize: 11)),
                Wrap(
                  spacing: 5,
                  children: [
                    for (final color in [
                      '#2563eb',
                      '#dc2626',
                      '#0d9488',
                      '#f59e0b',
                      '#475569',
                      '#111827',
                      '#9333ea',
                    ])
                      InkWell(
                        onTap: editable
                            ? () => editor.changeStyle({'color': color})
                            : null,
                        child: Container(
                          width: 23,
                          height: 23,
                          margin: const EdgeInsets.symmetric(vertical: 5),
                          decoration: BoxDecoration(
                            color: parseColor(color),
                            border: Border.all(
                              color: n.data['color'] == color
                                  ? Colors.black
                                  : Colors.white,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if ({'pipe', 'rect', 'ellipse'}.contains(n.kind))
                numeric(
                  '线宽',
                  n.strokeWidth,
                  1,
                  32,
                  (v) => editor.changeStyle({'stroke_width': v}, nodeID: n.id),
                  editable,
                  '${n.id}-stroke',
                ),
              if ({'rect', 'ellipse'}.contains(n.kind))
                check(
                  '填充',
                  n.fill != null,
                  editable
                      ? (v) =>
                            editor.changeStyle({'fill': v ? '#e2e8f0' : 'none'})
                      : null,
                ),
              if (n.kind != 'text' && n.kind != 'image') ...[
                const Divider(),
                const Text(
                  '实时数据绑定',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  key: const Key('process-bind'),
                  onPressed: editable && widget.station.isNotEmpty
                      ? () => bind(n)
                      : null,
                  icon: const Icon(Icons.link, size: 15),
                  label: Text(
                    n.pointID.isEmpty
                        ? widget.station.isEmpty
                              ? '模板变量占位（实例化后绑定）'
                              : '选择点位'
                        : widget.definitions[n.pointID]?['name']?.toString() ??
                              '点位缺失',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (n.pointID.isNotEmpty) ...[
                  Text(
                    n.pointID,
                    style: const TextStyle(
                      fontSize: 9,
                      color: WorkbenchColors.muted,
                    ),
                  ),
                  Text(
                    processValue(
                      n,
                      document,
                      widget.definitions,
                      widget.live,
                      widget.online,
                    ).text,
                    style: const TextStyle(fontSize: 11),
                  ),
                  TextButton(
                    onPressed: editable
                        ? () => editor.changeStyle({'point_id': ''})
                        : null,
                    child: const Text('解除绑定'),
                  ),
                ],
                if (n.kind == 'value') ...[
                  field(
                    '单位（留空用点位单位）',
                    n.unitOverride,
                    (v) {
                      if (v.length <= 64) {
                        editor.changeStyle({
                          'unit_override': v.trim(),
                        }, nodeID: n.id);
                      }
                    },
                    editable,
                    '${n.id}-unit',
                  ),
                  numeric(
                    '小数位',
                    n.decimals.toDouble(),
                    0,
                    6,
                    (v) => editor.changeStyle({
                      'decimals': v.round(),
                    }, nodeID: n.id),
                    editable,
                    '${n.id}-decimals',
                  ),
                  check(
                    '显示单位',
                    n.showUnit,
                    editable
                        ? (v) => editor.changeStyle({'show_unit': v})
                        : null,
                  ),
                ] else
                  const Text(
                    '正常值：非零/true 为运行色，零/false 为灰色；无效质量显示异常色。',
                    style: TextStyle(
                      fontSize: 10,
                      color: WorkbenchColors.muted,
                    ),
                  ),
              ],
              const Divider(),
              Wrap(
                children: [
                  button(
                    '复制副本',
                    Icons.copy,
                    editable
                        ? () {
                            editor.copy();
                            editor.paste();
                          }
                        : null,
                  ),
                  button(
                    '置于顶层',
                    Icons.flip_to_front,
                    editable ? () => editor.layer(true) : null,
                  ),
                  button(
                    '置于底层',
                    Icons.flip_to_back,
                    editable ? () => editor.layer(false) : null,
                  ),
                  button(
                    '删除元素',
                    Icons.delete_outline,
                    editable ? editor.removeSelected : null,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void resizeCanvas(double width, double height) {
    try {
      editor.resizeCanvas(width, height);
    } catch (e) {
      setState(() => message = e.toString());
    }
  }

  Future<void> editArrowRule(ScreenElement n, String key, String title) async {
    commitProperties();
    final rule = await showDialog<Json>(
      context: context,
      builder: (_) => ArrowRuleEditor(
        title: title,
        rule: n.data[key] as Json?,
        definitions: widget.definitions,
        station: widget.station,
        template: widget.station.isEmpty,
        onPickPoint: () => showDialog<String>(
          context: context,
          builder: (_) =>
              _PointPicker(points: widget.definitions.values.toList()),
        ),
      ),
    );
    if (!mounted || rule == null || !editor.editing) return;
    editor.changeStyle({
      key: rule['clear'] == true ? null : rule,
    }, nodeID: n.id);
  }

  Widget field(
    String label,
    String value,
    ValueChanged<String> submit,
    bool enabled,
    String identity, {
    int maxLines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: _PropertyField(
      key: ValueKey(identity),
      value: value,
      enabled: enabled,
      maxLines: maxLines,
      label: label,
      submit: submit,
      commits: propertyCommits,
    ),
  );
  Widget numeric(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> submit,
    bool enabled,
    String identity,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: _PropertyField(
      key: ValueKey(identity),
      value: value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1),
      enabled: enabled,
      label: label,
      numeric: true,
      commits: propertyCommits,
      submit: (text) {
        final parsed = double.tryParse(text);
        if (parsed == null ||
            !parsed.isFinite ||
            parsed < min ||
            parsed > max) {
          setState(() => message = '$label 需在 $min–$max 范围内');
          return;
        }
        submit(parsed);
      },
    ),
  );
  Widget check(String label, bool value, ValueChanged<bool>? changed) =>
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        visualDensity: VisualDensity.compact,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(label, style: const TextStyle(fontSize: 11)),
        value: value,
        onChanged: changed == null ? null : (v) => changed(v ?? false),
      );
  Future<void> bind(ScreenElement n) async {
    final scoped = widget.definitions.values.toList();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _PointPicker(points: scoped),
    );
    if (result != null &&
        mounted &&
        editor.editing &&
        editor.selectedID == n.id) {
      editor.changeStyle({'point_id': result});
    }
  }
}

class _PropertyField extends StatefulWidget {
  const _PropertyField({
    super.key,
    required this.label,
    required this.value,
    required this.enabled,
    required this.submit,
    required this.commits,
    this.maxLines = 1,
    this.numeric = false,
  });
  final String label, value;
  final bool enabled, numeric;
  final int maxLines;
  final ValueChanged<String> submit;
  final Set<VoidCallback> commits;
  @override
  State<_PropertyField> createState() => _PropertyFieldState();
}

class _PropertyFieldState extends State<_PropertyField> {
  late final text = TextEditingController(text: widget.value);
  final focus = FocusNode();
  late String lastCommitted = widget.value;
  @override
  void initState() {
    super.initState();
    focus.addListener(focusChanged);
    widget.commits.add(commit);
  }

  void focusChanged() {
    if (!focus.hasFocus) commit();
  }

  void commit() {
    if (widget.enabled && text.text != lastCommitted) {
      lastCommitted = text.text;
      widget.submit(text.text);
    }
  }

  @override
  void didUpdateWidget(_PropertyField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.commits != widget.commits) {
      oldWidget.commits.remove(commit);
      widget.commits.add(commit);
    }
    if (!focus.hasFocus && text.text != widget.value) text.text = widget.value;
    if (!focus.hasFocus || text.text == widget.value) {
      lastCommitted = widget.value;
    }
  }

  @override
  void dispose() {
    widget.commits.remove(commit);
    focus.removeListener(focusChanged);
    focus.dispose();
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: text,
    focusNode: focus,
    enabled: widget.enabled,
    maxLines: widget.maxLines,
    decoration: InputDecoration(labelText: widget.label),
    style: const TextStyle(fontSize: 12),
    keyboardType: widget.numeric
        ? const TextInputType.numberWithOptions(decimal: true)
        : widget.maxLines > 1
        ? TextInputType.multiline
        : TextInputType.text,
    onSubmitted: (_) {
      commit();
      focus.unfocus();
    },
    onTapOutside: (_) {
      commit();
      focus.unfocus();
    },
  );
}

class _PointPicker extends StatefulWidget {
  const _PointPicker({required this.points});
  final List<Json> points;
  @override
  State<_PointPicker> createState() => _PointPickerState();
}

class _PointPickerState extends State<_PointPicker> {
  String search = '';
  @override
  Widget build(BuildContext context) {
    final list = widget.points
        .where(VariableSearch(search).matchesPoint)
        .toList();
    return AlertDialog(
      title: const Text('绑定实时点位'),
      content: SizedBox(
        width: 560,
        height: 390,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜索变量：*、?、逗号多条件',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (s) => setState(() => search = s),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('当前作用域没有匹配的点位'))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) {
                        final p = list[i];
                        return ListTile(
                          dense: true,
                          title: Text('${p['name']}  ${p['unit'] ?? ''}'),
                          subtitle: Text('${p['station']} · ${p['id']}'),
                          onTap: () =>
                              Navigator.pop(context, p['id'] as String),
                        );
                      },
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
}
