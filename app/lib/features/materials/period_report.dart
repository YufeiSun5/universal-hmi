import 'dart:convert';
import 'package:flutter/material.dart';
import '../../platform/save.dart';
import '../../shared/api.dart';
import '../../shared/pagination.dart';
import 'detail.dart';
import 'session.dart';
import 'widgets.dart';

class MaterialPeriodReport extends StatefulWidget {
  const MaterialPeriodReport({
    super.key,
    required this.api,
    required this.session,
    required this.access,
    this.category,
    required this.onClearCategory,
    required this.onShowDirectory,
    required this.directoryHidden,
  });
  final PlatformApi api;
  final MaterialsSession session;
  final Json access;
  final Json? category;
  final VoidCallback onClearCategory, onShowDirectory;
  final bool directoryHidden;
  @override
  State<MaterialPeriodReport> createState() => _MaterialPeriodReportState();
}

class _MaterialPeriodReportState extends State<MaterialPeriodReport> {
  final search = TextEditingController();
  final from = TextEditingController(), to = TextEditingController();
  final horizontal = ScrollController(), vertical = ScrollController();
  String kind = 'inbound';
  int offset = 0, generation = 0;
  bool busy = false, exporting = false, dirty = false;
  Json? result;
  Json applied = {};
  String? error, exportError, saved;
  List<String> get kinds => [
    if ((widget.access['grants'] as Json?)?['materials_inbound'] == true)
      'inbound',
    if ((widget.access['grants'] as Json?)?['materials_outbound'] == true)
      'outbound',
  ];
  String day(DateTime date) => date.toIso8601String().substring(0, 10);
  @override
  void initState() {
    super.initState();
    final old = widget.session.filters['reports'] ?? {};
    kind = kinds.contains(old['kind']) ? old['kind'] as String : kinds.first;
    search.text = materialText(old, 'search');
    from.text = materialText(old, 'from_date');
    to.text = materialText(old, 'to_date');
    if (from.text.isEmpty || to.text.isEmpty) preset('本月');
    load();
  }

  @override
  void didUpdateWidget(covariant MaterialPeriodReport old) {
    super.didUpdateWidget(old);
    if (old.category?['id'] != widget.category?['id']) {
      offset = 0;
      load();
    }
  }

  @override
  void dispose() {
    search.dispose();
    from.dispose();
    to.dispose();
    horizontal.dispose();
    vertical.dispose();
    super.dispose();
  }

  void remember() => widget.session.filters['reports'] = {
    'kind': kind,
    'search': search.text,
    'from_date': from.text,
    'to_date': to.text,
  };
  void preset(String label) {
    final today = DateTime.now().toUtc().add(const Duration(hours: 8));
    var start = DateTime.utc(today.year, today.month, today.day), end = start;
    if (label == '本月') start = DateTime.utc(today.year, today.month);
    if (label == '上月') {
      start = DateTime.utc(today.year, today.month - 1);
      end = DateTime.utc(today.year, today.month, 0);
    }
    from.text = day(start);
    to.text = day(end);
    offset = 0;
  }

  DateTime parseDay(String value) {
    final d = DateTime.tryParse('${value.trim()}T00:00:00Z');
    if (d == null || day(d) != value.trim()) {
      throw const FormatException('日期格式应为 YYYY-MM-DD');
    }
    return d;
  }

  Future<void> pick(bool start) async {
    final field = start ? from : to;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(field.text) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: start ? '开始日期' : '结束日期',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (!mounted || picked == null) return;
    setState(() {
      field.text = day(picked);
      dirty = true;
      saved = null;
    });
    remember();
  }

