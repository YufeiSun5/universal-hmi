import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/table.dart';
import 'session.dart';

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
  });
  final List<String> headers;
  final List<List<String>> rows;
  final ValueChanged<int>? onSelect;
  final String empty;
  final double initialOffset;
  final ValueChanged<double>? onScroll;
  final Set<int> warningRows;
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
          initialWidths: List.generate(
            headers.length,
            (i) => i == 0 ? 230 : 160,
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
                    child: Text(
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('共 $total 条'),
                IconButton(
                  tooltip: '上一页',
                  onPressed: loading || offset == 0
                      ? null
                      : () {
                          offset = (offset - 50).clamp(0, total);
                          load();
                        },
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  tooltip: '下一页',
                  onPressed: loading || offset + 50 >= total
                      ? null
                      : () {
                          offset += 50;
                          load();
                        },
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
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
