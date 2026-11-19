import 'package:flutter/material.dart';
import '../../shared/api.dart';
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
  final zones = <String, TextEditingController>{};
  final rated = <String, TextEditingController>{};
  List<Json> options = [], sources = [];
  List<String> rows = [];
  Set<String> power = {};
  int revision = 0;
  String source = '';
  String? message;
  bool busy = true, ready = false, failed = false;

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
      ...zones.values,
      ...rated.values,
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
      title.text = '${config['title']}';
      delay.text = '${config['delay_minutes']}';
      offline.text = '${config['offline_minutes']}';
      latitude.text = config['latitude']?.toString() ?? '';
      longitude.text = config['longitude']?.toString() ?? '';
      for (final c in zones.values) {
        c.dispose();
      }
      zones.clear();
      final codes = config['zone_codes'];
      if (codes is Map) {
        for (final entry in codes.entries) {
          zones['${entry.key}'] = TextEditingController(text: '${entry.value}');
        }
      }
      for (final c in rated.values) {
        c.dispose();
      }
      rated.clear();
      final capacities = config['rated_mw'];
      if (capacities is Map) {
        for (final entry in capacities.entries) {
          rated['${entry.key}'] = TextEditingController(text: '${entry.value}');
        }
      }
      setState(() {
        options = objects(result[1]['rows']);
        sources = objects(
          result[2]['items'],
        ).where((r) => r['kind'] == 'energy').toList();
        revision = config['revision'] as int;
        source = config['energy_screen']?.toString() ?? '';
        rows = (config['focus_rows'] as List? ?? []).cast<String>().toList();
        power = (config['power_rows'] as List? ?? []).cast<String>().toSet();
        ready = true;
        failed = false;
      });
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

  Future<void> save() async {
    if (!(form.currentState?.validate() ?? false)) return;
    final delayed = int.parse(delay.text.trim());
    final disconnected = int.parse(offline.text.trim());
    if (delayed >= disconnected) {
      setState(() {
        failed = true;
        message = '离线阈值须大于延迟阈值';
      });
      return;
    }
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
          'title': title.text.trim(),
          'energy_screen': source,
          'delay_minutes': delayed,
          'offline_minutes': disconnected,
          'latitude': double.tryParse(latitude.text.trim()),
          'longitude': double.tryParse(longitude.text.trim()),
          'focus_rows': rows,
          'power_rows': power.toList()..sort(),
          'zone_codes': {
            for (final id in rows)
              if (zones[id]?.text.trim().isNotEmpty ?? false)
                id: zones[id]!.text.trim(),
          },
          'rated_mw': {
            for (final group in selectedGroups)
              group: ?double.tryParse(rated[group]?.text.trim() ?? ''),
          },
        },
      );
      if (mounted) {
        setState(() {
          revision = saved['revision'] as int;
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

  List<String> get selectedGroups => {
    for (final row in options.where((row) => power.contains(row['id'])))
      row['site']?.toString().isNotEmpty == true
          ? '${row['site']}'
          : '${row['name']}',
  }.toList()..sort();

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
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '驾驶舱配置',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : preview,
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('预览已保存画面'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : save,
                  child: const Text('保存'),
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
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 850),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: title,
                          maxLength: 22,
                          decoration: const InputDecoration(
                            labelText: '居中标题',
                            border: OutlineInputBorder(),
                          ),
                          validator: (v) =>
                              v?.trim().isNotEmpty == true ? null : '请填写标题',
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
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
                              : (value) => setState(() => source = value ?? ''),
                        ),
                        const SizedBox(height: 18),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            field(delay, '延迟阈值（分钟）', required: true),
                            field(offline, '离线阈值（分钟）', required: true),
                            field(latitude, '天气纬度'),
                            field(longitude, '天气经度'),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '重点站实时工况',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Text('最多四个站区，沿用数据总览的测点绑定。填写外部站区编码后可显示近两小时趋势。'),
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
                                  tooltip: '移除重点站区',
                                  onPressed: () =>
                                      setState(() => rows.remove(id)),
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ),
                          ),
                        if (rows.length < 4 &&
                            choices.keys.any((id) => !rows.contains(id)))
                          DropdownButton<String>(
                            isExpanded: true,
                            hint: const Text('添加重点站区'),
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
                        const SizedBox(height: 17),
                        Text(
                          '全网及站所热功率',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Text('勾选应参与汇总的计量行。同一绑定的表计只计一次。'),
                        if (selectedGroups.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                for (final group in selectedGroups)
                                  field(
                                    rated.putIfAbsent(
                                      group,
                                      TextEditingController.new,
                                    ),
                                    '$group 额定 MW',
                                  ),
                              ],
                            ),
                          ),
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

  Widget field(
    TextEditingController controller,
    String label, {
    bool required = false,
  }) => SizedBox(
    width: 160,
    child: TextFormField(
      controller: controller,
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
                double.tryParse(value!.trim()) == null
          ? '请输入数字'
          : null,
    ),
  );
}
