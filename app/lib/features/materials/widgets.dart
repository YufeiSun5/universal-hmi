import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../../shared/pagination.dart';
import '../../shared/api.dart';
import '../../shared/table.dart';
import 'session.dart';
import 'category_browser.dart';
import 'workflow_theme.dart';
export 'workflow_theme.dart';

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
  const MaterialStatusBadge({
    super.key,
    required this.status,
    this.prominent = false,
  });
  final String status;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final (foreground, background, icon) = switch (status) {
      'review' || 'approval' || 'receipt' || 'pending' || 'part_returned' => (
        const Color(0xff925c09),
        const Color(0xfffff3d6),
        Icons.schedule,
      ),
      'closed' || 'approved' || 'returned' || 'confirmed' => (
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
      padding: EdgeInsets.symmetric(horizontal: 9, vertical: prominent ? 6 : 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: foreground.withValues(alpha: .18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: foreground, size: prominent ? 18 : 14),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              materialStatus(status),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: prominent ? 15 : 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> materialConfirm(
  BuildContext context,
  String title,
  String content,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => MaterialWorkflowAlert(
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
  List<String> get headers => [
    ...widget.headers,
    if (widget.onSelect != null) '操作',
  ];
  List<List<String>> get rows => [
    for (final row in widget.rows)
      [...row, if (widget.onSelect != null) '查看详情'],
  ];
  ValueChanged<int>? get onSelect => widget.onSelect;
  String get empty => widget.empty;
  double get initialOffset => widget.initialOffset;
  ValueChanged<double>? get onScroll => widget.onScroll;
  Set<int> get warningRows => widget.warningRows;
  late double retainedOffset = initialOffset;
  void recordScroll(double value) {
    retainedOffset = value;
    onScroll?.call(value);
  }

  double minimumWidth(String label) => switch (label) {
    '主单号' || '申请单号' || '单号' => 96,
    '提交时间' || '时间' || '最近办理时间' => 104,
    '节点数' || '版本' || '层级' || '修订' => 52,
    '单位' => 48,
    '操作' => 80,
    '发起人' || '申请人' || '经办人' => 62,
    '领用方' => 84,
    '当前状态' || '审批状态' || '状态' => 96,
    '金额' => 100,
    '申请内容' || '物料明细' || '内容' => 104,
    _ => 82,
  };
  late final ScrollController mobileScroll = ScrollController(
    initialScrollOffset: initialOffset,
    keepScrollOffset: false,
  )..addListener(() => recordScroll(mobileScroll.offset));
  @override
  void dispose() {
    mobileScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (rows.isEmpty) return Center(child: Text(empty));
      final usable = box.maxWidth - 24; // DenseTable report frame margins.
      final minimums = headers.map(minimumWidth).toList();
      final minimumTotal = minimums.fold(0.0, (a, b) => a + b);
      final weights = headers
          .map((v) => ['申请内容', '物料明细', '内容', '物料名称'].contains(v) ? 3.0 : 1.0)
          .toList();
      final totalWeight = weights.fold(0.0, (a, b) => a + b);
      if (usable >= minimumTotal) {
        return DenseTable(
          key: ValueKey('material-fit-${headers.join('|')}-${usable.round()}'),
          appearance: const {'row_height': 64},
          headers: headers,
          rows: rows,
          onSelect: onSelect,
          reportStyle: true,
          emptyLabel: empty,
          initialScrollOffset: retainedOffset,
          onScroll: recordScroll,
          rowBuilder: (i) => rows[i],
          emphasizedRows: warningRows,
          warningRows: warningRows,
          cellBuilder: (row, column, value) =>
              column == headers.length - 1 && widget.onSelect != null
              ? OutlinedButton(
                  onPressed: () => widget.onSelect!(row),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(0, 36),
                  ),
                  child: const Text('查看详情', style: TextStyle(fontSize: 13)),
                )
              : column == widget.statusColumn && row < widget.statuses.length
              ? MaterialStatusBadge(status: widget.statuses[row])
              : Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign:
                      ['物料明细', '内容', '申请内容', '领用方'].contains(headers[column])
                      ? TextAlign.left
                      : TextAlign.center,
                  style: TextStyle(
                    fontSize:
                        [
                          '物料名称',
                          '申请内容',
                          '物料明细',
                          '内容',
                          '金额',
                          '该类库存',
                        ].contains(headers[column])
                        ? 15
                        : 13,
                    fontWeight:
                        [
                          '物料名称',
                          '申请内容',
                          '物料明细',
                          '内容',
                          '金额',
                          '该类库存',
                        ].contains(headers[column])
                        ? FontWeight.w600
                        : FontWeight.normal,
                    height: 1.35,
                  ),
                ),
          initialWidths: List.generate(
            headers.length,
            (i) =>
                minimums[i] +
                (usable - minimumTotal) * weights[i] / totalWeight,
          ),
        );
      }
      final primary = headers.indexWhere(
        (v) => ['申请内容', '物料名称', '物料明细', '内容'].contains(v),
      );
      final fieldOrder = [
        if (primary >= 0) primary,
        for (var col = 0; col < widget.headers.length; col++)
          if (col != primary) col,
      ];
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
                for (final col in fieldOrder)
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
                            col == primary
                                ? rows[i][col]
                                : '${headers[col]}：${rows[i][col]}',
                            style: TextStyle(
                              fontSize: col == primary ? 18 : 14,
                              fontWeight: col == primary
                                  ? FontWeight.w600
                                  : null,
                              color: warningRows.contains(i)
                                  ? const Color(0xffb3261e)
                                  : null,
                            ),
                          ),
                  ),
                if (onSelect != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: () => onSelect!(i),
                      icon: const Icon(Icons.arrow_forward, size: 18),
                      label: const Text('查看详情'),
                    ),
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
  bool applicationSelection = false,
  bool categorySelection = false,
}) => showDialog<Json>(
  context: context,
  builder: (_) => MaterialRecordPicker(
    api: api,
    title: title,
    endpoint: endpoint,
    label: label,
    query: query,
    applicationSelection: applicationSelection,
    categorySelection: categorySelection,
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
    this.applicationSelection = false,
    this.categorySelection = false,
  });
  final PlatformApi api;
  final String title, endpoint;
  final String Function(Json) label;
  final Json query;
  final bool applicationSelection;
  final bool categorySelection;
  @override
  State<MaterialRecordPicker> createState() => _MaterialRecordPickerState();
}

