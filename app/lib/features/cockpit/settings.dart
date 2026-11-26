import 'package:flutter/material.dart';
import '../../platform/process_files.dart';
import '../../platform/save.dart';
import '../../shared/api.dart';
import 'config_transfer.dart';
import 'workspace.dart';

class CockpitSettings extends StatefulWidget {
  const CockpitSettings({super.key, required this.api});
  final PlatformApi api;

  @override
  State<CockpitSettings> createState() => _CockpitSettingsState();
}

class _CockpitSettingsState extends State<CockpitSettings> {
  final form = GlobalKey<FormState>();
  final title = TextEditingController();
  final delay = TextEditingController();
  final offline = TextEditingController();
  final latitude = TextEditingController();
  final longitude = TextEditingController();
  final weatherHost = TextEditingController();
  final weatherKey = TextEditingController();
  final zones = <String, TextEditingController>{};
  Map<String, num> ratedMW = {};
  final rankNames = <String, TextEditingController>{};
  static const areaLabels = {
    'heat': '热',
    'electricity': '电',
    'water': '水',
    'water_zone': '分区水',
  };
  final rankAreas = {
    for (final metric in areaLabels.keys)
      metric: <String, TextEditingController>{},
  };
  List<Json> options = [], sources = [];
  List<Json> heatSites = [], energySites = [];
  List<Json> waterZones = [];
  String? waterZonesError;
  int waterZonesRequest = 0;