  Future<void> load() async {
    final token = ++generation;
    remember();
    setState(() {
      busy = true;
      error = null;
      exportError = null;
      saved = null;
      result = null;
    });
    try {
      final start = parseDay(from.text),
          end = parseDay(to.text).add(const Duration(days: 1));
      if (!start.isBefore(end)) throw const FormatException('开始日期不能晚于结束日期');
      final query = <String, dynamic>{
        'kind': kind,
        'from': start.subtract(const Duration(hours: 8)).toIso8601String(),
        'until': end.subtract(const Duration(hours: 8)).toIso8601String(),
        'search': search.text.trim(),
        'offset': offset,
        'limit': 50,
        if (widget.category != null) 'category_id': widget.category!['id'],
      };
      final data = await widget.api.request(
        'GET',
        '$materialsBase/reports',
        query: query,
      );
      if (!mounted || token != generation) return;
      setState(() {
        result = data;
        applied = query;
        dirty = false;
      });
      if (vertical.hasClients) vertical.jumpTo(0);
    } catch (e) {
      if (mounted && token == generation) setState(() => error = '$e');
    }
    if (mounted && token == generation) setState(() => busy = false);
  }

  Future<void> export(String selected) async {
    final query = <String, dynamic>{...applied, 'kind': selected}
      ..remove('offset')
      ..remove('limit');
    setState(() {
      exporting = true;
      exportError = null;
      saved = null;
    });
    try {
      final data = await widget.api.request(
        'GET',
        '$materialsBase/reports/export',
        query: query,
      );
      final ok = await saveFile(
        base64Decode(materialText(data, 'data')),
        materialText(data, 'name'),
      );
      if (mounted) {
        setState(() => saved = ok ? 'Excel已生成，已交给文件保存功能。' : '已取消文件保存。');
      }
    } catch (e) {
      if (mounted) setState(() => exportError = '导出失败：$e');
    }
    if (mounted) setState(() => exporting = false);
  }

  Future<void> open(Json row) async {
    await showMaterialDetail(
      context,
      widget.api,
      widget.session,
      kind: 'document',
      record: {'id': row['document_id']},
      access: widget.access,
    );
  }

  double columnWidth(String name) => ['名称', '供应商', '工程项目'].contains(name)
      ? 180
      : ['序号', '单位'].contains(name)
      ? 44
      : 100;

