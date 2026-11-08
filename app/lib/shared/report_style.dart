import 'package:flutter/material.dart';
import 'api.dart';
import 'report_number.dart';

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

class ReportStyles {
  ReportStyles(this.screen);
  Json screen;
  final schemas = <String, List<String>>{};
  final labels = <String, List<String>>{};
  String register(List<String> headers, {List<String>? displayLabels}) {
    final key = reportSchemaKey(headers, custom: screen['kind'] == 'custom');
    schemas[key] = List.of(headers);
    labels[key] = List.of(displayLabels ?? headers);
    return key;
  }

  Json layout(List<String> headers, {List<String>? displayLabels}) {
    final key = register(headers, displayLabels: displayLabels);
    final value = screen['report_layouts']?[key];
    return value is Map ? Map<String, dynamic>.from(value) : {};
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
    // A changed schema must remain inspectable even if all old columns vanished.
    if (columns.isEmpty) {
      columns = [
        for (final name in original)
          {'key': name, 'label': labels[name] ?? name, 'visible': true},
      ];
    }
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
  List<String> row(List<String> values, {bool raw = false}) => [
    for (final c in columns)
      format(
        c,
        original.indexOf('${c['key']}') < values.length
            ? values[original.indexOf('${c['key']}')]
            : '',
        raw: raw,
      ),
  ];
  String format(Json column, String value, {bool raw = false}) =>
      !raw && column['decimals'] is int
      ? reportNumber(value, (column['decimals'] as int).clamp(0, 6))
      : value;
}

Color? reportStyleColor(Object? value) {
  if (value is! String || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) {
    return null;
  }
  return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
}
