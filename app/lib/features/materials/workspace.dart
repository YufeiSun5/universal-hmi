import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../shared/api.dart';
import '../process/runtime_chrome.dart';
import 'session.dart';
import 'widgets.dart';
import 'editor.dart';
import 'detail.dart';
import 'category_tree.dart';

class MaterialsWorkspace extends StatefulWidget {
  const MaterialsWorkspace({super.key, required this.api, this.session});
  final PlatformApi api;
  final MaterialsSession? session;
  @override
  State<MaterialsWorkspace> createState() => MaterialsWorkspaceState();
}

class MaterialsWorkspaceState extends State<MaterialsWorkspace> {
  late final session = widget.session ?? MaterialsSession();
  final search = TextEditingController();
  final filtersScroll = ScrollController();
  Json access = {};
  List<Json> records = [];
  int total = 0, offset = 0, generation = 0;
  bool loading = true, initial = true, moreFilters = false;
  String? error;
  String status = '', owner = '', from = '', to = '';
  bool categories = false, transfers = false;
  Json? category;
  Json get grants => access['grants'] as Json? ?? {};
  bool allowed(String capability) => grants['materials_$capability'] == true;
  String get section => session.section;
  String get endpoint => switch (section) {
    'catalog' => categories ? 'categories' : 'items',
    'stock' => transfers ? 'transfer' : 'stock',
    _ => section,
  };
  final labels = const {
    'applications': '申请与审批',
    'catalog': '品类管理',
    'inbound': '入库管理',
    'stock': '库存管理',
    'outbound': '出库管理',
  };
  List<String> get sections => [
    if (allowed('request') || allowed('approve')) 'applications',
    if (allowed('catalog')) 'catalog',
    if (allowed('inbound')) 'inbound',
    if (allowed('inbound') || allowed('outbound') || allowed('catalog'))
      'stock',
    if (allowed('outbound')) 'outbound',
  ];
  @override
  void initState() {
    super.initState();
    initialize();
  }

  @override
  void dispose() {
    search.dispose();
    filtersScroll.dispose();
    if (widget.session == null) session.dispose();
    super.dispose();
  }

  Future<void> initialize() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      access = await widget.api.request('GET', '$materialsBase/capabilities');
      if (!mounted) return;
      initial = false;
      if (sections.isNotEmpty && !sections.contains(section)) {
        session.section = sections.first;
      }
      restoreFilters();
      await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  void saveFilters() {
    session.filters[section] = {
      'search': search.text,
      'status': status,
      'owner': owner,
      'from': from,
      'to': to,
      'offset': offset,
      'category': category,
      'categories': categories,
      'transfers': transfers,
    };
  }

  void restoreFilters() {
    final v = session.filters[section] ?? {};
    search.text = materialText(v, 'search');
    status = materialText(v, 'status');
    owner = materialText(v, 'owner');
    from = materialText(v, 'from');
    to = materialText(v, 'to');
    offset = v['offset'] as int? ?? 0;
    category = v['category'] as Json?;
    categories = v['categories'] == true;
    transfers = v['transfers'] == true;
  }

