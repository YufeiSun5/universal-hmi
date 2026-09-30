import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'shared/api.dart';

void main() => runApp(const UniversalHmiApp());

class UniversalHmiApp extends StatefulWidget {
  const UniversalHmiApp({super.key, this.api});

  final PlatformApi? api;

  @override
  State<UniversalHmiApp> createState() => _UniversalHmiAppState();
}

class _UniversalHmiAppState extends State<UniversalHmiApp> {
  bool _dark = true;
  late final PlatformApi _api;

  @override
  void initState() {
    super.initState();
    const configured = String.fromEnvironment('API_BASE_URL');
    final base = configured.isNotEmpty
        ? Uri.parse(configured)
        : kIsWeb
            ? Uri.base
            : Uri.parse('http://127.0.0.1:18080');
    _api = widget.api ?? PlatformClient(base);
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff4175df),
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: colors,
      useMaterial3: true,
      brightness: brightness,
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: colors.surface,
      dividerTheme: DividerThemeData(color: colors.outlineVariant, thickness: 1),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      dataTableTheme: const DataTableThemeData(
        headingRowHeight: 40,
        dataRowMinHeight: 40,
        dataRowMaxHeight: 44,
        columnSpacing: 24,
        horizontalMargin: 16,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '通用临时上位机平台',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
        home: Workspace(
          api: _api,
          dark: _dark,
          onThemeChanged: () => setState(() => _dark = !_dark),
        ),
      );
}

class Workspace extends StatefulWidget {
  const Workspace({
    super.key,
    required this.api,
    required this.dark,
    required this.onThemeChanged,
  });

  final PlatformApi api;
  final bool dark;
  final VoidCallback onThemeChanged;

  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  int _section = 0;
  bool _loading = true;
  bool _online = false;
  String? _error;
  String _query = '';
  List<PointDefinition> _points = [];