  List<Json> areaSites(String metric) => switch (metric) {
    'heat' => heatSites,
    'water_zone' => [
      ...waterZones,
      for (final input in rankAreas['water_zone']!.entries)
        if (input.value.text.trim().isNotEmpty &&
            !waterZones.any((zone) => zone['code'] == input.key))
          {'code': input.key, 'name': '已配置站区'},
    ],
    _ => energySites,
  };
  List<String> rows = [];
  Set<String> power = {};
  int revision = 0;
  int formVersion = 0;
  String source = '';
  String? message;
  bool busy = true, ready = false, failed = false;
  bool hasWeatherKey = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in [
      title,
      delay,
      offline,
      latitude,
      longitude,
      weatherHost,
      weatherKey,
      ...zones.values,
      ...rankNames.values,
      for (final areas in rankAreas.values) ...areas.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final result = await Future.wait([
        widget.api.request('GET', cockpitPath),
        widget.api.request('GET', '/api/v1/live-overview'),
        widget.api.request('GET', '/api/v1/external/screens'),
      ]);
      if (!mounted) return;
      final config = result[0];
      setState(() {
        options = objects(result[1]['rows']);
        sources = objects(
          result[2]['items'],
        ).where((r) => r['kind'] == 'energy').toList();
        revision = config['revision'] as int;
        heatSites = objects(config['heat_sites']);
        energySites = objects(config['energy_sites']);
        applyWeatherSettings(config);
        applyDraft(config);
        ready = true;
        failed = false;
      });
      await loadWaterZones();
    } catch (e) {
      if (mounted) {
        setState(() {
          message = '$e';
          failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> loadWaterZones() async {
    final request = ++waterZonesRequest;
    final id = source.isNotEmpty
        ? source
        : sources.length == 1
        ? '${sources.single['id']}'
        : '';
    setState(() {
      waterZones = [];
      waterZonesError = id.isEmpty ? '请选择能耗数据画面' : null;
    });
    if (id.isEmpty) return;
    try {
      final data = await widget.api.request(
        'GET',
        '/api/v1/external/screens/$id/stations',
        query: const {'scope': 'water_zones'},
      );
      if (mounted && request == waterZonesRequest) {
        setState(() => waterZones = objects(data['items']));
      }
    } catch (_) {
      if (mounted && request == waterZonesRequest) {
        setState(() => waterZonesError = '站区目录暂不可用');
      }
    }
  }

  void applyWeatherSettings(Json config) {
    weatherHost.text = config['weather_host'] as String? ?? '';
    weatherKey.clear();
    hasWeatherKey = config['has_weather_key'] == true;
  }

  void applyDraft(Json config, {bool preserveWaterZones = false}) {
    title.text = '${config['title']}';
    delay.text = '${config['delay_minutes']}';
    offline.text = '${config['offline_minutes']}';
    latitude.text = config['latitude']?.toString() ?? '';
    longitude.text = config['longitude']?.toString() ?? '';
    source = config['energy_screen']?.toString() ?? '';
    rows = (config['focus_rows'] as List? ?? []).cast<String>().toList();
    power = (config['power_rows'] as List? ?? []).cast<String>().toSet();
    updateInputs(zones, config['zone_codes'] as Map?);
    ratedMW = (config['rated_mw'] as Map? ?? const {}).cast<String, num>();
    if (config['rank_names'] case final Map names) {
      updateInputs(rankNames, names);
    }
    final areas = config['rank_areas_m2'] as Map?;
    final legacy = config['rank_area_m2'] as Map? ?? const {};
    for (final metric in areaLabels.keys) {
      if (metric == 'water_zone') {
        final saved = areas?[metric] as Map?;
        if (saved != null || !preserveWaterZones) {
          updateInputs(rankAreas[metric]!, saved);
        }
        continue;
      }
      updateInputs(
        rankAreas[metric]!,
        areas?[metric] as Map? ??
            {
              for (final site in areaSites(metric))
                if (site['confirm_area'] != true &&
                    legacy.containsKey(site['code']))
                  site['code']: legacy[site['code']],
            },
      );
    }
    formVersion++;
  }

  void updateInputs(Map<String, TextEditingController> inputs, Map? values) {
    for (final entry in inputs.entries) {
      entry.value.text = values?[entry.key]?.toString() ?? '';
    }
    if (values != null) {
      for (final entry in values.entries) {
        inputs.putIfAbsent(
          entry.key as String,
          () => TextEditingController(text: '${entry.value}'),
        );
      }
    }
  }

  Json? readDraft() {
    if (!(form.currentState?.validate() ?? false)) return null;
    final delayed = int.parse(delay.text.trim());
    final disconnected = int.parse(offline.text.trim());
    if (delayed >= disconnected) {
      setState(() {
        failed = true;
        message = '离线阈值须大于延迟阈值';
      });
      return null;
    }
    final areas = <String, Map<String, double>>{};
    for (final metric in areaLabels.keys) {
      final values = <String, double>{};
      areas[metric] = values;
      for (final row in areaSites(metric)) {
        final code = row['code'] as String;
        final value = rankAreas[metric]![code]?.text.trim() ?? '';
        if (value.isEmpty) continue;
        final area = double.tryParse(value);
        if (area == null || !area.isFinite || area <= 0) {
          setState(() {
            failed = true;
            message = '${row['name']}的${areaLabels[metric]}面积须大于零（㎡）';
          });
          return null;
        }
        values[code] = area;
      }
    }
    return {
      'title': title.text.trim(),
      'rank_areas_m2': areas,
      'energy_screen': source,
      'delay_minutes': delayed,
      'offline_minutes': disconnected,
      'latitude': double.tryParse(latitude.text.trim()),
      'longitude': double.tryParse(longitude.text.trim()),
      'focus_rows': rows.toList(),
      'power_rows': power.toList()..sort(),
      'zone_codes': {
        for (final id in rows)
          if (zones[id]?.text.trim().isNotEmpty ?? false)
            id: zones[id]!.text.trim(),
      },
      'rated_mw': {for (final group in selectedGroups) group: ?ratedMW[group]},
      'rank_names': {
        for (final entry in rankNames.entries)
          if (entry.value.text.trim().isNotEmpty)
            entry.key: entry.value.text.trim(),
      },
    };
  }

  Future<void> save() async {
    final draft = readDraft();
    if (draft == null) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final saved = await widget.api.request(
        'PUT',
        cockpitPath,
        body: {
          'revision': revision,
          ...draft,
          'weather_host': weatherHost.text.trim(),
          if (weatherKey.text.trim().isNotEmpty)
            'weather_api_key': weatherKey.text.trim(),
        },
      );
      if (mounted) {
        setState(() {
          revision = saved['revision'] as int;
          applyWeatherSettings(saved);
          failed = false;
          message = '驾驶舱配置已保存';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          message = '$e';
          failed = true;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> transfer({required bool importing}) async {
    final draft = importing ? null : readDraft();
    if (!importing && draft == null) return;
    setState(() {
      busy = true;
      failed = false;
      message = null;
    });
    try {
      if (importing) {
        final file = await pickProcessFile(
          image: false,
          jsonLabel: '驾驶舱配置 JSON',
        );
        if (file == null || !mounted) return;
        final incoming = decodeCockpitConfig(file.bytes);
        checkReferences(incoming);
        setState(() {
          applyDraft(incoming, preserveWaterZones: true);
          message = '已导入 ${file.name}，核对后点击保存生效';
        });
        await loadWaterZones();
      } else {
        final saved = await saveFile(encodeCockpitConfig(draft!), '驾驶舱配置.json');
        if (saved && mounted) setState(() => message = '已导出驾驶舱配置草稿');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          failed = true;
          message = e is FormatException ? e.message : '$e';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void checkReferences(Json draft) {
    final screen = draft['energy_screen'] as String;
    if (screen.isNotEmpty && !sources.any((row) => row['id'] == screen)) {
      throw const FormatException('当前工程找不到文件引用的能耗画面');
    }
    final powerIds = (draft['power_rows'] as List).toSet();
    final ids = {...draft['focus_rows'] as List, ...powerIds};
    final knownIds = options.map((row) => row['id']).toSet();
    if (!knownIds.containsAll(ids)) {
      throw const FormatException('当前工程缺少文件引用的总览站区');
    }
    final groups = options
        .where((row) => powerIds.contains(row['id']))
        .map(groupName)
        .toSet();
    if (!groups.containsAll((draft['rated_mw'] as Map).keys)) {
      throw const FormatException('额定功率对应的站所与汇总计量行不匹配');
    }
    final areas = draft['rank_areas_m2'] as Map?;
    for (final metric in areaLabels.keys) {
      if (metric == 'water_zone') continue;
      final allowed = areaSites(metric).map((row) => row['code']).toSet();
      if (!allowed.containsAll((areas?[metric] as Map? ?? const {}).keys)) {
        throw FormatException('${areaLabels[metric]}面积含不在当前计量名单内的编码');
      }
    }
  }

  void preview() {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(20),
        backgroundColor: const Color(0xff06132d),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: '关闭预览',
                onPressed: () => Navigator.pop(context),
                color: Colors.white,
                icon: const Icon(Icons.close),
              ),
            ),
            Expanded(child: CockpitWorkspace(api: widget.api)),
          ],
        ),
      ),
    );
  }

  String describe(Json row) => [
    row['site'],
    row['name'],
    row['area'],
  ].where((v) => v?.toString().trim().isNotEmpty == true).join(' · ');

  String groupName(Json row) => row['site']?.toString().isNotEmpty == true
      ? '${row['site']}'
      : '${row['name']}';

  List<String> get selectedGroups =>
      options
          .where((row) => power.contains(row['id']))
          .map(groupName)
          .toSet()
          .toList()
        ..sort();

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return Center(
        child: busy
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(message ?? '驾驶舱配置暂不可用'),
                  TextButton(onPressed: load, child: const Text('重试')),
                ],
              ),
      );
    }
    final choices = {for (final row in options) '${row['id']}': describe(row)};
    return LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('驾驶舱配置', style: Theme.of(context).textTheme.titleLarge),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => transfer(importing: true),
                      icon: const Icon(Icons.upload_file_outlined),
                      label: const Text('导入 JSON'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : () => transfer(importing: false),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('导出 JSON'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : preview,
                      icon: const Icon(Icons.visibility_outlined),
                      label: const Text('预览已保存画面'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : save,
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                message!,
                style: TextStyle(
                  color: failed ? Theme.of(context).colorScheme.error : null,
                ),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: form,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        section(context, '画面设置', Icons.dashboard_outlined, [
                          TextFormField(
                            controller: title,
                            enabled: !busy,
                            maxLength: 22,
                            decoration: const InputDecoration(
                              labelText: '居中标题',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) =>
                                v?.trim().isNotEmpty == true ? null : '请填写标题',
                          ),
                        ]),
                        const SizedBox(height: 14),
                        section(context, '能耗统计', Icons.analytics_outlined, [
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            key: ValueKey(formVersion),
                            initialValue: source,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '能耗数据来源',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: '',
                                child: Text('尚未选择'),
                              ),
                              if (source.isNotEmpty &&
                                  !sources.any((row) => row['id'] == source))
                                DropdownMenuItem(
                                  value: source,
                                  child: const Text('原画面已不可用'),
                                ),
                              for (final row in sources)
                                DropdownMenuItem(
                                  value: '${row['id']}',
                                  child: Text('${row['name']}'),
                                ),
                            ],
                            onChanged: busy
                                ? null
                                : (value) {
                                    setState(() {
                                      source = value ?? '';
                                    });
                                    loadWaterZones();
                                  },
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 6,
                            children: [
                              scopeLabel(
                                context,
                                Icons.local_fire_department_outlined,
                                '耗热 · 中节能 ${heatSites.length} 块表',
                              ),
                              scopeLabel(
                                context,
                                Icons.bolt_outlined,
                                '用电、补水 · ${energySites.length} 个整站',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            '热量按中节能表名计一次，电量每站取一块共享表，补水按站区相加。三项面积独立填写。',
                          ),
                          rankEditor(),
                        ]),
                        const SizedBox(height: 14),
                        section(
                          context,
                          '站点状态',
                          Icons.sensors_outlined,
                          [
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                field(delay, '延迟阈值（分钟）', required: true),
                                field(offline, '离线阈值（分钟）', required: true),
                              ],
                            ),
                          ],
                          subtitle: '根据数据总览的最后更新时间判断延迟和离线。',
                        ),
                        const SizedBox(height: 14),
                        section(
                          context,
                          '天气预报',
                          Icons.cloud_outlined,
                          [
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                field(latitude, '天气纬度'),
                                field(longitude, '天气经度'),
                                SizedBox(
                                  width: 325,
                                  child: TextFormField(
                                    controller: weatherHost,
                                    enabled: !busy,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    decoration: const InputDecoration(
                                      labelText: '和风 API Host',
                                      hintText: '控制台 → 设置 → API Host',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 285,
                                  child: TextFormField(
                                    controller: weatherKey,
                                    enabled: !busy,
                                    obscureText: true,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    decoration: InputDecoration(
                                      labelText: '和风 API KEY',
                                      hintText: hasWeatherKey
                                          ? '已配置，留空沿用'
                                          : '控制台项目凭据',
                                      border: const OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          subtitle: '现场温度读取数据总览。和风天气提供外部实况和预报。',
                        ),
                        const SizedBox(height: 14),
                        section(
                          context,
                          '近两小时热功率趋势',
                          Icons.show_chart,
                          [
                            for (final id in rows)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(choices[id] ?? '已移除的总览站区'),
                                    ),
                                    SizedBox(
                                      width: 155,
                                      child: TextFormField(
                                        key: ValueKey(id),
                                        enabled: !busy,
                                        controller: zones.putIfAbsent(
                                          id,
                                          TextEditingController.new,
                                        ),
                                        decoration: const InputDecoration(
                                          labelText: '外部站区编码',
                                          hintText: '01-001-01',
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '移除趋势绑定',
                                      onPressed: busy
                                          ? null
                                          : () =>
                                                setState(() => rows.remove(id)),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ],
                                ),
                              ),
                            if (choices.keys.any((id) => !rows.contains(id)))
                              DropdownButton<String>(
                                isExpanded: true,
                                hint: const Text('添加站区趋势绑定'),
                                items: [
                                  for (final row in choices.entries.where(
                                    (r) => !rows.contains(r.key),
                                  ))
                                    DropdownMenuItem(
                                      value: row.key,
                                      child: Text(row.value),
                                    ),
                                ],
                                onChanged: busy
                                    ? null
                                    : (id) {
                                        if (id != null) {
                                          setState(() => rows.add(id));
                                        }
                                      },
                              ),
                          ],
                          subtitle: '实时工况展示全部站区的二次网测点。填写外部站区编码可补充二次网瞬时热量趋势。',
                        ),
                        const SizedBox(height: 14),
                        section(
                          context,
                          '全网热功率',
                          Icons.speed_outlined,
                          [
                            for (final row in choices.entries)
                              CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text(row.value),
                                value: power.contains(row.key),
                                onChanged: busy
                                    ? null
                                    : (selected) => setState(() {
                                        if (selected == true) {
                                          power.add(row.key);
                                        } else {
                                          power.remove(row.key);
                                        }
                                      }),
                              ),
                          ],
                          subtitle: '勾选参与实时功率汇总的计量行。同一表计只计一次。',
                        ),
                        const SizedBox(height: 14),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget section(
    BuildContext context,
    String title,
    IconData icon,
    List<Widget> children, {
    String? subtitle,
  }) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 5),
              Text(
                subtitle,
                style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget scopeLabel(BuildContext context, IconData icon, String label) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: colors.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label, style: TextStyle(color: colors.primary)),
            ),
          ],
        ),
      ),
    );
  }

  Widget rankEditor() {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('单耗排行配置'),
      subtitle: const Text('分开设置热面积、电面积和水面积'),
      children: [
        for (final entry in areaLabels.entries)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('${entry.value}面积（㎡）'),
            subtitle: Text(switch (entry.key) {
              'heat' => '按中节能热表实际覆盖范围填写',
              'electricity' => '每个整站的电计量面积，可设置水、电排行显示名',
              'water_zone' => '能耗管理的水单耗按各分区面积计算',
              _ => '每个整站全部补水分区的计量面积',
            }),
            children: [
              if (entry.key == 'water_zone' && waterZonesError != null)
                TextButton(
                  onPressed: loadWaterZones,
                  child: Text(waterZonesError!),
                ),
              for (final site in areaSites(entry.key))
                areaRow(entry.key, entry.value, site),
            ],
          ),
      ],
    );
  }

  Widget areaRow(String metric, String label, Json site) {
    final code = site['code'] as String;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${site['name']} · $code${site['confirm_area'] == true ? '\n请核对热表覆盖面积' : ''}',
            ),
          ),
          Flexible(
            flex: 2,
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                field(
                  rankAreas[metric]!.putIfAbsent(
                    code,
                    TextEditingController.new,
                  ),
                  '$label面积（㎡）',
                  key: ValueKey('rank-area-$metric-$code'),
                ),
                if (metric == 'electricity')
                  SizedBox(
                    width: 160,
                    child: TextFormField(
                      key: ValueKey('rank-$code'),
                      controller: rankNames.putIfAbsent(
                        code,
                        TextEditingController.new,
                      ),
                      enabled: !busy,
                      maxLength: 24,
                      decoration: const InputDecoration(
                        labelText: '水、电显示名',
                        hintText: '留空沿用站名',
                        counterText: '',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget field(
    TextEditingController controller,
    String label, {
    bool required = false,
    Key? key,
  }) => SizedBox(
    width: 160,
    child: TextFormField(
      key: key,
      controller: controller,
      enabled: !busy,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      validator: (value) =>
          required && int.tryParse(value?.trim() ?? '') == null
          ? '请输入整数'
          : !required &&
                value?.trim().isNotEmpty == true &&
                double.tryParse(value!.trim())?.isFinite != true
          ? '请输入数字'
          : null,
    ),
  );
}
