import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../shared/desktop_sidebar.dart';
import '../../shared/api.dart';
import '../../platform/process_files.dart';
import 'editor.dart';
import 'model.dart';
import 'live_status.dart';
import 'navigation.dart';
import '../process/runtime_chrome.dart';

class EquipmentWorkspace extends StatefulWidget {
  const EquipmentWorkspace({
    super.key,
    required this.api,
    required this.canEdit,
  });
  final PlatformApi api;
  final bool canEdit;
  @override
  State<EquipmentWorkspace> createState() => _EquipmentWorkspaceState();
}

class _EquipmentWorkspaceState extends State<EquipmentWorkspace> {
  late EquipmentLiveStatus live = EquipmentLiveStatus(widget.api);
  final search = TextEditingController();
  final location = TextEditingController();
  final navigationSearch = TextEditingController();
  Timer? debounce;
  List<String> stations = [];
  List<Json> navigation = [];
  String? navigationError;
  Json data = {};
  Json? selected;
  String station = '', site = '', category = '';
  String? error;
  bool loading = true;
  int offset = 0,
      generation = 0,
      detailGeneration = 0,
      navigationGeneration = 0;
  @override
  void initState() {
    super.initState();
    load();
    loadNavigation();
  }

  Future<void> loadNavigation() async {
    final token = ++navigationGeneration;
    try {
      final result = await widget.api.request(
        'GET',
        '/api/v1/equipment-navigation',
      );
      if (mounted && token == navigationGeneration) {
        setState(() {
          navigation = objects(result['nodes']);
          navigationError = null;
        });
      }
    } catch (e) {
      if (mounted && token == navigationGeneration) {
        setState(() {
          navigation = [];
          navigationError = '$e';
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant EquipmentWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      live.dispose();
      live = EquipmentLiveStatus(widget.api);
      selected = null;
      data = {};
      navigation = [];
      detailGeneration++;
      load();
      loadNavigation();
    }
  }

  @override
  void dispose() {
    live.dispose();
    debounce?.cancel();
    search.dispose();
    location.dispose();
    navigationSearch.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final token = ++generation;
    final detailToken = detailGeneration;
    final selectedID = selected?['id'];
    setState(() {
      loading = true;
      error = null;
    });
    live.select([]);
    try {
      final results = await Future.wait([
        widget.api.request(
          'GET',
          '/api/v1/equipment',
          query: {
            'station': station,
            'site': site,
            'category': category,
            'search': search.text,
            'location': location.text.trim(),
            'offset': offset,
            'limit': 50,
          },
        ),
        widget.api.request('GET', '/api/v1/stations'),
      ]);
      Json? freshDetail;
      String? detailError;
      if (selectedID != null) {
        try {
          freshDetail = await widget.api.request(
            'GET',
            '/api/v1/equipment/$selectedID',
          );
        } catch (e) {
          // A removed or no longer authorized record must not remain visible.
          freshDetail = null;
          detailError = '设备详情刷新失败：$e';
        }
      }
      if (!mounted || token != generation) return;
      setState(() {
        data = results[0];
        if (detailToken == detailGeneration && selectedID != null) {
          selected = freshDetail;
          error = detailError;
        }
        if (selected != null) {
          data = {
            ...data,
            'items': [
              for (final item in objects(data['items']))
                item['id'] == selected!['id'] ? selected! : item,
            ],
          };
        }
        stations = objects(
          results[1]['items'],
        ).map((s) => value(s, 'name')).toList();
        loading = false;
      });
      live.select([...objects(data['items']), if (selected != null) selected!]);
    } catch (e) {
      if (mounted && token == generation) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  void filter(VoidCallback update) {
    debounce?.cancel();
    detailGeneration++;
    setState(() {
      update();
      offset = 0;
      selected = null;
    });
    load();
  }

  Widget filterChip(String label, VoidCallback clear) => InputChip(
    label: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    tooltip: label,
    onDeleted: () => filter(clear),
  );

  Future<void> open(Json d, bool wide) async {
    final token = ++detailGeneration;
    try {
      final fresh = await widget.api.request(
        'GET',
        '/api/v1/equipment/${d['id']}',
      );
      if (!mounted || token != detailGeneration) return;
      setState(() {
        selected = fresh;
        data = {
          ...data,
          'items': [
            for (final item in objects(data['items']))
              item['id'] == fresh['id'] ? fresh : item,
          ],
        };
      });
      live.select([...objects(data['items']), fresh]);
      if (!wide) {
        await showDialog<void>(
          context: context,
          builder: (context) => Dialog(
            child: SizedBox(
              width: 440,
              height: 720,
              child: EquipmentDetail(
                live: live,
                api: widget.api,
                device: fresh,
                canEdit: widget.canEdit,
                onEdit: (next) async {
                  Navigator.pop(context);
                  await edit(next);
                },
                onChanged: (next) {
                  selected = next;
                  load();
                },
                onClose: () => Navigator.pop(context),
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> edit([Json? d]) async {
    final saved = await showDialog<Json>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EquipmentEditor(
        api: widget.api,
        stations: stations,
        device: d,
        initialStation: station,
        initialSite: site,
      ),
    );
    if (saved != null && mounted) {
      setState(() => selected = saved);
      await load();
    }
  }

  Widget place(
    String label,
    int count,
    bool active,
    VoidCallback tap, {
    bool child = false,
  }) => DesktopSidebarRow(
    title: label,
    icon: child ? Icons.subdirectory_arrow_right : Icons.apartment_outlined,
    selected: active,
    indent: child ? 16 : 0,
    trailing: Text(
      '$count',
      style: const TextStyle(fontSize: 11, color: DesktopSidebar.muted),
    ),
    onTap: tap,
  );
  Widget tree() {
    final places = objects(data['places']);
    return Container(
      width: DesktopSidebar.width,
      decoration: BoxDecoration(
        color: widget.canEdit ? Colors.white : ProcessStyle.panel,
        border: Border(right: BorderSide(color: ledgerLine)),
      ),
      child: DesktopSidebar(
        title: '站区目录',
        search: DesktopSidebarSearch(
          controller: navigationSearch,
          hint: '搜索目录',
          onChanged: (_) => setState(() {}),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.canEdit)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextButton.icon(
                  onPressed: () async {
                    final saved = await showDialog<bool>(
                      context: context,
                      builder: (_) => EquipmentNavigationEditor(
                        api: widget.api,
                        stations: stations,
                        places: places,
                      ),
                    );
                    if (saved == true) await loadNavigation();
                  },
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('编辑目录'),
                ),
              ),
            if (navigationError != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '目录加载失败，显示默认目录',
                  style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            place(
              '全部设备',
              places.fold(0, (n, p) => n + (p['count'] as int)),
              station.isEmpty,
              () => filter(() {
                station = '';
                site = '';
              }),
            ),
            const Divider(
              height: 12,
              indent: 10,
              endIndent: 10,
              color: ledgerLine,
            ),
            Expanded(
              child: navigation.isNotEmpty
                  ? EquipmentNavigation(
                      nodes: navigation,
                      station: station,
                      site: site,
                      query: navigationSearch.text.trim().toLowerCase(),
                      onOpen: (st, sub) => filter(() {
                        station = st;
                        site = sub;
                      }),
                    )
                  : ListView(
                      children: [
                        for (final st in stations.where(
                          (s) =>
                              (widget.canEdit ||
                                  places.any(
                                    (p) =>
                                        p['station'] == s &&
                                        (p['count'] as int? ?? 0) > 0,
                                  )) &&
                              (navigationSearch.text.trim().isEmpty ||
                                  s.toLowerCase().contains(
                                    navigationSearch.text.trim().toLowerCase(),
                                  ) ||
                                  places.any(
                                    (p) =>
                                        p['station'] == s &&
                                        value(p, 'site').toLowerCase().contains(
                                          navigationSearch.text
                                              .trim()
                                              .toLowerCase(),
                                        ),
                                  )),
                        )) ...[
                          place(
                            st,
                            places
                                .where((p) => p['station'] == st)
                                .fold(0, (n, p) => n + (p['count'] as int)),
                            station == st && site.isEmpty,
                            () => filter(() {
                              station = st;
                              site = '';
                            }),
                          ),
                          for (final p in places.where(
                            (p) =>
                                p['station'] == st &&
                                value(p, 'site').isNotEmpty,
                          ))
                            place(
                              value(p, 'site'),
                              p['count'] as int,
                              station == st && site == p['site'],
                              () => filter(() {
                                station = st;
                                site = value(p, 'site');
                              }),
                              child: true,
                            ),
                        ],
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(
                    Icons.verified_user_outlined,
                    size: 15,
                    color: Color(0xff8a9da9),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      widget.canEdit ? '工程师 · 可维护档案' : '按已授权站区查看',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xff8495a2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: RuntimeStyle.theme(Theme.of(context)),
    child: Material(
      color: widget.canEdit ? const Color(0xfff3f6f8) : RuntimeStyle.paper,
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 1260;
          final showTree = box.maxWidth >= 900;
          final items = objects(data['items']);
          final places = objects(data['places']);
          final summary = <String, int>{
            '登记设备': places.fold(0, (n, p) => n + (p['count'] as int)),
            '所属站区': places.map((p) => p['station']).toSet().length,
            '设备类别': (data['categories'] as List? ?? []).length,
          };
          final content = Row(
            children: [
              if (showTree) tree(),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.all(
                    box.maxWidth < 600 || !widget.canEdit ? 16 : 24,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '设备台账',
                                  style: TextStyle(
                                    fontSize: widget.canEdit ? 25 : 21,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: .5,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  station.isEmpty
                                      ? '设备档案与技术参数'
                                      : '$station${site.isEmpty ? ' · 全部设备' : ' / $site'}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xff7b8e9c),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '刷新台账',
                            onPressed: loading ? null : load,
                            icon: const Icon(Icons.refresh, size: 20),
                          ),
                          if (widget.canEdit)
                            FilledButton.icon(
                              key: const Key('equipment-add'),
                              onPressed: stations.isEmpty ? null : () => edit(),
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('新增设备'),
                            ),
                        ],
                      ),
                      SizedBox(height: widget.canEdit ? 22 : 12),
                      if (!widget.canEdit)
                        Text(
                          summary.entries
                              .map((e) => '${e.key} ${e.value}')
                              .join('   ·   '),
                          style: const TextStyle(
                            fontSize: 12,
                            color: ProcessStyle.muted,
                          ),
                        )
                      else
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final entry in summary.entries)
                                Container(
                                  width: 156,
                                  margin: const EdgeInsets.only(right: 10),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: entry.key == '登记设备'
                                        ? ledgerInk
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: ledgerLine),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          entry.key,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: entry.key == '登记设备'
                                                ? const Color(0xffb5d1dc)
                                                : const Color(0xff7c8f9d),
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '${entry.value}',
                                        style: TextStyle(
                                          fontSize: 24,
                                          fontWeight: FontWeight.w600,
                                          color: entry.key == '登记设备'
                                              ? Colors.white
                                              : ledgerInk,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      SizedBox(height: widget.canEdit ? 20 : 12),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          SizedBox(
                            width: box.maxWidth < 600 ? box.maxWidth - 32 : 240,
                            child: TextField(
                              controller: search,
                              key: const Key('equipment-search'),
                              decoration: const InputDecoration(
                                labelText: '关键词',
                                hintText: '名称、编号、型号…',
                                prefixIcon: Icon(Icons.search, size: 19),
                                filled: true,
                                fillColor: Colors.white,
                              ),
                              onChanged: (_) {
                                debounce?.cancel();
                                debounce = Timer(
                                  const Duration(milliseconds: 300),
                                  () => filter(() {}),
                                );
                              },
                            ),
                          ),
                          SizedBox(
                            width: box.maxWidth < 600 ? box.maxWidth - 32 : 240,
                            child: TextField(
                              controller: location,
                              key: const Key('equipment-location'),
                              decoration: const InputDecoration(
                                labelText: '安装位置',
                                hintText: '包含文字，例如：一层泵房',
                                prefixIcon: Icon(
                                  Icons.place_outlined,
                                  size: 19,
                                ),
                                filled: true,
                                fillColor: Colors.white,
                              ),
                              onChanged: (_) {
                                debounce?.cancel();
                                debounce = Timer(
                                  const Duration(milliseconds: 300),
                                  () => filter(() {}),
                                );
                              },
                            ),
                          ),
                          SizedBox(
                            width: box.maxWidth < 600 ? box.maxWidth - 32 : 240,
                            child: DropdownButtonFormField<String>(
                              key: ValueKey('equipment-category-$category'),
                              initialValue: category,
                              decoration: const InputDecoration(
                                labelText: '设备类别',
                                filled: true,
                                fillColor: Colors.white,
                              ),
                              isExpanded: true,
                              items:
                                  [
                                        '',
                                        ...{
                                          ...equipmentKinds,
                                          ...List<String>.from(
                                            data['categories'] ?? [],
                                          ),
                                        },
                                      ]
                                      .map(
                                        (s) => DropdownMenuItem(
                                          value: s,
                                          child: Text(
                                            s.isEmpty ? '全部设备类别' : s,
                                            style: const TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      )
                                      .toList(),
                              onChanged: (s) =>
                                  filter(() => category = s ?? ''),
                            ),
                          ),
                          if (!showTree)
                            SizedBox(
                              width: box.maxWidth < 600
                                  ? box.maxWidth - 32
                                  : 240,
                              child: DropdownButtonFormField<String>(
                                key: ValueKey('equipment-station-$station'),
                                initialValue: station,
                                decoration: const InputDecoration(
                                  labelText: '所属站区',
                                ),
                                isExpanded: true,
                                items: ['', ...stations]
                                    .map(
                                      (s) => DropdownMenuItem(
                                        value: s,
                                        child: Text(
                                          s.isEmpty ? '全部站区' : s,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (s) => filter(() {
                                  station = s ?? '';
                                  site = '';
                                }),
                              ),
                            ),
                          if (!showTree)
                            SizedBox(
                              width: box.maxWidth < 600
                                  ? box.maxWidth - 32
                                  : 240,
                              child: DropdownButtonFormField<String>(
                                key: ValueKey('equipment-site-$station-$site'),
                                initialValue: site,
                                decoration: const InputDecoration(
                                  labelText: '所属小站',
                                ),
                                isExpanded: true,
                                items:
                                    [
                                          '',
                                          ...{
                                            if (site.isNotEmpty) site,
                                            for (final place in places)
                                              if ((station.isEmpty ||
                                                      place['station'] ==
                                                          station) &&
                                                  value(
                                                    place,
                                                    'site',
                                                  ).isNotEmpty)
                                                value(place, 'site'),
                                          },
                                        ]
                                        .map(
                                          (s) => DropdownMenuItem(
                                            value: s,
                                            child: Text(
                                              s.isEmpty ? '全部小站' : s,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        )
                                        .toList(),
                                onChanged: (s) => filter(() => site = s ?? ''),
                              ),
                            ),
                        ],
                      ),
                      if (station.isNotEmpty ||
                          site.isNotEmpty ||
                          category.isNotEmpty ||
                          search.text.isNotEmpty ||
                          location.text.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (station.isNotEmpty)
                                filterChip('站区：$station', () {
                                  station = '';
                                  site = '';
                                }),
                              if (site.isNotEmpty)
                                filterChip('小站：$site', () => site = ''),
                              if (category.isNotEmpty)
                                filterChip('类别：$category', () => category = ''),
                              if (search.text.isNotEmpty)
                                filterChip('关键词：${search.text}', search.clear),
                              if (location.text.isNotEmpty)
                                filterChip(
                                  '位置：${location.text.trim()}',
                                  location.clear,
                                ),
                              TextButton.icon(
                                key: const Key('equipment-clear-filters'),
                                onPressed: () => filter(() {
                                  station = '';
                                  site = '';
                                  category = '';
                                  search.clear();
                                  location.clear();
                                }),
                                icon: const Icon(
                                  Icons.filter_alt_off_outlined,
                                  size: 16,
                                ),
                                label: const Text('清空筛选'),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 16),
                      if (loading) const LinearProgressIndicator(minHeight: 2),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  error!,
                                  style: const TextStyle(color: Colors.red),
                                ),
                              ),
                              TextButton(
                                onPressed: load,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: Container(
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: widget.canEdit
                                ? Colors.white
                                : const Color(0xfff3f6f8),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: ledgerLine),
                          ),
                          child: LayoutBuilder(
                            builder: (context, tableBox) => Column(
                              children: [
                                Container(
                                  height: 42,
                                  color: const Color(0xfff8fafb),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                  ),
                                  child: Row(
                                    children: [
                                      const Expanded(
                                        flex: 4,
                                        child: Text(
                                          '设备 / 编号',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Color(0xff80929f),
                                          ),
                                        ),
                                      ),
                                      if (tableBox.maxWidth > 540)
                                        const Expanded(
                                          flex: 3,
                                          child: Text(
                                            '所属位置',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Color(0xff80929f),
                                            ),
                                          ),
                                        ),
                                      if (tableBox.maxWidth > 750)
                                        const Expanded(
                                          flex: 2,
                                          child: Text(
                                            '型号规格',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Color(0xff80929f),
                                            ),
                                          ),
                                        ),
                                      const SizedBox(
                                        width: 74,
                                        child: Text(
                                          '实时状态',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Color(0xff80929f),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: items.isEmpty
                                      ? Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(24),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.inventory_2_outlined,
                                                  size: 50,
                                                  color: Color(0xff9cb7c3),
                                                ),
                                                const SizedBox(height: 14),
                                                Text(
                                                  loading
                                                      ? '正在读取设备档案…'
                                                      : '暂无符合条件的设备',
                                                  style: const TextStyle(
                                                    fontSize: 16,
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                Text(
                                                  stations.isEmpty
                                                      ? '请先在开发端建立站区，再登记设备。'
                                                      : '登记站区直属设备，或填写小站名称归档。',
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    color: Color(0xff8396a3),
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        )
                                      : ListView.separated(
                                          itemCount: items.length,
                                          separatorBuilder: (_, _) =>
                                              const Divider(
                                                height: 1,
                                                color: ledgerLine,
                                              ),
                                          itemBuilder: (context, i) {
                                            final d = items[i];
                                            final active =
                                                selected?['id'] == d['id'];
                                            return Material(
                                              color: active
                                                  ? RuntimeStyle.selection
                                                  : Colors.white,
                                              child: InkWell(
                                                onTap: () => open(d, wide),
                                                child: Container(
                                                  height: widget.canEdit
                                                      ? 78
                                                      : 60,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 16,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    border: Border(
                                                      left: BorderSide(
                                                        width: 3,
                                                        color: active
                                                            ? ledgerAccent
                                                            : Colors
                                                                  .transparent,
                                                      ),
                                                    ),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      Expanded(
                                                        flex: 4,
                                                        child: Row(
                                                          children: [
                                                            Container(
                                                              width: 40,
                                                              height: 40,
                                                              decoration: BoxDecoration(
                                                                color:
                                                                    const Color(
                                                                      0xffeff4f6,
                                                                    ),
                                                                borderRadius:
                                                                    BorderRadius.circular(
                                                                      9,
                                                                    ),
                                                              ),
                                                              child: Icon(
                                                                equipmentIcon(
                                                                  value(
                                                                    d,
                                                                    'category',
                                                                  ),
                                                                ),
                                                                size: 23,
                                                                color:
                                                                    const Color(
                                                                      0xff53798c,
                                                                    ),
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              width: 12,
                                                            ),
                                                            Expanded(
                                                              child: Column(
                                                                mainAxisAlignment:
                                                                    MainAxisAlignment
                                                                        .center,
                                                                crossAxisAlignment:
                                                                    CrossAxisAlignment
                                                                        .start,
                                                                children: [
                                                                  Text(
                                                                    value(
                                                                      d,
                                                                      'name',
                                                                    ),
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                    style: const TextStyle(
                                                                      fontSize:
                                                                          13,
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w600,
                                                                    ),
                                                                  ),
                                                                  const SizedBox(
                                                                    height: 6,
                                                                  ),
                                                                  Text(
                                                                    '${d['code']}  ·  ${d['category']}',
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                    style: const TextStyle(
                                                                      fontSize:
                                                                          10,
                                                                      color: Color(
                                                                        0xff8b9ca7,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      if (tableBox.maxWidth >
                                                          540)
                                                        Expanded(
                                                          flex: 3,
                                                          child: Column(
                                                            mainAxisAlignment:
                                                                MainAxisAlignment
                                                                    .center,
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            children: [
                                                              Text(
                                                                value(
                                                                  d,
                                                                  'station',
                                                                ),
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style:
                                                                    const TextStyle(
                                                                      fontSize:
                                                                          12,
                                                                    ),
                                                              ),
                                                              const SizedBox(
                                                                height: 5,
                                                              ),
                                                              Text(
                                                                value(
                                                                      d,
                                                                      'site',
                                                                    ).isEmpty
                                                                    ? '站区直属'
                                                                    : value(
                                                                        d,
                                                                        'site',
                                                                      ),
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: const TextStyle(
                                                                  fontSize: 11,
                                                                  color: Color(
                                                                    0xff8b9ca7,
                                                                  ),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      if (tableBox.maxWidth >
                                                          750)
                                                        Expanded(
                                                          flex: 2,
                                                          child: Text(
                                                            value(
                                                                  d,
                                                                  'model',
                                                                ).isEmpty
                                                                ? '—'
                                                                : value(
                                                                    d,
                                                                    'model',
                                                                  ),
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                const TextStyle(
                                                                  fontSize: 12,
                                                                ),
                                                          ),
                                                        ),
                                                      SizedBox(
                                                        width: 74,
                                                        child: Align(
                                                          alignment: Alignment
                                                              .centerLeft,
                                                          child:
                                                              EquipmentStatusBadge(
                                                                live: live,
                                                                device: d,
                                                              ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                ),
                                Container(
                                  height: 44,
                                  decoration: const BoxDecoration(
                                    border: Border(
                                      top: BorderSide(color: ledgerLine),
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '共 ${data['total'] ?? 0} 台 · 每页 50 台',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Color(0xff8294a0),
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: '上一页',
                                        onPressed: offset > 0 && !loading
                                            ? () {
                                                setState(
                                                  () => offset = (offset - 50)
                                                      .clamp(0, 5000),
                                                );
                                                load();
                                              }
                                            : null,
                                        icon: const Icon(
                                          Icons.chevron_left,
                                          size: 18,
                                        ),
                                      ),
                                      Text(
                                        '${offset ~/ 50 + 1}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                      IconButton(
                                        tooltip: '下一页',
                                        onPressed:
                                            offset + 50 <
                                                    (data['total'] as int? ??
                                                        0) &&
                                                !loading
                                            ? () {
                                                setState(() => offset += 50);
                                                load();
                                              }
                                            : null,
                                        icon: const Icon(
                                          Icons.chevron_right,
                                          size: 18,
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
                      const SizedBox(height: 10),
                      const Text(
                        '按站区归档设备资料，集中查阅技术参数与图片。',
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xff8a9da9),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (wide && selected != null)
                Container(
                  width: (box.maxWidth * .28).clamp(420.0, 520.0),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(left: BorderSide(color: ledgerLine)),
                  ),
                  child: EquipmentDetail(
                    live: live,
                    key: ValueKey(selected!['id']),
                    api: widget.api,
                    device: selected!,
                    canEdit: widget.canEdit,
                    onEdit: edit,
                    onClose: () => setState(() => selected = null),
                    onChanged: (d) {
                      setState(() => selected = d);
                      load();
                    },
                  ),
                ),
            ],
          );
          final minHeight = box.maxWidth < 600 ? 850.0 : 650.0;
          if (box.maxHeight < minHeight) {
            return SingleChildScrollView(
              key: const Key('equipment-compact-scroll'),
              child: SizedBox(height: minHeight, child: content),
            );
          }
          return content;
        },
      ),
    ),
  );
}

class EquipmentDetail extends StatefulWidget {
  const EquipmentDetail({
    super.key,
    required this.api,
    required this.live,
    required this.device,
    required this.canEdit,
    required this.onEdit,
    required this.onChanged,
    required this.onClose,
  });
  final PlatformApi api;
  final EquipmentLiveStatus live;
  final Json device;
  final bool canEdit;
  final Future<void> Function(Json) onEdit;
  final ValueChanged<Json> onChanged;
  final VoidCallback onClose;
  @override
  State<EquipmentDetail> createState() => _EquipmentDetailState();
}

class _EquipmentDetailState extends State<EquipmentDetail> {
  late Json d = widget.device;
  late String photoFit = fitValue(widget.device['photo_fit']);
  static String fitValue(Object? value) =>
      const {'contain', 'cover', 'fill'}.contains(value)
      ? value as String
      : 'contain';
  @override
  void didUpdateWidget(covariant EquipmentDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device != widget.device || oldWidget.api != widget.api) {
      d = widget.device;
      if (oldWidget.api != widget.api ||
          oldWidget.device['id'] != d['id'] ||
          oldWidget.device['photo_fit'] != d['photo_fit']) {
        photoFit = fitValue(d['photo_fit']);
      }
    }
  }

  bool busy = false;
  String? error;
  Future<void> upload() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final f = await pickProcessFile(image: true);
      if (f == null) return;
      final next = await widget.api.request(
        'POST',
        '/api/v1/equipment/${d['id']}/photos',
        body: {
          'revision': d['revision'],
          'name': f.name,
          'data': base64Encode(f.bytes),
        },
      );
      if (mounted) {
        setState(() => d = next);
        widget.onChanged(next);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove(Json p) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('移除此图片？'),
        content: const Text('图片将从当前设备档案中移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final next = await widget.api.request(
        'DELETE',
        '/api/v1/equipment/${d['id']}/photos/${p['id']}',
        body: {'revision': d['revision']},
      );
      if (mounted) {
        setState(() => d = next);
        widget.onChanged(next);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget section(String title) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 14),
    child: Text(
      title,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
    ),
  );
  Widget field(String label, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xff8a9da9)),
          ),
        ),
        Expanded(
          child: SelectableText(
            text.isEmpty ? '—' : text,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 8, 4),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                '设备档案',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: '关闭档案',
              onPressed: widget.onClose,
              icon: const Icon(Icons.close, size: 19),
            ),
          ],
        ),
      ),
      const Divider(height: 1, color: ledgerLine),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
          children: [
            Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: const Color(0xffe9f2f5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    equipmentIcon(value(d, 'category')),
                    color: ledgerAccent,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        value(d, 'name'),
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        value(d, 'code'),
                        style: const TextStyle(
                          color: Color(0xff8a9da9),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: EquipmentStatusBadge(live: widget.live, device: d),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  value(d, 'category'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff8396a3),
                  ),
                ),
              ],
            ),
            section('设备图片'),
            if (objects(d['photos']).isNotEmpty)
              DropdownButtonFormField<String>(
                key: ValueKey(
                  'equipment-preview-fit-${d['id']}-${d['photo_fit']}',
                ),
                initialValue: photoFit,
                decoration: const InputDecoration(
                  labelText: '本次图片显示方式',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 'contain', child: Text('完整显示')),
                  DropdownMenuItem(value: 'cover', child: Text('裁切填满')),
                  DropdownMenuItem(value: 'fill', child: Text('拉伸填满')),
                ],
                onChanged: (v) => setState(() => photoFit = v!),
              ),
            if (objects(d['photos']).isEmpty)
              Container(
                height: 150,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xfff4f7f9),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: ledgerLine),
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.add_photo_alternate_outlined,
                      size: 32,
                      color: Color(0xffb2c4ce),
                    ),
                    SizedBox(height: 8),
                    Text(
                      '暂无设备图片',
                      style: TextStyle(fontSize: 11, color: Color(0xff94a7b4)),
                    ),
                  ],
                ),
              ),
            for (final p in objects(d['photos']))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  children: [
                    EquipmentPhoto(
                      key: ValueKey(p['id']),
                      api: widget.api,
                      deviceID: value(d, 'id'),
                      photo: p,
                      fit: photoFit,
                    ),
                    Row(
                      children: [
                        if (widget.canEdit)
                          Expanded(
                            child: Text(
                              value(p, 'name'),
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xff8294a0),
                              ),
                            ),
                          ),
                        if (widget.canEdit)
                          TextButton(
                            onPressed: busy ? null : () => remove(p),
                            child: const Text(
                              '移除',
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            if (widget.canEdit)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  onPressed: busy || objects(d['photos']).length >= 6
                      ? null
                      : upload,
                  icon: const Icon(Icons.file_upload_outlined, size: 17),
                  label: Text(busy ? '正在处理…' : '上传图片'),
                ),
              ),
            if (widget.canEdit) const SizedBox(height: 5),
            if (widget.canEdit)
              const Text(
                'PNG / JPEG · 每张 ≤ 2 MiB · 最多 6 张',
                style: TextStyle(fontSize: 10, color: Color(0xff91a3af)),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            section('基本信息'),
            for (final e in {
              'station': '所属站区',
              'site': '所属小站',
              'location': '安装位置',
              'manufacturer': '生产厂家',
              'model': '型号规格',
              'serial': '出厂编号',
              'installed': '投运日期',
            }.entries)
              field(
                e.value,
                e.key == 'site' && value(d, 'site').isEmpty
                    ? '站区直属'
                    : value(d, e.key),
              ),
            section('技术属性'),
            if (objects(d['properties']).isEmpty)
              const Text(
                '暂未登记技术属性',
                style: TextStyle(color: Color(0xff91a3af), fontSize: 11),
              ),
            for (final p in objects(d['properties']))
              field(value(p, 'name'), '${p['value']} ${p['unit']}'),
            if (value(d, 'notes').isNotEmpty) ...[
              section('备注'),
              Text(
                value(d, 'notes'),
                style: const TextStyle(fontSize: 12, height: 1.7),
              ),
            ],
            const SizedBox(height: 20),
            Text(
              '最近更新 ${DateTime.tryParse(value(d, 'updated'))?.toLocal().toString().split('.').first ?? '—'}',
              style: const TextStyle(fontSize: 10, color: Color(0xff9baab5)),
            ),
          ],
        ),
      ),
      if (widget.canEdit)
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : () => widget.onEdit(d),
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: const Text('编辑档案'),
            ),
          ),
        ),
    ],
  );
}

class EquipmentPhoto extends StatefulWidget {
  const EquipmentPhoto({
    super.key,
    required this.api,
    required this.deviceID,
    required this.photo,
    this.fit = 'contain',
  });
  final PlatformApi api;
  final String deviceID;
  final Json photo;
  final String fit;
  @override
  State<EquipmentPhoto> createState() => _EquipmentPhotoState();
}

class _EquipmentPhotoState extends State<EquipmentPhoto> {
  late Future<Uint8List> request = fetch();
  Future<Uint8List> fetch() async => base64Decode(
    (await widget.api.request(
          'GET',
          '/api/v1/equipment/${widget.deviceID}/photos/${widget.photo['id']}',
        ))['data']
        as String,
  );
  @override
  void didUpdateWidget(EquipmentPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!mapEquals(oldWidget.photo, widget.photo) ||
        oldWidget.deviceID != widget.deviceID ||
        oldWidget.api != widget.api) {
      request = fetch();
    }
  }

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1.65,
    child: Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xfff2f6f8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ledgerLine),
      ),
      child: FutureBuilder<Uint8List>(
        key: ObjectKey(request),
        future: request,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(() => request = fetch()),
                child: const Text('图片加载失败 · 重试'),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          final bytes = snapshot.data!;
          return InkWell(
            onTap: () => showDialog<void>(
              context: context,
              builder: (c) => Dialog(
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: InteractiveViewer(
                        child: Image.memory(bytes, fit: BoxFit.contain),
                      ),
                    ),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: IconButton(
                        onPressed: () => Navigator.pop(c),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            child: Image.memory(
              bytes,
              fit: switch (widget.fit) {
                'cover' => BoxFit.cover,
                'fill' => BoxFit.fill,
                _ => BoxFit.contain,
              },
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => Center(
                child: TextButton(
                  onPressed: () => setState(() => request = fetch()),
                  child: const Text('图片加载失败 · 重试'),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}
