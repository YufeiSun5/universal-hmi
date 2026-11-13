import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../shared/pagination.dart';
import '../../shared/api.dart';
import '../../shared/table.dart';
import 'session.dart';

class MaterialAccountLink extends StatelessWidget {
  const MaterialAccountLink({
    super.key,
    required this.session,
    this.enabled = true,
    this.compact = false,
  });
  final MaterialsSession session;
  final bool enabled;
  final bool compact;
  @override
  Widget build(BuildContext context) => compact
      ? IconButton(
          tooltip: '设置个人签名',
          onPressed: enabled ? session.openAccount : null,
          icon: const Icon(Icons.draw_outlined, size: 18),
        )
      : TextButton.icon(
          onPressed: enabled ? session.openAccount : null,
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('设置个人签名'),
        );
}

class MaterialStatusBadge extends StatelessWidget {
  const MaterialStatusBadge({super.key, required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (foreground, background, icon) = switch (status) {
      'pending' || 'part_returned' => (
        const Color(0xff925c09),
        const Color(0xfffff3d6),
        Icons.schedule,
      ),
      'approved' || 'returned' => (
        const Color(0xff167149),
        const Color(0xffe7f5ec),
        Icons.check_circle_outline,
      ),
      'rejected' => (
        const Color(0xffb33737),
        const Color(0xfffceaea),
        Icons.cancel_outlined,
      ),
      _ => (
        const Color(0xff41647f),
        const Color(0xffeaf1f7),
        Icons.info_outline,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: foreground.withValues(alpha: .18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: foreground, size: 14),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              materialStatus(status),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Widget materialError(String message, {VoidCallback? retry}) => Padding(
  padding: const EdgeInsets.all(12),
  child: Wrap(
    spacing: 12,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(message, style: const TextStyle(color: Color(0xffb3261e))),
      if (retry != null)
        OutlinedButton(onPressed: retry, child: const Text('重试')),
    ],
  ),
);

Future<bool> materialConfirm(
  BuildContext context,
  String title,
  String content,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

class MaterialTable extends StatefulWidget {
  const MaterialTable({
    super.key,
    required this.headers,
    required this.rows,
    this.onSelect,
    this.empty = '暂无记录',
    this.initialOffset = 0,
    this.onScroll,
    this.warningRows = const {},
    this.statusColumn,
    this.statuses = const [],
  });
  final List<String> headers;
  final List<List<String>> rows;
  final ValueChanged<int>? onSelect;
  final String empty;
  final double initialOffset;
  final ValueChanged<double>? onScroll;
  final Set<int> warningRows;
  final int? statusColumn;
  final List<String> statuses;
  @override
  State<MaterialTable> createState() => _MaterialTableState();
}

class _MaterialTableState extends State<MaterialTable> {
  List<String> get headers => widget.headers;
  List<List<String>> get rows => widget.rows;
  ValueChanged<int>? get onSelect => widget.onSelect;
  String get empty => widget.empty;
  double get initialOffset => widget.initialOffset;
  ValueChanged<double>? get onScroll => widget.onScroll;
  Set<int> get warningRows => widget.warningRows;
  late final ScrollController mobileScroll = ScrollController(
    initialScrollOffset: initialOffset,
    keepScrollOffset: false,
  )..addListener(() => onScroll?.call(mobileScroll.offset));
  @override
  void dispose() {
    mobileScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (rows.isEmpty) return Center(child: Text(empty));
      if (box.maxWidth >= 700) {
        return DenseTable(
          headers: headers,
          rows: rows,
          onSelect: onSelect,
          reportStyle: true,
          emptyLabel: empty,
          initialScrollOffset: initialOffset,
          onScroll: onScroll,
          rowBuilder: (i) => rows[i],
          emphasizedRows: warningRows,
          warningRows: warningRows,
          cellBuilder: (row, column, value) =>
              column == widget.statusColumn && row < widget.statuses.length
              ? MaterialStatusBadge(status: widget.statuses[row])
              : null,
          initialWidths: List.generate(
            headers.length,
            (i) => switch (headers[i]) {
              '主单号' || '申请单号' || '单号' => 235,
              '提交时间' || '时间' || '最近办理时间' => 165,
              '节点数' || '版本' || '层级' || '修订' => 60,
              '单位' => 55,
              '发起人' || '申请人' || '经办人' => 90,
              '当前状态' || '审批状态' || '状态' => 105,
              '参考单价' || '预警值' || '该类库存' || '各类总库存' => 95,
              '金额' => 125,
              '规格' => 100,
              '预警' => 135,
              '分类路径' => 380,
              '申请内容' || '物料明细' || '内容' => 210,
              _ => 175,
            },
          ),
        );
      }
      return ListView.separated(
        controller: mobileScroll,
        itemCount: rows.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) => InkWell(
          onTap: onSelect == null ? null : () => onSelect!(i),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var col = 0; col < headers.length; col++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child:
                        col == widget.statusColumn && i < widget.statuses.length
                        ? Row(
                            children: [
                              Text('${headers[col]}：'),
                              MaterialStatusBadge(status: widget.statuses[i]),
                            ],
                          )
                        : Text(
                            '${headers[col]}：${rows[i][col]}',
                            style: TextStyle(
                              fontWeight: col == 0 ? FontWeight.w600 : null,
                              color: warningRows.contains(i)
                                  ? const Color(0xffb3261e)
                                  : null,
                            ),
                          ),
                  ),
                if (onSelect != null)
                  const Align(
                    alignment: Alignment.centerRight,
                    child: Icon(Icons.chevron_right, size: 18),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class MaterialAssetView extends StatefulWidget {
  const MaterialAssetView({
    super.key,
    required this.api,
    required this.id,
    this.height = 120,
  });
  final PlatformApi api;
  final String id;
  final double height;
  @override
  State<MaterialAssetView> createState() => _MaterialAssetViewState();
}

class _MaterialAssetViewState extends State<MaterialAssetView> {
  late Future<Json> task;
  void load() {
    task = widget.api.request(
      'GET',
      '$materialsBase/assets/${Uri.encodeComponent(widget.id)}',
    );
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant MaterialAssetView old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: task,
    builder: (context, result) {
      if (result.hasError) {
        return materialError('${result.error}', retry: () => setState(load));
      }
      if (!result.hasData) {
        return const SizedBox(
          height: 48,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      late final Uint8List data;
      try {
        data = base64Decode(materialText(result.data!, 'data'));
      } on FormatException {
        return materialError('图片内容无效', retry: () => setState(load));
      }
      return InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (dialog) => Dialog(
            child: Stack(
              children: [
                SizedBox(
                  width: 800,
                  height: MediaQuery.sizeOf(dialog).height * .75,
                  child: InteractiveViewer(
                    child: Image.memory(
                      data,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Text('图片内容无效，请关闭后重试'),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: IconButton(
                    tooltip: '关闭图片',
                    onPressed: () => Navigator.pop(dialog),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
        ),
        child: Container(
          height: widget.height,
          color: Colors.white,
          alignment: Alignment.centerLeft,
          child: Image.memory(
            data,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                materialError('图片内容无效', retry: () => setState(load)),
          ),
        ),
      );
    },
  );
}

Future<Json?> pickMaterialRecord(
  BuildContext context,
  PlatformApi api, {
  required String title,
  required String endpoint,
  required String Function(Json) label,
  Json query = const {},
}) => showDialog<Json>(
  context: context,
  builder: (_) => MaterialRecordPicker(
    api: api,
    title: title,
    endpoint: endpoint,
    label: label,
    query: query,
  ),
);

class MaterialRecordPicker extends StatefulWidget {
  const MaterialRecordPicker({
    super.key,
    required this.api,
    required this.title,
    required this.endpoint,
    required this.label,
    this.query = const {},
  });
  final PlatformApi api;
  final String title, endpoint;
  final String Function(Json) label;
  final Json query;
  @override
  State<MaterialRecordPicker> createState() => _MaterialRecordPickerState();
}

class _MaterialRecordPickerState extends State<MaterialRecordPicker> {
  final search = TextEditingController();
  List<Json> items = [];
  int total = 0, offset = 0, generation = 0;
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final token = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final data = await widget.api.request(
        'GET',
        widget.endpoint,
        query: {
          ...widget.query,
          'search': search.text,
          'offset': offset,
          'limit': 50,
        },
      );
      if (!mounted || token != generation) return;
      setState(() {
        items = objects(data['items']);
        total = data['total'] as int? ?? 0;
      });
    } catch (e) {
      if (mounted && token == generation) setState(() => error = '$e');
    }
    if (mounted && token == generation) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 680,
      height: MediaQuery.sizeOf(context).height * .75,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '取消选择',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            TextField(
              key: const Key('material-picker-search'),
              controller: search,
              decoration: InputDecoration(
                labelText: '搜索',
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  onPressed: () {
                    offset = 0;
                    load();
                  },
                  icon: const Icon(Icons.search),
                ),
              ),
              onSubmitted: (_) {
                offset = 0;
                load();
              },
            ),
            if (loading) const LinearProgressIndicator(),
            if (error != null) materialError(error!, retry: load),
            Expanded(
              child: items.isEmpty && !loading
                  ? const Center(child: Text('暂无可选记录'))
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => ListTile(
                        title: Text(widget.label(items[i])),
                        enabled: !loading,
                        onTap: () => Navigator.pop(context, items[i]),
                      ),
                    ),
            ),
            PaginationBar(
              total: total,
              offset: offset,
              pageSize: 50,
              busy: loading,
              onChanged: (v) {
                offset = v;
                load();
              },
            ),
          ],
        ),
      ),
    ),
  );
}

String categoryLabel(Json v) => materialText(v, 'path').isNotEmpty
    ? materialText(v, 'path')
    : materialText(v, 'name');
String itemLabel(Json v) =>
    '${v['name']} · ${v['specification'] ?? ''} · ${v['unit']}';