  Future<void> load() async {
    if (sections.isEmpty) {
      setState(() => loading = false);
      return;
    }
    final token = ++generation;
    saveFilters();
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        'GET',
        '$materialsBase/$endpoint',
        query: {
          'search': search.text,
          'status': status,
          'offset': offset,
          'limit': 50,
          if (endpoint == 'categories' && search.text.isEmpty) 'parent_id': '',
          if (owner.isNotEmpty) 'owner_id': owner,
          if (from.isNotEmpty) 'from': from,
          if (to.isNotEmpty) 'to': to,
          if (category != null) 'category_id': category!['id'],
        },
      );
      if (!mounted || token != generation) return;
      setState(() {
        records = objects(result['items']);
        total = result['total'] as int? ?? 0;
      });
    } catch (e) {
      if (mounted && token == generation) setState(() => error = '$e');
    }
    if (mounted && token == generation) setState(() => loading = false);
  }

  Future<bool> prepareLeave() async {
    if (!session.dirty) return true;
    return materialConfirm(
      context,
      '保留物料草稿并离开？',
      '未提交输入会保留在当前登录会话，返回可继续；刷新或退出会丢失草稿。结果待确认的操作请使用原操作ID重试。',
    );
  }

  Future<void> select(String value) async {
    if (value == section) {
      await load();
      return;
    }
    if (!await prepareLeave() || !mounted) return;
    saveFilters();
    setState(() {
      session.section = value;
      records = [];
      restoreFilters();
    });
    load();
  }

  Future<void> edit(String kind, {Json seed = const {}}) async {
    await editMaterial(
      context,
      widget.api,
      session,
      kind: kind,
      seed: seed,
      canCatalog: allowed('catalog'),
    );
    if (mounted) {
      setState(() {});
      load();
    }
  }

  Future<void> open(Json record) async {
    if (section == 'catalog') {
      await edit(categories ? 'category' : 'item', seed: record);
      return;
    }
    await showMaterialDetail(
      context,
      widget.api,
      session,
      kind: section == 'applications'
          ? 'application'
          : section == 'stock' && !transfers
          ? 'stock'
          : 'document',
      record: record,
      access: access,
    );
    if (mounted) load();
  }

  Future<void> pickDate(bool start) async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    setState(() {
      if (start) {
        from = date.toUtc().toIso8601String();
      } else {
        to = date
            .add(const Duration(days: 1))
            .subtract(const Duration(microseconds: 1))
            .toUtc()
            .toIso8601String();
      }
      offset = 0;
    });
    load();
  }

  List<String> get headers => switch (endpoint) {
    'categories' => ['分类路径', '层级', '修订'],
    'items' => ['物料名称', '规格', '单位', '默认分类', '参考单价', '预警值'],
    'stock' => ['物料名称', '规格', '分类', '该类库存', '各类总库存', '单位', '预警'],
    'applications' => ['申请单号', '申请人', '申请内容', '审批状态', '版本', '提交时间'],
    _ => ['单号', '经办人', '时间', '物料明细', '状态', '金额'],
  };
  List<String> row(Json v) => switch (endpoint) {
    'categories' => [
      categoryLabel(v),
      '${categoryLabel(v).split(' / ').length}',
      '${v['version']}',
    ],
    'items' => [
      materialText(v, 'name'),
      materialText(v, 'specification'),
      materialText(v, 'unit'),
      materialText(v, 'category_name'),
      materialText(v, 'price').isEmpty ? '未填' : materialText(v, 'price'),
      materialText(v, 'warning'),
    ],
    'stock' => [
      materialText(v, 'name'),
      materialText(v, 'specification'),
      materialText(v, 'stock_category'),
      materialText(v, 'quantity'),
      materialText(v, 'total_quantity'),
      materialText(v, 'unit'),
      v['low'] == true ? '低库存（≤${v['warning']}）' : '正常',
    ],
    'applications' => [
      materialText(v, 'number'),
      materialText(v, 'owner'),
      materialText(v, 'text'),
      materialStatus(materialText(v, 'status')),
      '${v['version']}',
      materialTime(v['submitted']),
    ],
    _ => [
      materialText(v, 'number'),
      materialText(v, 'owner'),
      materialTime(v['created']),
      objects(
        v['lines'],
      ).map((l) => '${l['name']} ${l['quantity']} ${l['unit']}').join('；'),
      materialStatus(materialText(v, 'status')),
      materialText(v, 'known_amount').isEmpty
          ? '—'
          : '${v['known_amount']}${(v['missing_prices'] as int? ?? 0) > 0 ? '（缺价${v['missing_prices']}行）' : ''}',
    ],
  };
  Widget toolbar() => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              labels[section] ?? '物料管理',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (section == 'applications' && allowed('request'))
              FilledButton.icon(
                onPressed: loading ? null : () => edit('application'),
                icon: const Icon(Icons.add),
                label: const Text('新建申请'),
              ),
            if (section == 'catalog') ...[
              ChoiceChip(
                label: const Text('物料档案'),
                selected: !categories,
                onSelected: loading
                    ? null
                    : (_) {
                        setState(() {
                          categories = false;
                          offset = 0;
                        });
                        load();
                      },
              ),
              ChoiceChip(
                label: const Text('分类层级'),
                selected: categories,
                onSelected: loading
                    ? null
                    : (_) {
                        setState(() {
                          categories = true;
                          offset = 0;
                        });
                        load();
                      },
              ),
              FilledButton.icon(
                onPressed: loading
                    ? null
                    : () => edit(categories ? 'category' : 'item'),
                icon: const Icon(Icons.add),
                label: Text(categories ? '新建分类' : '新建物料'),
              ),
            ],
            if (section == 'inbound')
              FilledButton.icon(
                onPressed: loading ? null : () => edit('inbound'),
                icon: const Icon(Icons.add),
                label: const Text('新建入库'),
              ),
            if (section == 'outbound')
              FilledButton.icon(
                onPressed: loading ? null : () => edit('outbound'),
                icon: const Icon(Icons.remove_circle_outline),
                label: const Text('新建出库'),
              ),
            if (section == 'stock' && allowed('catalog')) ...[
              ChoiceChip(
                label: const Text('当前库存'),
                selected: !transfers,
                onSelected: loading
                    ? null
                    : (_) {
                        setState(() {
                          transfers = false;
                          offset = 0;
                        });
                        load();
                      },
              ),
              ChoiceChip(
                label: const Text('转类记录'),
                selected: transfers,
                onSelected: loading
                    ? null
                    : (_) {
                        setState(() {
                          transfers = true;
                          offset = 0;
                        });
                        load();
                      },
              ),
              OutlinedButton(
                onPressed: loading ? null : () => edit('transfer'),
                child: const Text('转移库存'),
              ),
            ],
            MaterialAccountLink(session: session),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, box) => Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: box.maxWidth < 500 ? box.maxWidth : 300,
                child: TextField(
                  key: const Key('materials-search'),
                  controller: search,
                  decoration: const InputDecoration(
                    labelText: '搜索单号、物料或内容',
                    isDense: true,
                  ),
                  onSubmitted: (_) {
                    offset = 0;
                    load();
                  },
                ),
              ),
              if (section == 'applications' || section == 'outbound')
                SizedBox(
                  width: 150,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('$section-$status'),
                    initialValue: status,
                    decoration: const InputDecoration(
                      labelText: '状态',
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('全部状态')),
                      for (final value
                          in section == 'applications'
                              ? ['pending', 'approved', 'rejected']
                              : ['not_returned', 'part_returned', 'returned'])
                        DropdownMenuItem(
                          value: value,
                          child: Text(materialStatus(value)),
                        ),
                    ],
                    onChanged: loading
                        ? null
                        : (v) {
                            setState(() {
                              status = v ?? '';
                              offset = 0;
                            });
                            load();
                          },
                  ),
                ),
              FilledButton(
                onPressed: loading
                    ? null
                    : () {
                        offset = 0;
                        load();
                      },
                child: const Text('查询'),
              ),
              IconButton(
                tooltip: '刷新列表',
                onPressed: loading ? null : load,
                icon: const Icon(Icons.refresh),
              ),
              TextButton(
                onPressed: () => setState(() => moreFilters = !moreFilters),
                child: Text(moreFilters ? '收起筛选' : '更多筛选'),
              ),
            ],
          ),
        ),
        if (moreFilters)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (section != 'catalog' && section != 'stock') ...[
                  OutlinedButton(
                    onPressed: () => pickDate(true),
                    child: Text(
                      from.isEmpty
                          ? '开始日期'
                          : materialTime(from).substring(0, 10),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => pickDate(false),
                    child: Text(
                      to.isEmpty ? '结束日期' : materialTime(to).substring(0, 10),
                    ),
                  ),
                  FilterChip(
                    label: const Text('仅本人办理'),
                    selected: owner.isNotEmpty,
                    onSelected: (v) {
                      setState(() {
                        owner = v ? materialText(access, 'user_id') : '';
                        offset = 0;
                      });
                      load();
                    },
                  ),
                ],
                if (section == 'stock' && !transfers ||
                    section == 'catalog' && !categories)
                  OutlinedButton(
                    onPressed: () async {
                      final selected = await pickMaterialRecord(
                        context,
                        widget.api,
                        title: '按分类筛选',
                        endpoint: '$materialsBase/categories',
                        label: categoryLabel,
                      );
                      if (selected != null && mounted) {
                        setState(() {
                          category = selected;
                          offset = 0;
                        });
                        load();
                      }
                    },
                    child: Text(
                      category == null ? '选择分类' : categoryLabel(category!),
                    ),
                  ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      status = '';
                      owner = '';
                      from = '';
                      to = '';
                      category = null;
                      search.clear();
                      offset = 0;
                    });
                    load();
                  },
                  child: const Text('清除筛选'),
                ),
              ],
            ),
          ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final mobile = MediaQuery.sizeOf(context).width < 700;
    final base = RuntimeStyle.theme(Theme.of(context));
    final theme = base.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: base.filledButtonTheme.style?.copyWith(
          minimumSize: WidgetStatePropertyAll(Size(64, mobile ? 44 : 34)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: base.outlinedButtonTheme.style?.copyWith(
          minimumSize: WidgetStatePropertyAll(Size(64, mobile ? 44 : 34)),
        ),
      ),
    );
    return Theme(
      data: theme,
      child: LayoutBuilder(
        builder: (context, box) => ColoredBox(
          color: const Color(0xfff6f8fa),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (initial) ...[
                if (loading) const LinearProgressIndicator(),
                if (error != null) materialError(error!, retry: initialize),
              ],
              if (!initial && sections.isEmpty)
                const Expanded(
                  child: Center(child: Text('当前账号没有物料业务权限，请联系管理员授权。')),
                ),
              if (!initial && sections.isNotEmpty) ...[
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        for (final value in sections)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              key: ValueKey('materials-section-$value'),
                              label: Text(labels[value]!),
                              selected: section == value,
                              onSelected: (_) => select(value),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.min(
                      mobile ? 190 : 150,
                      box.maxHeight * .45,
                    ),
                  ),
                  child: Scrollbar(
                    controller: filtersScroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: filtersScroll,
                      child: toolbar(),
                    ),
                  ),
                ),
                if (loading) const LinearProgressIndicator(minHeight: 2),
                if (error != null) materialError(error!, retry: load),
                Expanded(
                  child: endpoint == 'categories' && search.text.isEmpty
                      ? MaterialCategoryTree(
                          key: ValueKey('category-tree-$generation'),
                          api: widget.api,
                          roots: records,
                          session: session,
                          onEdit: (record) => edit('category', seed: record),
                          onAdd: (parent) => edit(
                            'category',
                            seed: {
                              'parent_id': parent['id'],
                              'parent_name': categoryLabel(parent),
                            },
                          ),
                        )
                      : MaterialTable(
                          key: ValueKey('$section-$endpoint'),
                          headers: headers,
                          rows: records.map(row).toList(),
                          empty: loading
                              ? '正在查询…'
                              : error != null
                              ? '查询未完成，请重试'
                              : '暂无记录',
                          statusColumn: endpoint == 'applications'
                              ? 3
                              : [
                                  'inbound',
                                  'outbound',
                                  'transfer',
                                ].contains(endpoint)
                              ? 4
                              : null,
                          statuses: records
                              .map((v) => materialText(v, 'status'))
                              .toList(),
                          onSelect: loading ? null : (i) => open(records[i]),
                          initialOffset: session.offsets[endpoint] ?? 0,
                          onScroll: (v) => session.offsets[endpoint] = v,
                          warningRows: {
                            for (var i = 0; i < records.length; i++)
                              if (records[i]['low'] == true) i,
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '共 $total 条${session.dirty ? ' · 有未提交草稿' : ''}',
                        ),
                      ),
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
                      Text('${offset ~/ 50 + 1}'),
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
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
