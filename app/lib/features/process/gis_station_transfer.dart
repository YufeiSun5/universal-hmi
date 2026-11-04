import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../shared/api.dart';
import '../../shared/batch_selection.dart';
import '../../shared/desktop_dialog.dart';
import 'gis_bindings.dart';

const gisStationParts = {
  'basic': '站点名称与坐标',
  'target': '工艺画面跳转',
  'common': '站公共数据',
  'zones': '分区数据与顺序',
};

/// File data is a station editor draft, never a point definition or authority.
/// Final persistence still uses the screen service's revision and permission checks.
class GisStationFile {
  GisStationFile(this.parts);
  final Json parts;

  factory GisStationFile.fromStation(Json station) => GisStationFile({
    'basic': {
      'name': station['name'],
      'longitude': station['longitude'],
      'latitude': station['latitude'],
    },
    'target': station['target_screen_id'] ?? '',
    'common': _section(station),
    'zones': [
      for (final zone in objects(station['zones']))
        {'id': zone['id'], 'name': zone['name'], ..._section(zone)},
    ],
  });

  static Json _section(Json section) => {
    'fields':
        section['fields'] ??
        [
          for (final e in gisMetrics.entries) {'id': e.key, 'name': e.value},
        ],
    'bindings': section['bindings'] ?? <String, dynamic>{},
  };

  Uint8List encode(Set<String> selected) => Uint8List.fromList(
    utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'format': 'universal-hmi-gis-station',
        'version': 1,
        'parts': {for (final key in selected) key: parts[key]},
      }),
    ),
  );

  factory GisStationFile.decode(Uint8List bytes) {
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('站点配置不能超过 8 MiB');
    }
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Map ||
        raw['format'] != 'universal-hmi-gis-station' ||
        raw['version'] != 1 ||
        raw['parts'] is! Map) {
      throw const FormatException('请选择本系统导出的 GIS 站点配置 JSON');
    }
    final parts = Map<String, dynamic>.from(raw['parts'] as Map);
    if (parts.isEmpty ||
        parts.keys.any((key) => !gisStationParts.containsKey(key))) {
      throw const FormatException('站点配置内容为空或包含未知部分');
    }
    final file = GisStationFile(parts);
    for (final key in parts.keys) {
      file.validatePart(key);
    }
    return file;
  }

  static final _id = RegExp(r'^[a-zA-Z0-9_-]{1,96}$');
  static bool validName(Object? value) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.runes.length <= 80 &&
      !value.contains(RegExp(r'[\x00\r\n]'));

  void validatePart(String key) {
    final value = parts[key];
    if (key == 'basic') {
      if (value is! Map || !validName(value['name'])) {
        throw const FormatException('站点名称无效');
      }
      for (final entry in const {'longitude': 180, 'latitude': 85}.entries) {
        final n = value[entry.key];
        if (n is! num || !n.isFinite || n.abs() > entry.value) {
          throw const FormatException('站点经纬度无效');
        }
      }
    } else if (key == 'target') {
      if (value is! String || (value.isNotEmpty && !_id.hasMatch(value))) {
        throw const FormatException('跳转画面标识无效');
      }
    } else if (key == 'common') {
      _validateSection(value);
    } else if (key == 'zones') {
      if (value is! List || value.length > 16) {
        throw const FormatException('分区最多 16 个');
      }
      final ids = <String>{};
      for (final zone in value) {
        if (zone is! Map ||
            zone['id'] is! String ||
            !_id.hasMatch(zone['id'] as String) ||
            !ids.add(zone['id'] as String) ||
            !validName(zone['name'])) {
          throw const FormatException('分区名称或标识无效、重复');
        }
        _validateSection(zone);
      }
    }
  }

  static void _validateSection(Object? value) {
    if (value is! Map ||
        value['fields'] is! List ||
        value['bindings'] is! Map) {
      throw const FormatException('展示信息或绑定格式无效');
    }
    final fields = value['fields'] as List;
    if (fields.length > 32) throw const FormatException('每组最多 32 项信息');
    final ids = <String>{};
    for (final field in fields) {
      if (field is! Map ||
          field['id'] is! String ||
          !_id.hasMatch(field['id'] as String) ||
          !ids.add(field['id'] as String) ||
          !validName(field['name'])) {
        throw const FormatException('信息名称或标识无效、重复');
      }
    }
    for (final binding in (value['bindings'] as Map).entries) {
      if (!ids.contains(binding.key) ||
          binding.value is! String ||
          !_id.hasMatch(binding.value as String)) {
        throw const FormatException('变量绑定与信息项不对应');
      }
    }
  }

  Set<String> pointIDs(String key) {
    final sections = key == 'common'
        ? [parts[key]]
        : key == 'zones'
        ? parts[key] as List
        : const [];
    return {
      for (final section in sections)
        ...(section['bindings'] as Map).values.cast<String>(),
    };
  }

  Json apply(Json current, Set<String> selected) {
    // Deep-copy file lists/maps so cancellation never mutates the source draft.
    final result = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(current)) as Map,
    );
    final copied = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(parts)) as Map,
    );
    if (selected.contains('basic')) {
      final basic = copied['basic'] as Map;
      for (final key in ['name', 'longitude', 'latitude']) {
        result[key] = basic[key];
      }
    }
    if (selected.contains('target')) {
      result['target_screen_id'] = copied['target'];
    }
    if (selected.contains('common')) {
      result['fields'] = copied['common']['fields'];
      result['bindings'] = copied['common']['bindings'];
    }
    if (selected.contains('zones')) result['zones'] = copied['zones'];
    return result;
  }

  String summary(String key) => switch (key) {
    'basic' =>
      '${parts[key]['name']} · ${parts[key]['longitude']}, ${parts[key]['latitude']}',
    'target' => parts[key] == '' ? '不设置跳转' : '已配置工艺画面跳转',
    'common' =>
      '${(parts[key]['fields'] as List).length} 项信息 · ${(parts[key]['bindings'] as Map).length} 个绑定',
    'zones' =>
      '${(parts[key] as List).length} 个分区：${objects(parts[key]).map((z) => z['name']).join('、')}',
    _ => '',
  };
}

