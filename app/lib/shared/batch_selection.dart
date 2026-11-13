import 'package:flutter/material.dart';

/// Selection is independent of paging; callers supply the entire filtered set.
class BatchSelectionBar extends StatelessWidget {
  const BatchSelectionBar({
    super.key,
    required this.all,
    required this.matching,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });

  final Set<String> all, matching, selected;
  final ValueChanged<Set<String>> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text('已选 ${selected.intersection(all).length} / ${all.length}'),
      TextButton.icon(
        onPressed: enabled && !selected.containsAll(all)
            ? () => onChanged({...selected, ...all})
            : null,
        icon: const Icon(Icons.select_all, size: 18),
        label: const Text('全选'),
      ),
      if (matching.length != all.length) ...[
        TextButton(
          onPressed: enabled && !selected.containsAll(matching)
              ? () => onChanged({...selected, ...matching})
              : null,
          child: const Text('全选匹配项'),
        ),
        TextButton(
          onPressed: enabled && selected.intersection(matching).isNotEmpty
              ? () => onChanged(selected.difference(matching))
              : null,
          child: const Text('取消匹配项'),
        ),
      ],
      TextButton(
        onPressed: enabled && selected.isNotEmpty
            ? () => onChanged(<String>{})
            : null,
        child: const Text('清空选择'),
      ),
    ],
  );
}
