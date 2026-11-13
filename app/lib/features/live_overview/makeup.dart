import '../../shared/api.dart';

const overviewMakeupPumpColumns = <Json>[
  {'group': '补水泵1', 'name': '补水电流', 'header': '电流', 'unit': 'A', 'decimals': 1},
  {
    'group': '补水泵1',
    'name': '补水频率',
    'header': '频率',
    'unit': 'Hz',
    'decimals': 1,
  },
  {
    'group': '补水泵2',
    'name': '补水泵2电流',
    'header': '电流',
    'unit': 'A',
    'decimals': 1,
  },
  {
    'group': '补水泵2',
    'name': '补水泵2频率',
    'header': '频率',
    'unit': 'Hz',
    'decimals': 1,
  },
];

/// Explicit draft update: retain existing stable IDs and formatting, and add
/// only absent pump columns. Row bindings and additional equipment are untouched.
List<Json> overviewMakeupLayout(
  List<Json> columns, {
  required String Function() newID,
}) {
  final matched = <String>{};
  final pumps = <Json>[];
  for (final spec in overviewMakeupPumpColumns) {
    final candidates = columns.where((c) => c['name'] == spec['name']).toList();
    if (candidates.length > 1) {
      throw FormatException('“${spec['name']}”存在多个同名指标，请先区分名称');
    }
    final existing = candidates.firstOrNull;
    if (existing == null) {
      pumps.add({...spec, 'id': newID()});
      continue;
    }
    matched.add(existing['id'] as String);
    final header = existing['header'] as String? ?? '';
    pumps.add({
      ...existing,
      'group': spec['group'],
      if (header.isEmpty || header == '补水\n${spec['header']}')
        'header': spec['header'],
    });
  }
  final result = [
    for (final c in columns)
      if (!matched.contains(c['id'])) {...c},
  ];
  if (result.length + pumps.length > 64) {
    throw const FormatException('补水双泵布局将超过64列，请先移除不需要的指标');
  }
  var insertAt = result.lastIndexWhere((c) => c['group'] == '补水水箱') + 1;
  if (insertAt == 0) {
    insertAt = result.indexWhere(
      (c) => '${c['group']}'.startsWith('循环泵') || c['group'] == '电能',
    );
    if (insertAt < 0) insertAt = result.length;
  }
  result.insertAll(insertAt, pumps);
  return result;
}