class GisStationTransferDialog extends StatefulWidget {
  const GisStationTransferDialog({
    super.key,
    required this.file,
    required this.importing,
    this.issues = const {},
    this.current,
  });
  final GisStationFile file;
  final bool importing;
  final Map<String, String> issues;
  final GisStationFile? current;

  @override
  State<GisStationTransferDialog> createState() =>
      _GisStationTransferDialogState();
}

class _GisStationTransferDialogState extends State<GisStationTransferDialog> {
  late Set<String> selected = widget.file.parts.keys.toSet();

  @override
  Widget build(BuildContext context) {
    final invalid = selected.any(widget.issues.containsKey);
    return AlertDialog(
      shape: DesktopDialogStyle.shape,
      backgroundColor: DesktopDialogStyle.background,
      insetPadding: DesktopDialogStyle.insetPadding,
      title: Text(widget.importing ? '预览导入站点配置' : '选择导出内容'),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.importing
                    ? '勾选的部分将替换当前编辑内容；未勾选部分保留。确认后仍需确定并保存画面。'
                    : '导出当前编辑内容为 JSON，含已有变量引用。',
              ),
              BatchSelectionBar(
                all: widget.file.parts.keys.toSet(),
                matching: widget.file.parts.keys.toSet(),
                selected: selected,
                onChanged: (value) => setState(() => selected = value),
              ),
              for (final key in widget.file.parts.keys)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: selected.contains(key),
                  title: Text(gisStationParts[key]!),
                  subtitle: Text(
                    [
                      if (widget.current != null)
                        '当前：${widget.current!.summary(key)}',
                      '${widget.importing ? '文件' : '内容'}：${widget.file.summary(key)}',
                      if (widget.issues[key] != null) widget.issues[key]!,
                    ].join('\n'),
                  ),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      selected.add(key);
                    } else {
                      selected.remove(key);
                    }
                  }),
                ),
              if (invalid)
                const Text(
                  '所选内容含不可用的引用。请取消对应部分，或在原工程修正后重新导出。',
                  style: TextStyle(color: Colors.red),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: selected.isEmpty || invalid
              ? null
              : () => Navigator.pop(context, selected),
          child: Text(widget.importing ? '替换所选内容' : '导出 JSON'),
        ),
      ],
    );
  }
}

/// Whole-map transfer preserves station identities. Unselected draft rows retain
/// their order; new identities append in file order.
class GisStationListFile {
  static Uint8List encode(List<Json> rows) => Uint8List.fromList(
    utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'format': 'universal-hmi-gis-stations',
        'version': 1,
        'stations': rows,
      }),
    ),
  );

  static List<Json> decode(Uint8List bytes) {
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('GIS站点文件超过8 MiB');
    }
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! Json ||
        raw['format'] != 'universal-hmi-gis-stations' ||
        raw['version'] != 1 ||
        raw['stations'] is! List ||
        raw['stations'].length > 100) {
      throw const FormatException('请选择“地图站点 → 导出站点”生成的 GIS 站点列表（最多100个）');
    }
    final ids = <String>{};
    final result = <Json>[];
    for (final row in raw['stations']) {
      if (row is! Json ||
          row['id'] is! String ||
          !GisStationFile._id.hasMatch(row['id']) ||
          !ids.add(row['id']) ||
          (row['zones'] != null &&
              (row['zones'] is! List ||
                  (row['zones'] as List).any((z) => z is! Json)))) {
        throw const FormatException('站点标识重复或站点格式无效');
      }
      final file = GisStationFile.fromStation(row);
      for (final key in gisStationParts.keys) {
        file.validatePart(key);
      }
      result.add(file.apply({'id': row['id']}, gisStationParts.keys.toSet()));
    }
    return result;
  }

  static List<Json> merge(List<Json> current, List<Json> selected) {
    final byID = {for (final r in selected) r['id']: r};
    final existing = current.map((r) => r['id']).toSet();
    final result = [
      for (final r in current) byID[r['id']] ?? r,
      for (final r in selected)
        if (!existing.contains(r['id'])) r,
    ];
    if (result.length > 100) throw const FormatException('合并后超过100个站点，请减少选择');
    return result;
  }
}