  static const _labels = ['点位管理', '条件事件', '独立存储', '图表分析', 'Excel 报表'];
  static const _icons = [
    Icons.table_chart_outlined,
    Icons.bolt_outlined,
    Icons.storage_outlined,
    Icons.show_chart,
    Icons.description_outlined,
  ];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      await widget.api.checkHealth();
      final points = await widget.api.listPoints();
      if (!mounted) return;
      setState(() {
        _points = points;
        _online = true;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _online = false;
        _error = '后端连接不可用。已显示的配置可能不是最新版本。';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addPoint() async {
    final point = await showDialog<PointDefinition>(
      context: context,
      builder: (_) => AddPointDialog(api: widget.api),
    );
    if (point == null || !mounted) return;
    setState(() => _points = [..._points, point]);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('点位配置已保存；实时采集尚未启用。')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.outlineVariant)),
              ),
              child: Row(
                children: [
                  Icon(Icons.hub_outlined, size: 20, color: colors.primary),
                  const SizedBox(width: 10),
                  const Text('Universal HMI',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 16),
                  const Text('通用临时上位机平台'),
                  const Spacer(),
                  IconButton(
                    tooltip: widget.dark ? '浅色主题' : '深色主题',
                    onPressed: widget.onThemeChanged,
                    icon: Icon(widget.dark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  NavigationRail(
                    selectedIndex: _section,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (value) =>
                        setState(() => _section = value),
                    destinations: List.generate(
                      _labels.length,
                      (index) => NavigationRailDestination(
                        icon: Icon(_icons[index]),
                        label: Text(_labels[index]),
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(_labels[_section],
                                  style: Theme.of(context).textTheme.titleLarge),
                              const Spacer(),
                              IconButton(
                                tooltip: '刷新',
                                onPressed: _loading ? null : _reload,
                                icon: const Icon(Icons.refresh),
                              ),
                              if (_section == 0)
                                FilledButton.icon(
                                  onPressed: _online ? _addPoint : null,
                                  icon: const Icon(Icons.add, size: 18),
                                  label: const Text('添加点位'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(_error!,
                                  style: TextStyle(color: colors.error)),
                            ),
                          if (_loading) const LinearProgressIndicator(),
                          Expanded(
                            child: _section == 0
                                ? _pointTable(context)
                                : _futureWorkspace(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.outlineVariant)),
              ),
              child: Row(
                children: [
                  Icon(_online ? Icons.link : Icons.link_off, size: 14),
                  const SizedBox(width: 6),
                  Text(_online ? '后端已连接' : '后端未连接'),
                  const SizedBox(width: 24),
                  Text('点位配置 ${_points.length}'),
                  const Spacer(),
                  const Text('实时采集未启用'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pointTable(BuildContext context) {
    final rows = _points.where((point) =>
        '${point.station} ${point.name} ${point.unit}'
            .toLowerCase()
            .contains(_query.toLowerCase()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          decoration: const InputDecoration(
            hintText: '搜索站点、点位或单位',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _points.isEmpty
              ? const Center(
                  child: Text('添加第一个点位，开始建立工程数据配置。'),
                )
              : LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: math.max(960.0, constraints.maxWidth),
                      child: SingleChildScrollView(
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('站点')),
                            DataColumn(label: Text('点位')),
                            DataColumn(label: Text('类型')),
                            DataColumn(label: Text('来源')),
                            DataColumn(label: Text('单位')),
                            DataColumn(label: Text('倍率 / 偏移')),
                          ],
                          rows: rows
                              .map((point) => DataRow(cells: [
                                    DataCell(Text(point.station)),
                                    DataCell(Text(point.name)),
                                    DataCell(Text(point.dataType)),
                                    DataCell(Text(point.sourceType)),
                                    DataCell(Text(point.unit)),
                                    DataCell(Text(
                                        '${point.scaleFactor} / ${point.offset}')),
                                  ]))
                              .toList(),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _futureWorkspace(BuildContext context) {
    const descriptions = [
      '',
      '组合点位条件、持续时间与事件动作，统一管理下设和存储。',
      '按周期、变化或条件配置独立存储，查询历史与采集质量。',
      '查看实时与历史趋势，比较曲线并筛选时间区间。',
      '导入工作表、映射数据列、筛选分析并导出报表。',
    ];
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(descriptions[_section]),
            const SizedBox(height: 12),
            Text('此功能尚未启用。',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class AddPointDialog extends StatefulWidget {
  const AddPointDialog({super.key, required this.api});

  final PlatformApi api;

  @override
  State<AddPointDialog> createState() => _AddPointDialogState();
}

class _AddPointDialogState extends State<AddPointDialog> {
  final _form = GlobalKey<FormState>();
  final _station = TextEditingController();
  final _name = TextEditingController();
  final _unit = TextEditingController();
  final _scale = TextEditingController(text: '1');
  final _offset = TextEditingController(text: '0');
  String _type = 'FLOAT';
  String _source = 'manual';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in [_station, _name, _unit, _scale, _offset]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '请填写此项' : null;

  String? _number(String? value, {bool nonzero = false}) {
    final number = double.tryParse(value ?? '');
    if (number == null || !number.isFinite || (nonzero && number == 0)) {
      return nonzero ? '请输入非零有限数字' : '请输入有限数字';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final point = await widget.api.addPoint({
        'station': _station.text.trim(),
        'name': _name.text.trim(),
        'unit': _unit.text.trim(),
        'data_type': _type,
        'source_type': _source,
        'scale_factor': double.parse(_scale.text),
        'offset': double.parse(_offset.text),
      });
      if (!mounted) return;
      Navigator.of(context).pop(point);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_saving,
        child: AlertDialog(
          title: const Text('添加点位'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      key: const Key('point-station'),
                      controller: _station,
                      autofocus: true,
                      maxLength: 128,
                      decoration: const InputDecoration(labelText: '站点'),
                      validator: _required,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const Key('point-name'),
                      controller: _name,
                      maxLength: 256,
                      decoration: const InputDecoration(labelText: '点位名称'),
                      validator: _required,
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _type,
                      decoration: const InputDecoration(labelText: '数据类型'),
                      items: ['FLOAT', 'INT', 'BOOL', 'STRING']
                          .map((value) => DropdownMenuItem(
                              value: value, child: Text(value)))
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _type = value ?? 'FLOAT'),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: _source,
                      decoration: const InputDecoration(labelText: '来源类型'),
                      items: const [
                        DropdownMenuItem(value: 'manual', child: Text('手工点')),
                        DropdownMenuItem(value: 'virtual', child: Text('虚拟点')),
                      ],
                      onChanged: (value) =>
                          setState(() => _source = value ?? 'manual'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _unit,
                      decoration: const InputDecoration(labelText: '单位'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _scale,
                      decoration: const InputDecoration(labelText: '缩放倍率'),
                      validator: (value) => _number(value, nonzero: true),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _offset,
                      decoration: const InputDecoration(labelText: '偏移'),
                      validator: _number,
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(_error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '保存配置'),
            ),
          ],
        ),
      );
}
