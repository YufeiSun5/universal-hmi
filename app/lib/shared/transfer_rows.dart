import 'package:flutter/material.dart';
import 'api.dart';
import 'batch_selection.dart';

/// Keeps the selection while the station search changes, including hidden rows.
Future<List<Json>?> selectTransferRows(
  BuildContext context, {
  required List<Json> rows,
  required String title,
  required String description,
  required String action,
  required String Function(Json) label,
  required String Function(Json) detail,
  Map<String, String> issues = const {},
  bool allowEmpty = false,
}) {
  final available = rows
      .map((r) => r['id'] as String)
      .where((id) => !issues.containsKey(id))
      .toSet();
  var selected = {...available};
  var search = '';
  return showDialog<List<Json>>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (_, update) {
        final matching = rows
            .where(
              (r) => ('${label(r)} ${detail(r)} ${r['id']}')
                  .toLowerCase()
                  .contains(search),
            )
            .toList();
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 520,
            height: 440,
            child: CustomScrollView(
              slivers: [
                SliverList.list(
                  children: [
                    Text(description),
                    TextField(
                      decoration: const InputDecoration(labelText: '筛选站点'),
                      onChanged: (s) =>
                          update(() => search = s.trim().toLowerCase()),
                    ),
                    BatchSelectionBar(
                      all: available,
                      matching: matching
                          .map((r) => r['id'] as String)
                          .toSet()
                          .intersection(available),
                      selected: selected,
                      onChanged: (v) => update(() => selected = v),
                    ),
                  ],
                ),
                SliverList.builder(
                  itemCount: matching.length,
                  itemBuilder: (_, i) {
                    final r = matching[i], id = r['id'] as String;
                    return CheckboxListTile(
                      title: Text(label(r)),
                      subtitle: Text(
                        [
                          detail(r),
                          if (issues[id] != null) issues[id]!,
                        ].join('\n'),
                      ),
                      value: selected.contains(id),
                      onChanged: issues.containsKey(id)
                          ? null
                          : (value) => update(() {
                              if (value == true) {
                                selected.add(id);
                              } else {
                                selected.remove(id);
                              }
                            }),
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: selected.isEmpty && !(allowEmpty && rows.isEmpty)
                  ? null
                  : () => Navigator.pop(
                      dialog,
                      rows.where((r) => selected.contains(r['id'])).toList(),
                    ),
              child: Text(action),
            ),
          ],
        );
      },
    ),
  );
}
