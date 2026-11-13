import 'package:flutter/material.dart';
import '../../shared/pagination.dart';
import 'dart:math' as math;
import '../../shared/api.dart';
import '../../shared/desktop_sidebar.dart';
import '../../shared/query_toolbar.dart';
import '../../shared/query_control_theme.dart';
import '../process/runtime_chrome.dart';
import 'session.dart';
import 'widgets.dart';
import 'editor.dart';
import 'detail.dart';
import 'category_tree.dart';
import 'navigation.dart';
import 'chain_detail.dart';
import 'category_browser.dart';
import 'period_summary.dart';

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
  Json access = {};
  List<Json> records = [];
  int total = 0, offset = 0, generation = 0;
  bool loading = true, initial = true, moreFilters = false;
  String? error;
  String status = '', owner = '', from = '', to = '', chainKind = '';
  bool categories = true, transfers = false, returns = false;
  int catalogRevision = 0;
  Json? summary, returnSummary;
  Json appliedQuery = {};
  bool get dated => ['inbound', 'outbound'].contains(section);
  bool get categoryEnabled =>
      section != 'applications' &&
      ['catalog', 'inbound', 'outbound'].any(allowed);
  Json? category;
  Json get grants => access['grants'] as Json? ?? {};
  bool allowed(String capability) => grants['materials_$capability'] == true;
  String get section => session.section;
  String get endpoint => switch (section) {
    'catalog' => categories ? 'categories' : 'items',
    'stock' => transfers ? 'transfer' : 'stock',
    'outbound' => returns ? 'return' : 'outbound',
    _ => section,
  };
  final labels = materialSections;
  List<String> get sections => [
    if (allowed('request') || allowed('approve')) 'applications',
    if (allowed('catalog')) 'catalog',
    if (allowed('inbound')) 'inbound',
    if (allowed('inbound') || allowed('outbound') || allowed('catalog'))
      'stock',
    if (allowed('outbound')) 'outbound',
    if (['request', 'approve', 'inbound', 'outbound', 'catalog'].any(allowed))
      'chains',
  ];
  @override
  void initState() {
    super.initState();
    initialize();
  }

  @override
  void dispose() {
    search.dispose();
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
      'returns': returns,
      'categories': categories,
      'transfers': transfers,
      'kind': chainKind,
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
    category = session.selectedCategory;
    categories = v['categories'] as bool? ?? true;
    returns = v['returns'] == true;
    if (dated && !session.filters.containsKey(section)) setPeriod('本月');
    transfers = v['transfers'] == true;
    chainKind = materialText(v, 'kind');
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
      if (from.isNotEmpty &&
          to.isNotEmpty &&
          DateTime.parse(from).compareTo(DateTime.parse(to)) >= 0) {
        throw const FormatException('开始日期不能晚于结束日期');
      }
      final query = <String, dynamic>{
        'search': search.text,
        'status': status,
        'offset': offset,
        'limit': 50,
        if (endpoint == 'categories' &&
            search.text.isEmpty &&
            status != 'deleted')
          'parent_id': '',
        if (owner.isNotEmpty) 'owner_id': owner,
        if (from.isNotEmpty) 'from': from,
        if (to.isNotEmpty) 'until': to,
        if (categoryEnabled && endpoint != 'categories' && category != null)
          'category_id': category!['id'],
        if (section == 'chains') 'kind': chainKind,
      };
      final result = await widget.api.request(
        'GET',
        '$materialsBase/$endpoint',
        query: query,
      );
      if (!mounted || token != generation) return;
      setState(() {
        records = objects(result['items']);
        total = result['total'] as int? ?? 0;
        summary = result['summary'] as Json?;
        returnSummary = result['return_summary'] as Json?;
        appliedQuery = query;
      });
    } catch (e) {
      if (mounted && token == generation) {
        setState(() {
          error = '$e';
          records = [];
          total = 0;
          summary = null;
          returnSummary = null;
        });
      }
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
      summary = null;
      returnSummary = null;
      restoreFilters();
    });
    load();
  }

  Future<void> edit(String kind, {Json seed = const {}}) async {
    final result = await editMaterial(
      context,
      widget.api,
      session,
      kind: kind,
      seed:
          seed.isEmpty && category != null && ['item', 'inbound'].contains(kind)
          ? {
              'category_id': category!['id'],
              'category_name': categoryLabel(category!),
            }
          : seed,
      canCatalog: allowed('catalog'),
    );
    if (mounted) {
      setState(() => catalogRevision++);
      load();
      if (result != null &&
          ['inbound', 'outbound', 'return', 'transfer'].contains(kind)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${materialKind(kind)}已完成 · 单号 ${result['number']}'),
            action: SnackBarAction(
              label: '查看单据',
              onPressed: () => showMaterialDetail(
                context,
                widget.api,
                session,
                kind: 'document',
                record: result,
                access: access,
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> open(Json record) async {
    if (section == 'chains') {
      await showMaterialChain(
        context,
        widget.api,
        session,
        record: record,
        access: access,
      );
      if (mounted) load();
      return;
    }
    if (section == 'catalog') {
      if (categories && record['deleted'] == true) {
        await deleteCategory(record);
        return;
      }
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

  void setPeriod(String preset) {
    final today = DateTime.now().toUtc().add(const Duration(hours: 8));
    final day = DateTime.utc(today.year, today.month, today.day);
    DateTime start = day, end = day.add(const Duration(days: 1));
    if (preset == '本周') start = day.subtract(Duration(days: day.weekday - 1));
    if (preset == '本月') start = DateTime.utc(day.year, day.month);
    if (preset == '上月') {
      start = DateTime.utc(day.year, day.month - 1);
      end = DateTime.utc(day.year, day.month);
    }
    from = preset == '全部'
        ? ''
        : start.subtract(const Duration(hours: 8)).toIso8601String();
    to = preset == '全部'
        ? ''
        : end.subtract(const Duration(hours: 8)).toIso8601String();
    offset = 0;
  }

  String dateLabel(String value, {bool end = false}) => value.isEmpty
      ? (end ? '结束日期' : '开始日期')
      : materialTime(
          DateTime.parse(
            value,
          ).subtract(Duration(days: end ? 1 : 0)).toIso8601String(),
        ).substring(0, 10);
  Future<void> pickDate(bool start) async {
    final value = start ? from : to;
    final parsed = DateTime.tryParse(value)
        ?.toUtc()
        .add(const Duration(hours: 8))
        .subtract(Duration(days: start ? 0 : 1));
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDate: parsed ?? DateTime.now(),
    );
    if (date == null || !mounted) return;
    setState(() {
      final utc = DateTime.utc(
        date.year,
        date.month,
        date.day,
      ).subtract(const Duration(hours: 8));
      if (start) {
        from = utc.toIso8601String();
      } else {
        to = utc.add(const Duration(days: 1)).toIso8601String();
      }
      offset = 0;
    });
  }

  void selectCategory(Json? value) {
    setState(() {
      category = value;
      session.selectedCategory = value;
      offset = 0;
    });
    if (endpoint != 'categories') load();
  }

  Future<void> deleteCategory(Json record) async {
    final changed = await changeMaterialCategoryDeletion(
      context,
      widget.api,
      session,
      record,
      onDependency: (target) {
        saveFilters();
        setState(() {
          session.section = target == 'balances' ? 'stock' : 'catalog';
          restoreFilters();
          category = record;
          session.selectedCategory = record;
          categories = target == 'children';
          transfers = false;
          status = '';
          search.clear();
          offset = 0;
          session.categoryExpanded.add(materialText(record, 'id'));
        });
        load();
      },
    );
    if (!mounted || changed != true) return;
    setState(() {
      catalogRevision++;
      if (category?['id'] == record['id']) {
        category = null;
        session.selectedCategory = null;
      }
    });
    load();
  }

  void expandCategories(bool value) {
    session.categoryDefaultExpanded = value;
    session.categorySeen.clear();
    session.categoryExpanded.clear();
    setState(() {
      catalogRevision++;
    });
    load();
  }

  List<String> get headers => switch (endpoint) {
    'categories' => ['分类路径', '层级', '修订'],
    'items' => ['物料名称', '规格', '单位', '默认分类', '参考单价', '预警值'],
    'stock' => ['物料名称', '规格', '分类', '该类库存', '各类总库存', '单位', '预警'],
    'applications' => ['申请单号', '申请人', '申请内容', '审批状态', '版本', '提交时间'],
    'chains' => ['链路类别', '主单号', '发起人', '内容', '当前状态', '节点数', '最近办理时间'],
    _ => ['单号', '经办人', '时间', '物料明细', '状态', '金额'],
  };
  List<String> row(Json v) => switch (endpoint) {
    'chains' => [
      materialChainKind(materialText(v, 'kind')),
      materialText(v, 'number'),
      materialText(v, 'owner'),
      materialText(v, 'title'),
      materialStatus(materialText(v, 'status')),
      materialText(v, 'node_count'),
      materialTime(v['updated']),
    ],
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
          : '${category != null && v['matched_amount'] != null ? '该分类 ${v['matched_amount']} / 整单 ' : ''}${v['known_amount']}${(v['missing_prices'] as int? ?? 0) > 0 ? '（整单缺价${v['missing_prices']}行）' : ''}',
    ],
  };
  Widget toolbar(double budget) => LayoutBuilder(
    builder: (context, box) {
      final mobile = MediaQuery.sizeOf(context).width < 700;
      final height = mobile ? 44.0 : 34.0;
      final actions = <Widget>[
        if (section == 'applications' && allowed('request'))
          FilledButton.icon(
            onPressed: loading ? null : () => edit('application'),
            icon: const Icon(Icons.add),
            label: const Text('新建申请'),
          ),
        if (section == 'catalog') ...[
          if (categories) ...[
            TextButton(
              onPressed: loading ? null : () => expandCategories(true),
              child: const Text('全部展开'),
            ),
            TextButton(
              onPressed: loading ? null : () => expandCategories(false),
              child: const Text('全部收起'),
            ),
            FilterChip(
              label: const Text('已删除'),
              selected: status == 'deleted',
              onSelected: loading
                  ? null
                  : (v) {
                      setState(() {
                        status = v ? 'deleted' : '';
                        offset = 0;
                      });
                      load();
                    },
            ),
          ],
          ChoiceChip(
            label: const Text('物料档案'),
            selected: !categories,
            onSelected: loading
                ? null
                : (_) {
                    setState(() {
                      categories = false;
                      status = '';
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
        if (section == 'outbound') ...[
          ChoiceChip(
            label: const Text('出库单'),
            selected: !returns,
            onSelected: loading
                ? null
                : (_) {
                    setState(() {
                      returns = false;
                      offset = 0;
                      status = '';
                    });
                    load();
                  },
          ),
          ChoiceChip(
            label: const Text('退库单'),
            selected: returns,
            onSelected: loading
                ? null
                : (_) {
                    setState(() {
                      returns = true;
                      offset = 0;
                      status = '';
                    });
                    load();
                  },
          ),
          FilledButton.icon(
            onPressed: loading ? null : () => edit('outbound'),
            icon: const Icon(Icons.remove_circle_outline),
            label: const Text('新建出库'),
          ),
        ],
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
      ];
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            QueryControlTheme(
              minHeight: height,
              child: SizedBox(
                height: height,
                child: Row(
                  children: [
                    if (session.directoryHidden)
                      IconButton(
                        tooltip: '显示物料目录',
                        icon: const Icon(Icons.menu_open),
                        onPressed: () =>
                            setState(() => session.directoryHidden = false),
                      ),
                    Text(
                      labels[section] ?? '物料管理',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            for (final action in actions)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: action,
                              ),
                          ],
                        ),
                      ),
                    ),
                    MaterialAccountLink(session: session, compact: mobile),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            QueryToolbar(
              maxHeight: math.max(height + 22, budget - height - 22),
              minControlHeight: height,
              fields: [
                SizedBox(
                  width: math.min(300, math.max(150, box.maxWidth - 46)),
                  child: TextField(
                    key: const Key('materials-search'),
                    controller: search,
                    decoration: const InputDecoration(
                      labelText: '搜索单号、物料或内容',
                      isDense: false,
                    ),
                    onSubmitted: (_) {
                      offset = 0;
                      load();
                    },
                  ),
                ),
                if (section == 'applications' ||
                    section == 'outbound' && !returns)
                  SizedBox(
                    width: 150,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('$section-$status'),
                      initialValue: status,
                      decoration: const InputDecoration(
                        labelText: '状态',
                        isDense: false,
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
                if (section == 'chains')
                  SizedBox(
                    width: 170,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('materials-chain-kind-$chainKind'),
                      initialValue: chainKind,
                      decoration: const InputDecoration(
                        labelText: '业务类别',
                        isDense: false,
                      ),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('全部类别')),
                        for (final k in [
                          'application',
                          'inbound',
                          'outbound',
                          'transfer',
                        ])
                          DropdownMenuItem(
                            value: k,
                            child: Text(materialChainKind(k)),
                          ),
                      ],
                      onChanged: (v) {
                        setState(() {
                          chainKind = v ?? '';
                          offset = 0;
                        });
                        load();
                      },
                    ),
                  ),

                if (dated ||
                    moreFilters &&
                        section != 'catalog' &&
                        section != 'stock') ...[
                  OutlinedButton(
                    onPressed: () => pickDate(true),
                    child: Text(dateLabel(from)),
                  ),
                  const Text('至'),
                  OutlinedButton(
                    onPressed: () => pickDate(false),
                    child: Text(dateLabel(to, end: true)),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '快捷时间段（北京时间）',
                    onSelected: (v) {
                      setState(() => setPeriod(v));
                      load();
                    },
                    itemBuilder: (_) => [
                      for (final p in ['今天', '本周', '本月', '上月', '全部'])
                        PopupMenuItem(value: p, child: Text(p)),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('快捷时间段 ▾'),
                    ),
                  ),
                ],
                if (moreFilters && section != 'catalog' && section != 'stock')
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
                if (categoryEnabled &&
                    category != null &&
                    endpoint != 'categories')
                  InputChip(
                    onPressed: () => selectCategory(null),
                    deleteButtonTooltipMessage: '清除分类',
                    label: Text(
                      '${categoryLabel(category!)}（含子类）',
                      overflow: TextOverflow.ellipsis,
                    ),
                    onDeleted: () => selectCategory(null),
                  ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      status = '';
                      owner = '';
                      from = '';
                      to = '';
                      category = null;
                      session.selectedCategory = null;
                      chainKind = '';
                      search.clear();
                      offset = 0;
                    });
                    load();
                  },
                  child: const Text('清除筛选'),
                ),
              ],
              actions: [
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
                  onPressed: loading
                      ? null
                      : () {
                          setState(() => catalogRevision++);
                          load();
                        },
                  icon: const Icon(Icons.refresh),
                ),
                TextButton(
                  onPressed: () => setState(() => moreFilters = !moreFilters),
                  child: Text(moreFilters ? '收起筛选' : '更多筛选'),
                ),
              ],
            ),
          ],
        ),
      );
    },
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
        builder: (context, outer) => Row(
          children: [
            if (!initial &&
                sections.isNotEmpty &&
                !session.directoryHidden) ...[
              SizedBox(
                width: mobile ? 96 : DesktopSidebar.width,
                child: MaterialNavigation(
                  sections: sections,
                  selected: section,
                  categoryBrowser: categoryEnabled
                      ? MaterialCategoryBrowser(
                          api: widget.api,
                          session: session,
                          onSelect: selectCategory,
                          revision: catalogRevision,
                        )
                      : null,
                  compact: mobile,
                  onSelect: select,
                  onHide: () => setState(() => session.directoryHidden = true),
                  onExpand: () => showDialog<void>(
                    context: context,
                    builder: (dialog) => Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 248,
                        child: Material(
                          child: MaterialNavigation(
                            sections: sections,
                            selected: section,
                            onSelect: (value) {
                              Navigator.pop(dialog);
                              select(value);
                            },
                            onHide: () => Navigator.pop(dialog),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
            ],
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => ColoredBox(
                  color: const Color(0xfff6f8fa),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (initial) ...[
                        if (loading) const LinearProgressIndicator(),
                        if (error != null)
                          materialError(error!, retry: initialize),
                      ],
                      if (!initial && sections.isEmpty)
                        const Expanded(
                          child: Center(child: Text('当前账号没有物料业务权限，请联系管理员授权。')),
                        ),
                      if (!initial && sections.isNotEmpty) ...[
                        toolbar(
                          math.min(mobile ? 230 : 190, box.maxHeight * .45),
                        ),
                        if (loading)
                          const LinearProgressIndicator(minHeight: 2),
                        if (error != null) materialError(error!, retry: load),
                        if (dated && !loading && error == null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                            child: Text(
                              '查询范围（北京时间）：${materialText(appliedQuery, 'from').isEmpty ? '不限开始' : dateLabel(materialText(appliedQuery, 'from'))} 至 ${materialText(appliedQuery, 'until').isEmpty ? '不限结束' : dateLabel(materialText(appliedQuery, 'until'), end: true)} · ${category == null ? '全部分类' : '${categoryLabel(category!)}（含子类）'}',
                            ),
                          ),
                        if (summary != null && !loading)
                          MaterialPeriodSummary(
                            summary: summary!,
                            label: '${materialKind(endpoint)}概览',
                            onDetails: () => showMaterialSummary(
                              context,
                              widget.api,
                              '$materialsBase/$endpoint',
                              appliedQuery,
                            ),
                          ),
                        if (returnSummary != null && !loading)
                          MaterialPeriodSummary(
                            summary: returnSummary!,
                            label: '本期发生退库（含往期出库）',
                            secondary: true,
                            onDetails: () => showMaterialSummary(
                              context,
                              widget.api,
                              '$materialsBase/$endpoint',
                              appliedQuery,
                              returns: true,
                            ),
                          ),
                        Expanded(
                          child: endpoint == 'categories'
                              ? MaterialCategoryTree(
                                  key: ValueKey('category-tree-$generation'),
                                  api: widget.api,
                                  roots: records,
                                  session: session,
                                  searchResults:
                                      search.text.isNotEmpty ||
                                      status == 'deleted',
                                  onSelect: selectCategory,
                                  selectedID: category?['id'] as String?,
                                  onDelete: deleteCategory,
                                  onEdit: status == 'deleted'
                                      ? null
                                      : (record) =>
                                            edit('category', seed: record),
                                  onAdd: status == 'deleted'
                                      ? null
                                      : (parent) => edit(
                                          'category',
                                          seed: {
                                            'parent_id': parent['id'],
                                            'parent_name': categoryLabel(
                                              parent,
                                            ),
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
                                      : dated
                                      ? '该时间段和分类下没有单据，请调整日期、清除筛选或新建单据。'
                                      : '暂无记录，请调整筛选或使用上方新建入口。',
                                  statusColumn: endpoint == 'applications'
                                      ? 3
                                      : [
                                          'inbound',
                                          'outbound',
                                          'transfer',
                                          'chains',
                                        ].contains(endpoint)
                                      ? 4
                                      : null,
                                  statuses: records
                                      .map((v) => materialText(v, 'status'))
                                      .toList(),
                                  onSelect: loading
                                      ? null
                                      : (i) => open(records[i]),
                                  initialOffset: session.offsets[endpoint] ?? 0,
                                  onScroll: (v) =>
                                      session.offsets[endpoint] = v,
                                  warningRows: {
                                    for (var i = 0; i < records.length; i++)
                                      if (records[i]['low'] == true) i,
                                  },
                                ),
                        ),
                        PaginationBar(
                          total: total,
                          offset: offset,
                          pageSize: 50,
                          busy: loading,
                          trailing: session.dirty
                              ? const Text(' · 有未提交草稿')
                              : null,
                          onChanged: (v) {
                            offset = v;
                            load();
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