class _MaterialRecordPickerState extends State<MaterialRecordPicker> {
  final search = TextEditingController();
  List<Json> items = [];
  int total = 0, offset = 0, generation = 0;
  bool loading = true;
  String? error;
  DateTime? fromDate, toDate;
  bool onlyUnreceived = false;
  final categorySession = MaterialsSession();
  bool showCategories = true;
  @override
  void initState() {
    super.initState();
    if (widget.applicationSelection) recentDays();
    load();
  }

  @override
  void dispose() {
    search.dispose();
    categorySession.dispose();
    super.dispose();
  }

  void recentDays() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    toDate = DateTime.utc(now.year, now.month, now.day);
    fromDate = toDate!.subtract(const Duration(days: 6));
  }

  String dateLabel(DateTime? value, String fallback) =>
      value == null ? fallback : value.toIso8601String().substring(0, 10);

  Future<void> pickDate(bool start) async {
    final today = DateTime.now().toUtc().add(const Duration(hours: 8));
    final chosen = await showDatePicker(
      context: context,
      helpText: start ? '开始日期' : '结束日期',
      initialDate: (start ? fromDate : toDate) ?? today,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      cancelText: '取消',
      confirmText: '确定',
      builder: (context, child) => Localizations.override(
        context: context,
        locale: const Locale('zh', 'CN'),
        delegates: GlobalMaterialLocalizations.delegates,
        child: Theme(
          data: Theme.of(context).copyWith(
            datePickerTheme: Theme.of(context).datePickerTheme.copyWith(
              headerHeadlineStyle: const TextStyle(
                fontFamily: 'HmiCJK',
                fontSize: 24,
                height: 1.2,
              ),
            ),
          ),
          child: child!,
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final day = DateTime.utc(chosen.year, chosen.month, chosen.day);
    if (start) {
      fromDate = day;
      if (toDate != null && day.isAfter(toDate!)) toDate = day;
    } else {
      toDate = day;
      if (fromDate != null && day.isBefore(fromDate!)) fromDate = day;
    }
    offset = 0;
    load();
  }

  Widget applicationFilters() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('提交日期（北京时间）', style: TextStyle(fontSize: 14)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const Key('material-picker-from'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                textStyle: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontSize: 14),
                visualDensity: VisualDensity.standard,
              ),
              onPressed: () => pickDate(true),
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(dateLabel(fromDate, '开始日期')),
            ),
            const Text('至'),
            OutlinedButton.icon(
              key: const Key('material-picker-until'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                textStyle: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontSize: 14),
                visualDensity: VisualDensity.standard,
              ),
              onPressed: () => pickDate(false),
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(dateLabel(toDate, '结束日期')),
            ),
            TextButton(
              onPressed: () {
                recentDays();
                offset = 0;
                load();
              },
              child: const Text('最近7天'),
            ),
            TextButton(
              onPressed: () {
                fromDate = null;
                toDate = null;
                offset = 0;
                load();
              },
              child: const Text('全部日期'),
            ),
            Tooltip(
              message: '尚未关联任何入库单；已分批入库的申请不属于未入库',
              child: FilterChip(
                labelStyle: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(fontSize: 14),
                label: const Text('仅未入库'),
                selected: onlyUnreceived,
                onSelected: (v) {
                  onlyUnreceived = v;
                  offset = 0;
                  load();
                },
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Future<void> load() async {
    final token = ++generation;
    setState(() {
      loading = true;
      error = null;
      items = [];
      total = 0;
    });
    try {
      final data = await widget.api.request(
        'GET',
        widget.endpoint,
        query: {
          ...widget.query,
          if (widget.categorySelection &&
              categorySession.selectedCategory != null)
            'category_id': categorySession.selectedCategory!['id'],
          if (widget.applicationSelection) ...{
            if (fromDate != null)
              'from': fromDate!
                  .subtract(const Duration(hours: 8))
                  .toIso8601String(),
            if (toDate != null)
              'until': toDate!
                  .add(const Duration(days: 1))
                  .subtract(const Duration(hours: 8))
                  .toIso8601String(),
            if (onlyUnreceived) 'inbound_status': 'none',
          },
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

  Widget choice(Json item) {
    void select() => Navigator.pop(context, item);
    final application = widget.applicationSelection;
    final unavailable =
        widget.endpoint.endsWith('/stock') &&
        (num.tryParse(materialText(item, 'quantity')) ?? 0) <= 0;
    final name = application
        ? materialApplicationLabel(item)
        : materialText(item, 'name');
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: Color(0xffd3dbe3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: loading || unavailable ? null : select,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                name.isEmpty ? widget.label(item) : name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 8),
              if (application) ...[
                Wrap(
                  spacing: 18,
                  runSpacing: 4,
                  children: [
                    Text('申请人：${item['owner'] ?? ''}'),
                    Text('提交时间：${materialTime(item['submitted'])}'),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '单号：${item['number'] ?? ''}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xff647581),
                  ),
                ),
              ] else ...[
                Wrap(
                  spacing: 18,
                  runSpacing: 4,
                  children: [
                    Text(
                      '料号：${materialText(item, 'code')} · 规格：${materialText(item, 'specification').isEmpty ? '未填写' : item['specification']}',
                    ),
                    Text('单位：${item['unit'] ?? ''}'),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '分类：${item['stock_category'] ?? item['category_name'] ?? item['category'] ?? '未填写'}',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 18,
                  runSpacing: 4,
                  children: [
                    Text(
                      '参考单价：${materialText(item, 'price').isEmpty ? '未填写' : '¥${item['price']} / ${item['unit']}'}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    if (widget.endpoint.endsWith('/stock'))
                      Text(
                        '可用库存：${item['quantity']} ${item['unit']}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: loading || unavailable ? null : select,
                  icon: Icon(
                    unavailable ? Icons.inventory_2_outlined : Icons.add,
                    size: 18,
                  ),
                  label: Text(
                    unavailable
                        ? '暂无库存'
                        : application
                        ? '选择此申请'
                        : '选择物料',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget results() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.applicationSelection || widget.categorySelection)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            widget.applicationSelection
                ? '已批准申请 · $total 条 · 最新提交在前'
                : '${categorySession.selectedCategory == null ? '全部分类' : '${categoryLabel(categorySession.selectedCategory!)}（含子类）'} · $total 项',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ),
      if (loading) const LinearProgressIndicator(),
      if (error != null) materialError(error!, retry: load),
      Expanded(
        child: items.isEmpty && !loading
            ? Center(
                child: Text(
                  widget.applicationSelection
                      ? '当前条件下没有已批准申请，可调整日期或入库筛选'
                      : '暂无可选记录',
                ),
              )
            : ListView.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) =>
                    widget.applicationSelection || widget.categorySelection
                    ? const SizedBox(height: 10)
                    : const Divider(height: 1),
                itemBuilder: (context, i) =>
                    widget.applicationSelection || widget.categorySelection
                    ? choice(items[i])
                    : ListTile(
                        title: Text(widget.label(items[i])),
                        enabled: !loading,
                        onTap: () => Navigator.pop(context, items[i]),
                      ),
              ),
      ),
      if (total > 50)
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
  );

  Widget categoryResults() => LayoutBuilder(
    builder: (context, box) => Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => showCategories = !showCategories),
            icon: Icon(
              showCategories ? Icons.chevron_left : Icons.account_tree_outlined,
            ),
            label: Text(showCategories ? '收起分类' : '展开分类'),
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showCategories) ...[
                SizedBox(
                  width: box.maxWidth < 600 ? 132 : 210,
                  child: MaterialCategoryBrowser(
                    api: widget.api,
                    session: categorySession,
                    compact: box.maxWidth < 600,
                    onSelect: (value) {
                      categorySession.selectedCategory = value;
                      offset = 0;
                      load();
                    },
                  ),
                ),
                const VerticalDivider(width: 18),
              ],
              Expanded(child: results()),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => MaterialWorkflowDialog(
    child: SizedBox(
      width: widget.categorySelection ? 960 : 820,
      height: MediaQuery.sizeOf(context).height * .85,
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
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
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
                hintText: widget.applicationSelection
                    ? '申请内容、申请人或单号'
                    : '料号、物料名称或规格',
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
            if (widget.applicationSelection) applicationFilters(),
            const Divider(height: 16),
            Expanded(
              child: widget.categorySelection ? categoryResults() : results(),
            ),
          ],
        ),
      ),
    ),
  );
}

String itemLabel(Json v) =>
    '${materialText(v, 'code').isEmpty ? '' : '料号 ${v['code']} · '}${v['name']} · ${v['specification'] ?? ''} · ${v['unit']}';
