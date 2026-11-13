import 'package:flutter/material.dart';

/// Stays outside the scrolling rows so repeated clicks move the selected field
/// without changing the pointer target or selecting the row that replaced it.
class ColumnOrderToolbar extends StatelessWidget {
  const ColumnOrderToolbar({
    super.key,
    required this.label,
    required this.index,
    required this.length,
    required this.onMove,
    this.busy = false,
  });
  final String label;
  final int index, length;
  final ValueChanged<int> onMove;
  final bool busy;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(
            index < 0 ? '请选择要调整的列' : '$label · 第 ${index + 1} / $length 列',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          key: const ValueKey('selected-column-up'),
          tooltip: '上移选中列',
          onPressed: busy || index <= 0 ? null : () => onMove(-1),
          icon: const Icon(Icons.arrow_upward, size: 20),
        ),
        const SizedBox(width: 8),
        IconButton(
          key: const ValueKey('selected-column-down'),
          tooltip: '下移选中列',
          onPressed: busy || index < 0 || index + 1 >= length
              ? null
              : () => onMove(1),
          icon: const Icon(Icons.arrow_downward, size: 20),
        ),
      ],
    ),
  );
}
