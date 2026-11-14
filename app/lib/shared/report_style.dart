import 'package:flutter/material.dart';
import 'api.dart';
import 'report_number.dart';
import 'report_time.dart';

String reportSchemaKey(List<String> headers, {bool custom = false}) {
  if (custom) return 'custom';
  var hash = 2166136261;
  for (final c in headers.join('\u001f').codeUnits) {
    hash = ((hash ^ c) * 16777619) & 0xffffffff;
  }
  return 'table_${hash.toRadixString(16)}';
}

List<String> reportColumnKeys(
  List<String> headers, {
  List<String>? groups,
  List<String>? groupKeys,
}) => [
  for (var i = 0; i < headers.length; i++)
    headers.where((h) => h == headers[i]).length == 1
        ? headers[i]
        : '${groups?[i] ?? ''} / ${headers[i]} · ${groupKeys?[i] ?? i}',
];

class ReportSchema {
  ReportSchema(
    this.key,
    this.fields,
    this.labels,
    this.legacyFields,
    this.descriptions,
    this.groups,
    this.groupKeys,
  );
  final String key;
  final List<String> fields, labels, legacyFields;
  final List<String> descriptions;
  final List<String> groups, groupKeys;
}

class ReportStyles {
  ReportStyles(this.screen);
  Json screen;
  Json? sourceScreen;
  final _tables = <Object, ReportSchema>{};
  Map<String, List<String>> get schemas => {
    for (final t in _tables.values) t.key: t.fields,
  };
  Map<String, List<String>> get labels => {
    for (final t in _tables.values) t.key: t.labels,
  };
  Map<String, List<String>> get descriptions => {
    for (final t in _tables.values) t.key: t.descriptions,
  };
  Map<String, List<String>> get groups => {
    for (final t in _tables.values) t.key: t.groups,
  };
  Map<String, List<String>> get groupKeys => {
    for (final t in _tables.values) t.key: t.groupKeys,
  };
  Map<String, Json> get currentLayouts => {
    for (final t in _tables.values)
      t.key: layout(t.fields, tableKey: t.key, legacyKeys: t.legacyFields),
  };
  Map<String, String> get legacyLayoutKeys => {
    for (final t in _tables.values)
      t.key: reportSchemaKey(
        t.legacyFields,
        custom: screen['kind'] == 'custom',
      ),
  };
  void unregister(Object owner) => _tables.remove(owner);
  void register(
    Object owner,
    List<String> headers, {
    List<String>? displayLabels,
    String? tableKey,
    List<String>? legacyKeys,
    List<String>? groups,
    List<String>? groupKeys,
  }) {
    final key =
        tableKey ??
        reportSchemaKey(headers, custom: screen['kind'] == 'custom');
    _tables[owner] = ReportSchema(
      key,
      List.of(headers),
      List.of(displayLabels ?? headers),
      List.of(legacyKeys ?? headers),
      [
        for (var i = 0; i < headers.length; i++)
          [
            if ((groups?[i] ?? '').isNotEmpty) groups![i],
            (displayLabels ?? headers)[i],
          ].join(' · '),
      ],
      List.of(groups ?? List.filled(headers.length, '')),
      List.of(groupKeys ?? groups ?? List.filled(headers.length, '')),
    );
  }

  Json layout(
    List<String> headers, {
    List<String>? displayLabels,
    String? tableKey,
    List<String>? legacyKeys,
  }) {
    final legacy = legacyKeys ?? headers;
    final oldKey = reportSchemaKey(legacy, custom: screen['kind'] == 'custom');
    final layouts = screen['report_layouts'] as Map? ?? {};
    final value = layouts[tableKey ?? oldKey];
    if (value is Map) return Map<String, dynamic>.from(value);
    final old = layouts[oldKey];
    if (old is! Map) return {};
    return {
      ...Map<String, dynamic>.from(old),
      'columns': [
        for (final c in objects(old['columns']))
          {
            ...c,
            'key': legacy.contains(c['key'])
                ? headers[legacy.indexOf(c['key'])]
                : c['key'],
          },
      ],
    };
  }
}

class ReportStyleScope extends InheritedWidget {
  const ReportStyleScope({
    super.key,
    required this.styles,
    required super.child,
    this.suppressed = false,
  });
  final ReportStyles styles;
  final bool suppressed;
  static ReportStyleScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReportStyleScope>();
  @override
  bool updateShouldNotify(ReportStyleScope oldWidget) => true;
}

class ReportProjection {
  ReportProjection(
    this.original,
    this.layout, {
    Map<String, String> labels = const {},
  }) {
    final saved = objects(layout['columns']);
    columns = [
      for (final c in saved)
        if (original.contains(c['key']) && c['visible'] != false) c,
      for (final name in original)
        if (!saved.any((c) => c['key'] == name))
          {'key': name, 'label': labels[name] ?? name, 'visible': true},
    ];
  }
  final List<String> original;
  final Json layout;
  late List<Json> columns;
  List<int> get indices => [
    for (final c in columns) original.indexOf('${c['key']}'),
  ];
  List<String> get headers => [
    for (final c in columns) '${c['label'] ?? c['key']}',
  ];
  List<ReportHeaderGroup> headerGroups({
    List<String>? groups,
    List<String>? groupKeys,
  }) => [
    for (final c in columns)
      reportHeaderGroup(
        c,
        layout,
        sourceLabel: groups?[original.indexOf('${c['key']}')] ?? '',
        sourceKey: groupKeys?[original.indexOf('${c['key']}')],
      ),
  ];
  List<String> row(
    List<String> values, {
    bool raw = false,
    List<String>? rawValues,
  }) => [
    for (final c in columns)
      format(
        c,
        original.indexOf('${c['key']}') < values.length
            ? rawValues != null &&
                      (c['decimals'] is int ||
                          (c['time_zone'] is Map &&
                              reportTime(
                                    rawValues[original.indexOf('${c['key']}')],
                                    Map<String, dynamic>.from(c['time_zone']),
                                  ) !=
                                  rawValues[original.indexOf('${c['key']}')]))
                  ? rawValues[original.indexOf('${c['key']}')]
                  : values[original.indexOf('${c['key']}')]
            : '',
        raw: raw,
      ),
  ];
  String format(Json column, String value, {bool raw = false}) {
    if (column['time_zone'] is Map) {
      final converted = reportTime(
        value,
        Map<String, dynamic>.from(column['time_zone']),
      );
      if (converted != value) return converted;
    }
    return !raw && column['decimals'] is int
        ? value
              .split('～')
              .map(
                (v) => reportNumber(
                  v.trim(),
                  (column['decimals'] as int).clamp(0, 6),
                ),
              )
              .join('～')
        : value;
  }
}

class ReportHeaderGroup {
  const ReportHeaderGroup(this.key, this.label, this.sourceLabel);
  final String key, label, sourceLabel;
}

// Display aliases never replace the stable identity used to merge headers.
ReportHeaderGroup reportHeaderGroup(
  Json column,
  Json layout, {
  String sourceLabel = '',
  String? sourceKey,
}) {
  final custom = '${column['group'] ?? ''}';
  final label = custom.isNotEmpty ? custom : sourceLabel;
  final key = custom.isNotEmpty
      ? 'custom:$custom'
      : label.isEmpty
      ? ''
      : 'source:${sourceKey ?? sourceLabel}';
  final aliases = layout['group_labels'] as Map? ?? {};
  return ReportHeaderGroup(key, '${aliases[key] ?? label}', label);
}

Color? reportStyleColor(Object? value) {
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return null;
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}
