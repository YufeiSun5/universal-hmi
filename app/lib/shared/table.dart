import 'dart:math' as math;
import 'package:flutter/material.dart';

class DenseTable extends StatefulWidget {
  const DenseTable({
    super.key,
    required this.headers,
    required this.rows,
    this.onSelect,
    this.selected = -1,
    this.onContext,
    this.checks,
    this.onCheck,
  });
  final List<String> headers;
  final List<List<String>> rows;
  final ValueChanged<int>? onSelect;
  final int selected;
  final void Function(int, Offset)? onContext;
  final Set<int>? checks;
  final void Function(int, bool)? onCheck;
  @override
  State<DenseTable> createState() => _DenseTableState();
}

class _DenseTableState extends State<DenseTable> {
  final horizontal = ScrollController(), vertical = ScrollController();
  late List<double> widths;
  @override
  void initState() {
    super.initState();
    widths = List.generate(widget.headers.length, (i) => i == 1 ? 180 : 125);
  }

  @override
  void didUpdateWidget(DenseTable old) {
    super.didUpdateWidget(old);
    if (widths.length != widget.headers.length) {
      widths = List.generate(widget.headers.length, (_) => 140);
    }
  }

  @override
  void dispose() {
    horizontal.dispose();
    vertical.dispose();
    super.dispose();
  }

  Widget cells(List<String> row, {bool header = false, int index = -1}) {
    final c = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (widget.checks != null)
          SizedBox(
            width: 36,
            child: header
                ? const SizedBox()
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
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
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
                            widths[i] = (widths[i] + d.delta.dx).clamp(65, 500),
                      ),
                      child: SizedBox(
                        width: 5,
                        height: 28,
                        child: VerticalDivider(color: c.outlineVariant),
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
    return LayoutBuilder(
      builder: (context, box) {
        final total =
            widths.fold(0.0, (a, b) => a + b) +
            (widget.checks != null ? 36 : 0);
        return Scrollbar(
          controller: horizontal,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: horizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: math.max(total, box.maxWidth),
              child: Column(
                children: [
                  Container(
                    height: 34,
                    color: c.surfaceContainerLow,
                    child: cells(widget.headers, header: true),
                  ),
                  const Divider(),
                  Expanded(
                    child: widget.rows.isEmpty
                        ? const Center(child: Text('没有符合条件的数据'))
                        : Scrollbar(
                            controller: vertical,
                            child: ListView.builder(
                              controller: vertical,
                              itemExtent: 35,
                              itemCount: widget.rows.length,
                              itemBuilder: (context, index) => InkWell(
                                onTap: () => widget.onSelect?.call(index),
                                onSecondaryTapDown: (d) => widget.onContext
                                    ?.call(index, d.globalPosition),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: widget.selected == index
                                        ? c.primary.withValues(alpha: .13)
                                        : index.isOdd
                                        ? c.surfaceContainerLow.withValues(
                                            alpha: .35,
                                          )
                                        : null,
                                    border: Border(
                                      bottom: BorderSide(
                                        color: c.outlineVariant.withValues(
                                          alpha: .25,
                                        ),
                                      ),
                                    ),
                                  ),
                                  child: cells(
                                    widget.rows[index],
                                    index: index,
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
