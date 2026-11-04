import 'package:flutter/material.dart';
import 'table_csv.dart';

Future<void> saveGisTable(BuildContext context, Map message) async {
  final rows = message['rows'], name = message['name'];
  if (rows is! List || rows.isEmpty || name is! String) return;
  try {
    final csv = TableCsv();
    for (final row in rows) {
      if (row is! List || row.any((v) => v is! String)) return;
      csv.add(row.cast<String>());
    }
    await csv.save('$name-分区表.csv');
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }
}
