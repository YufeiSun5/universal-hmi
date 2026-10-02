import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';

/// Both row widgets and their display values are produced only in the viewport.
class DenseTable extends StatefulWidget {
  const DenseTable({
    super.key,
    required this.headers,
    this.rows = const [],
    this.rowCount,
    this.rowBuilder,
    this.onSelect,
    this.selected = -1,
    this.onContext,
    this.checks,
    this.onCheck,
    this.numericColumns = const {},
    this.initialWidths,
    this.initialScrollOffset = 0,
    this.onScroll,
    this.rowKey,
    this.cellKey,
    this.emptyLabel = '没有符合条件的数据',
  });
  final List<String> headers;
  final List<List<String>> rows;
  final int? rowCount;
  final List<String> Function(int)? rowBuilder;
  final Key Function(int)? rowKey;
  final Key? Function(int, int)? cellKey;
  final ValueChanged<int>? onSelect;
  final int selected;
  final void Function(int, Offset)? onContext;
  final Set<int>? checks;
  final void Function(int, bool)? onCheck;
  final Set<int> numericColumns;
  final List<double>? initialWidths;
  final double initialScrollOffset;
  final ValueChanged<double>? onScroll;
  final String emptyLabel;
  @override
  State<DenseTable> createState() => _DenseTableState();
}

class _DenseTableState extends State<DenseTable> {
  final horizontal = ScrollController();
  late final ScrollController vertical;
  late List<double> widths;
  int get count => widget.rowCount ?? widget.rows.length;
  @override
  void initState() {
    super.initState();
    vertical = ScrollController(
      initialScrollOffset: widget.initialScrollOffset,
      keepScrollOffset: false,
    )..addListener(() => widget.onScroll?.call(vertical.offset));
    widths =
        widget.initialWidths?.toList() ??
        List.generate(widget.headers.length, (i) => i == 1 ? 180 : 120);
  }

  @override
  void didUpdateWidget(DenseTable old) {
    super.didUpdateWidget(old);
    if (widths.length != widget.headers.length) {
      widths = List.filled(widget.headers.length, 120);
    }
  }

  @override
  void dispose() {
    horizontal.dispose();
    vertical.dispose();
    super.dispose();
  }

  void step(int delta) {
    if (count == 0) return;
    final next = (widget.selected + delta).clamp(0, count - 1);
    widget.onSelect?.call(next);
    if (vertical.hasClients) {
      final top = next * 28.0;
      final height = vertical.position.viewportDimension;
      if (top < vertical.offset || top + 28 > vertical.offset + height) {
        vertical.jumpTo(
          (top - (delta > 0 ? height - 28 : 0)).clamp(
            0,
            vertical.position.maxScrollExtent,
          ),
        );
      }
    }
  }

  Widget cells(List<String> row, {bool header = false, int index = -1}) {
    final c = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (widget.checks != null)
          SizedBox(
            width: 34,
            child: header
                ? Tooltip(
                    message: '选择最多 6 条趋势曲线',
                    child: Icon(
                      Icons.show_chart,
                      size: 14,
                      color: c.onSurfaceVariant,
                    ),
                  )
                : Checkbox(
                    value: widget.checks!.contains(index),
                    onChanged: (v) => widget.onCheck?.call(index, v ?? false),
                  ),
          ),
        ...List.generate(
          widget.headers.length,
          (i) => SizedBox(
            width: widths[i],
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      i < row.length ? row[i] : '',
                      key: header ? null : widget.cellKey?.call(index, i),
                      overflow: TextOverflow.ellipsis,
                      textAlign: widget.numericColumns.contains(i)
                          ? TextAlign.right
                          : TextAlign.left,
                      style: numericStyle.copyWith(
                        fontSize: 11.5,
                        fontWeight: header ? FontWeight.w600 : FontWeight.w400,
                        color: header ? c.onSurfaceVariant : c.onSurface,
                      ),
                    ),
                  ),
                ),
                if (header)
                  MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (d) => setState(
                        () =>
                            widths[i] = (widths[i] + d.delta.dx).clamp(55, 500),
                      ),
                      child: const SizedBox(
                        width: 5,
                        height: 24,
                        child: VerticalDivider(width: 1),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => step(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => step(-1),
      },
      child: Focus(
        child: LayoutBuilder(
          builder: (context, box) {
            final total =
                widths.fold(0.0, (a, b) => a + b) +
                (widget.checks != null ? 34 : 0);
            return Scrollbar(
              controller: horizontal,
              thumbVisibility: total > box.maxWidth,
              notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
              child: SingleChildScrollView(
                controller: horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(total, box.maxWidth),
                  child: Column(
                    children: [
                      Container(
                        height: 28,
                        color: c.surfaceContainerLow,
                        child: cells(widget.headers, header: true),
                      ),
                      const Divider(),
                      Expanded(
                        child: count == 0
                            ? Center(child: Text(widget.emptyLabel))
                            : Scrollbar(
                                controller: vertical,
                                child: ListView.builder(
                                  key: const Key('dense-table-scroll'),
                                  controller: vertical,
                                  itemExtent: 28,
                                  itemCount: count,
                                  cacheExtent: 160,
                                  itemBuilder: (context, index) => InkWell(
                                    key: widget.rowKey?.call(index),
                                    onTap: () {
                                      Focus.of(context).requestFocus();
                                      widget.onSelect?.call(index);
                                    },
                                    onSecondaryTapDown: (d) => widget.onContext
                                        ?.call(index, d.globalPosition),
                                    child: Container(
                                      foregroundDecoration: BoxDecoration(
                                        border: Border(
                                          left: BorderSide(
                                            width: 2,
                                            color: widget.selected == index
                                                ? c.primary
                                                : Colors.transparent,
                                          ),
                                        ),
                                      ),
                                      decoration: BoxDecoration(
                                        color: widget.selected == index
                                            ? c.primaryContainer
                                            : index.isOdd
                                            ? const Color(0xfffafbfd)
                                            : c.surface,
                                        border: Border(
                                          bottom: BorderSide(
                                            color: c.outlineVariant.withValues(
                                              alpha: .5,
                                            ),
                                          ),
                                        ),
                                      ),
                                      child: cells(
                                        widget.rowBuilder?.call(index) ??
                                            widget.rows[index],
                                        index: index,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