  Widget dateField(
    TextEditingController controller,
    String label,
    bool start,
  ) => SizedBox(
    width: 176,
    child: TextField(
      controller: controller,
      enabled: !busy && !exporting,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'YYYY-MM-DD',
        isDense: true,
        suffixIcon: IconButton(
          tooltip: '选择$label',
          onPressed: busy || exporting ? null : () => pick(start),
          icon: const Icon(Icons.calendar_month, size: 18),
        ),
      ),
      onChanged: (_) {
        setState(() {
          dirty = true;
          saved = null;
        });
        remember();
      },
      onSubmitted: (_) {
        offset = 0;
        load();
      },
    ),
  );
  @override
  Widget build(BuildContext context) {
    final locked = busy || exporting;
    final rows = objects(result?['items']);
    final columns = (result?['columns'] as List? ?? [])
        .map((e) => '$e')
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (widget.directoryHidden)
                IconButton(
                  tooltip: '显示物料目录',
                  onPressed: widget.onShowDirectory,
                  icon: const Icon(Icons.menu_open),
                ),
              const Text(
                '出入库汇总',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              for (final k in kinds)
                ChoiceChip(
                  label: Text('${materialKind(k)}明细'),
                  selected: kind == k,
                  onSelected: locked
                      ? null
                      : (_) {
                          setState(() => kind = k);
                          offset = 0;
                          load();
                        },
                ),
              OutlinedButton.icon(
                onPressed: locked || dirty || result == null
                    ? null
                    : () => export(kind),
                icon: const Icon(Icons.download_outlined, size: 18),
                label: Text('导出${materialKind(kind)}'),
              ),
              if (kinds.length == 2)
                FilledButton.icon(
                  onPressed: locked || dirty || result == null
                      ? null
                      : () => export('both'),
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: Text(exporting ? '正在导出…' : '合并导出入库＋出库'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              dateField(from, '开始日期', true),
              dateField(to, '结束日期', false),
              SizedBox(
                width: 230,
                child: TextField(
                  controller: search,
                  enabled: !locked,
                  decoration: const InputDecoration(
                    labelText: '物料名称／规格／单号／领用方',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                  ),
                  onChanged: (_) {
                    setState(() => dirty = true);
                    remember();
                  },
                  onSubmitted: (_) {
                    offset = 0;
                    load();
                  },
                ),
              ),
              for (final p in ['今天', '本月', '上月'])
                TextButton(
                  onPressed: locked
                      ? null
                      : () {
                          preset(p);
                          load();
                        },
                  child: Text(p),
                ),
              FilledButton.icon(
                onPressed: locked
                    ? null
                    : () {
                        offset = 0;
                        load();
                      },
                icon: const Icon(Icons.search, size: 18),
                label: const Text('查询'),
              ),
              if (widget.category != null)
                InputChip(
                  label: Text('${categoryLabel(widget.category!)}（含子类）'),
                  onDeleted: locked ? null : widget.onClearCategory,
                ),
            ],
          ),
        ),
        if (busy || exporting) const LinearProgressIndicator(minHeight: 2),
        if (error != null) materialError(error!, retry: load),
        if (exportError != null) materialError(exportError!),
        if (saved != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(saved!),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            dirty
                ? '筛选条件已修改，请查询后导出。'
                : '北京时间 · ${widget.category == null ? '全部分类' : '当前分类及子类'} · 缺失字段留空；退库不冲减原出库明细。',
            style: const TextStyle(fontSize: 12, color: Color(0xff647581)),
          ),
        ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Wrap(
              spacing: 20,
              runSpacing: 4,
              children: [
                Text(
                  '${result!['documents'] ?? 0} 张单据 · ${result!['total'] ?? 0} 条明细',
                ),
                Text(
                  '已知金额 ¥${result!['known_amount'] ?? '0.00'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if ((result!['missing_prices'] as int? ?? 0) > 0)
                  Text(
                    '缺价 ${result!['missing_prices']} 行',
                    style: const TextStyle(color: Color(0xff98601e)),
                  ),
                for (final u in objects(result!['quantities']))
                  Text('${u['quantity']} ${u['unit']}'),
              ],
            ),
          ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    busy
                        ? '正在查询…'
                        : error != null
                        ? '查询未完成，请重试'
                        : '当前日期和分类下没有明细。',
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Scrollbar(
                    controller: horizontal,
                    thumbVisibility: true,
                    notificationPredicate: (n) =>
                        n.metrics.axis == Axis.horizontal,
                    child: SingleChildScrollView(
                      controller: horizontal,
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        controller: vertical,
                        child: DataTable(
                          showCheckboxColumn: false,
                          headingRowHeight: 40,
                          dataRowMinHeight: 48,
                          dataRowMaxHeight: 64,
                          columnSpacing: 16,
                          horizontalMargin: 12,
                          headingRowColor: const WidgetStatePropertyAll(
                            Color(0xffe7edf3),
                          ),
                          columns: [
                            const DataColumn(label: Text('原单')),
                            for (final c in columns)
                              DataColumn(
                                label: SizedBox(
                                  width: c == '名称' || c == '供应商' || c == '工程项目'
                                      ? 180
                                      : c == '序号' || c == '单位'
                                      ? 44
                                      : 100,
                                  child: Text(c),
                                ),
                              ),
                          ],
                          rows: [
                            for (final r in rows)
                              DataRow(
                                onSelectChanged: (_) => open(r),
                                cells: [
                                  DataCell(
                                    TextButton(
                                      onPressed: () => open(r),
                                      child: const Text('查看原单'),
                                    ),
                                  ),
                                  for (var i = 0; i < columns.length; i++)
                                    DataCell(
                                      Tooltip(
                                        message: '${(r['cells'] as List)[i]}',
                                        child: SizedBox(
                                          width: columnWidth(columns[i]),
                                          child: Text(
                                            '${(r['cells'] as List)[i]}'.isEmpty
                                                ? '—'
                                                : '${(r['cells'] as List)[i]}',
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        PaginationBar(
          total: result?['total'] as int? ?? 0,
          offset: offset,
          pageSize: 50,
          busy: locked || dirty,
          onChanged: (v) {
            offset = v;
            load();
          },
        ),
      ],
    );
  }
}
