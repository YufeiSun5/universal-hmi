import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';
import 'report_style.dart';
import 'mobile_report.dart';

/// Both row widgets and their display values are produced only in the viewport.
class DenseTable extends StatefulWidget {
  const DenseTable({
    super.key,
    required this.headers,
    this.headerGroups,
    this.headerGroupKeys,
    this.rows = const [],
    this.rowCount,
    this.rowBuilder,
    this.rawRowBuilder,
    this.reportSchemaReady = true,
    this.reportTableKey,
    this.columnKeys,
    this.onSelect,
    this.selected = -1,
    this.onContext,
    this.checks,
    this.onCheck,
    this.onCheckAll,
    this.selectedRows,
    this.numericColumns = const {},
    this.initialWidths,
    this.initialScrollOffset = 0,
    this.onScroll,
    this.rowKey,
    this.cellKey,
    this.cellBuilder,
    this.emptyLabel = '没有符合条件的数据',
    this.reportStyle = false,
    this.emphasizedRows = const {},
    this.warningRows = const {},
    this.appearance,
  });
  final List<String> headers;

  /// Optional contiguous groups above the ordinary resizable column headers.
  final List<String>? headerGroups;
  final List<String>? headerGroupKeys;
  final List<List<String>> rows;
  final int? rowCount;
  final List<String> Function(int)? rowBuilder;

  /// Unrounded values used only when a report column overrides decimal places.
  final List<String> Function(int)? rawRowBuilder;

  /// False while dynamic result columns are not known (before a query).
  final bool reportSchemaReady;
  final String? reportTableKey;
  final List<String>? columnKeys;
  final Key Function(int)? rowKey;
  final Key? Function(int, int)? cellKey;

  /// Optional presentation for a data cell; plain values remain available for
  /// tooltips and all existing table consumers keep their default rendering.
  final Widget? Function(int row, int column, String value)? cellBuilder;
  final ValueChanged<int>? onSelect;
  final int selected;
  final void Function(int, Offset)? onContext;
  final Set<int>? checks;
  final void Function(int, bool)? onCheck;
  final ValueChanged<bool>? onCheckAll;
  final Set<int>? selectedRows;
  final Set<int> numericColumns;
  final List<double>? initialWidths;
  final double initialScrollOffset;
  final ValueChanged<double>? onScroll;
  final String emptyLabel;

  /// Centered, full-width presentation for business reports. Engineering grids
  /// retain their existing compact alignment and column sizing by default.
  final bool reportStyle;
  final Set<int> emphasizedRows;
  final Set<int> warningRows;
  final Map<String, dynamic>? appearance;
  @override
  State<DenseTable> createState() => _DenseTableState();
}

class _DenseTableState extends State<DenseTable> {
  bool phoneTable = false;
  ReportStyles? registeredStyles;
  final horizontal = ScrollController();
  late final ScrollController vertical;
  late List<double> widths;
  int get count => widget.rowCount ?? widget.rows.length;
  double get rowHeight =>
      (widget.appearance?['row_height'] as num?)?.toDouble() ??
      (widget.reportStyle ? 36 : 28);
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
    registeredStyles?.unregister(this);
    horizontal.dispose();
    vertical.dispose();
    super.dispose();
  }

  void step(int delta) {
    if (count == 0) return;
    final next = (widget.selected + delta).clamp(0, count - 1);
    widget.onSelect?.call(next);
    if (vertical.hasClients) {
      final top = next * rowHeight;
      final height = vertical.position.viewportDimension;
      if (top < vertical.offset || top + rowHeight > vertical.offset + height) {
        vertical.jumpTo(
          (top - (delta > 0 ? height - rowHeight : 0)).clamp(
            0,
            vertical.position.maxScrollExtent,
          ),
        );
      }
    }
  }

  Widget cells(
    List<String> row, {
    bool header = false,
    int index = -1,
    List<double>? renderWidths,
  }) {
    final c = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (widget.checks != null)
          SizedBox(
            width: 34,
            child: header
                ? widget.onCheckAll != null
                      ? Checkbox(
                          tristate: true,
                          value: widget.checks!.isEmpty
                              ? false
                              : widget.checks!.length == count
                              ? true
                              : null,
                          onChanged: count == 0
                              ? null
                              : (v) => widget.onCheckAll!(v ?? false),
                        )
                      : Tooltip(
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
          (i) => columnCell(
            i < row.length ? row[i] : '',
            i,
            renderWidths ?? widths,
            header: header,
            index: index,
          ),
        ),
      ],
    );
  }

  Widget columnCell(
    String value,
    int column,
    List<double> renderWidths, {
    bool header = false,
    int index = -1,
  }) {
    final colors = Theme.of(context).colorScheme;
    final report = widget.reportStyle;
    final columnStyles = widget.appearance?['columns'] as List?;
    final columnStyle = columnStyles != null && column < columnStyles.length
        ? columnStyles[column] as Map
        : const {};
    final alignment = switch (columnStyle['align']) {
      'left' => TextAlign.left,
      'right' => TextAlign.right,
      'center' => TextAlign.center,
      _ =>
        report
            ? TextAlign.center
            : widget.numericColumns.contains(column)
            ? TextAlign.right
            : TextAlign.left,
    };
    Widget text = Text(
      value,
      key: header ? null : widget.cellKey?.call(index, column),
      maxLines: header && report ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      textAlign: alignment,
      style: numericStyle.copyWith(
        fontSize:
            (widget.appearance?['font_size'] as num?)?.toDouble() ??
            (report ? 12.5 : 11.5),
        height: report ? 1.25 : null,
        fontWeight: header || widget.emphasizedRows.contains(index)
            ? FontWeight.w600
            : FontWeight.w400,
        color: !header && widget.warningRows.contains(index)
            ? colors.error
            : report
            ? header
                  ? const Color(0xff435c6e)
                  : const Color(0xff263c4c)
            : header
            ? colors.onSurfaceVariant
            : colors.onSurface,
      ),
    );
    if (report && !header && widget.numericColumns.contains(column)) {
      text = FittedBox(fit: BoxFit.scaleDown, child: text);
    }
    if (!header) {
      text = widget.cellBuilder?.call(index, column, value) ?? text;
    }
    if (report) text = Tooltip(message: value, child: text);
    return Container(
      width: renderWidths[column],
      decoration: report && column < widget.headers.length - 1
          ? const BoxDecoration(
              border: Border(
                right: BorderSide(color: Color(0xffe4ebf0), width: .5),
              ),
            )
          : null,
      child: Row(
        children: [
          if (report && header) const SizedBox(width: 5),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: report ? 8 : 10),
              child: report
                  ? Align(
                      alignment: alignment == TextAlign.left
                          ? Alignment.centerLeft
                          : alignment == TextAlign.right
                          ? Alignment.centerRight
                          : Alignment.center,
                      child: text,
                    )
                  : text,
            ),
          ),
          if (header)
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) => setState(() {
                  widths = renderWidths.toList();
                  widths[column] = (widths[column] + d.delta.dx).clamp(55, 800);
                }),
                child: SizedBox(
                  width: 5,
                  height: report ? 30 : 24,
                  child: const VerticalDivider(width: 1),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget reportHeader(List<double> renderWidths) {
    final groups = widget.headerGroups;
    if (groups == null) {
      return SizedBox(
        height: 42,
        child: cells(widget.headers, header: true, renderWidths: renderWidths),
      );
    }
    final keys = widget.headerGroupKeys ?? groups;
    final blocks = <Widget>[];
    if (widget.checks != null) blocks.add(const SizedBox(width: 34));
    for (var i = 0; i < widget.headers.length;) {
      final start = i;
      var end = i + 1;
      if (groups[start].isNotEmpty) {
        while (end < groups.length && keys[end] == keys[start]) {
          end++;
        }
      }
      if (groups[start].isEmpty) {
        blocks.add(
          columnCell(widget.headers[start], start, renderWidths, header: true),
        );
      } else {
        blocks.add(
          SizedBox(
            width: renderWidths
                .sublist(start, end)
                .fold<double>(0.0, (a, b) => a + b),
            child: Column(
              children: [
                Container(
                  height: 28,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Color(0xffe6eef4),
                    border: Border(
                      bottom: BorderSide(color: Color(0xffd6e1e9)),
                      right: BorderSide(color: Color(0xffd6e1e9)),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      groups[start],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xff435c6e),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 38,
                  child: Row(
                    children: [
                      for (var n = start; n < end; n++)
                        columnCell(
                          widget.headers[n],
                          n,
                          renderWidths,
                          header: true,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
      i = end;
    }
    return SizedBox(
      height: 66,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: blocks,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = ReportStyleScope.of(context);
    if (registeredStyles != scope?.styles ||
        scope?.suppressed == true ||
        !widget.reportSchemaReady) {
      registeredStyles?.unregister(this);
      registeredStyles = null;
    }
    if (scope != null && !scope.suppressed) {
      final legacyKeys = reportColumnKeys(
        widget.headers,
        groups: widget.headerGroups,
        groupKeys: widget.headerGroupKeys,
      );
      final keys = widget.columnKeys ?? legacyKeys;
      if (widget.reportSchemaReady && keys.isNotEmpty) {
        registeredStyles = scope.styles;
        scope.styles.register(
          this,
          keys,
          displayLabels: widget.headers,
          tableKey: widget.reportTableKey,
          legacyKeys: legacyKeys,
          groups: widget.headerGroups,
          groupKeys: widget.headerGroupKeys,
        );
      }
      final layout = scope.styles.layout(
        keys,
        displayLabels: widget.headers,
        tableKey: widget.reportTableKey,
        legacyKeys: legacyKeys,
      );
      if (layout.isNotEmpty) {
        final projection = ReportProjection(
          keys,
          layout,
          labels: {
            for (var i = 0; i < keys.length; i++) keys[i]: widget.headers[i],
          },
        );
        final order = projection.indices;
        final columns = projection.columns;
        final groups = projection.headerGroups(
          groups: widget.headerGroups,
          groupKeys: widget.headerGroupKeys,
        );
        final hasGroups = groups.any((g) => g.key.isNotEmpty);
        return ReportStyleScope(
          styles: scope.styles,
          suppressed: true,
          child: DenseTable(
            key: ValueKey('${widget.headers.join('|')}-${layout.toString()}'),
            headers: projection.headers,
            headerGroups: hasGroups ? [for (final g in groups) g.label] : null,
            headerGroupKeys: hasGroups ? [for (final g in groups) g.key] : null,
            rowCount: count,
            rowBuilder: (i) => projection.row(
              widget.rowBuilder?.call(i) ?? widget.rows[i],
              rawValues: widget.rawRowBuilder?.call(i),
            ),
            onSelect: widget.onSelect,
            selected: widget.selected,
            onContext: widget.onContext,
            checks: widget.checks,
            onCheck: widget.onCheck,
            onCheckAll: widget.onCheckAll,
            selectedRows: widget.selectedRows,
            numericColumns: {
              for (var i = 0; i < order.length; i++)
                if (widget.numericColumns.contains(order[i])) i,
            },
            initialWidths: [
              for (var i = 0; i < order.length; i++)
                ((columns[i]['width'] as num? ?? 0) > 0
                        ? (columns[i]['width'] as num).toDouble().clamp(55, 800)
                        : null) ??
                    (widget.initialWidths?[order[i]] ??
                        (order[i] == 1 ? 180 : 120)),
            ],
            initialScrollOffset: widget.initialScrollOffset,
            onScroll: widget.onScroll,
            rowKey: widget.rowKey,
            cellKey: widget.cellKey == null
                ? null
                : (r, c) => widget.cellKey!(r, order[c]),
            emptyLabel: widget.emptyLabel,
            reportStyle: widget.reportStyle,
            emphasizedRows: widget.emphasizedRows,
            appearance: {...layout, 'columns': columns},
          ),
        );
      }
    }
    final c = Theme.of(context).colorScheme;
    final table = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => step(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => step(-1),
      },
      child: Focus(
        child: LayoutBuilder(
          builder: (context, box) {
            final originalTotal =
                widths.fold(0.0, (a, b) => a + b) +
                (widget.checks != null ? 34 : 0);
            final extra = widget.checks != null ? 34.0 : 0.0;
            final scale =
                widget.reportStyle &&
                    originalTotal > extra &&
                    originalTotal < box.maxWidth
                ? (box.maxWidth - extra) / (originalTotal - extra)
                : 1.0;
            final renderWidths = [for (final w in widths) w * scale];
            final total = renderWidths.fold(0.0, (a, b) => a + b) + extra;
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
                      if (widget.reportStyle)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color:
                                reportStyleColor(
                                  widget.appearance?['header_color'],
                                ) ??
                                const Color(0xffeff4f8),
                            border: const Border(
                              bottom: BorderSide(color: Color(0xffcbd9e3)),
                            ),
                          ),
                          child: reportHeader(renderWidths),
                        )
                      else ...[
                        if (widget.headerGroups != null)
                          Container(
                            height: 30,
                            color: c.surfaceContainerLow,
                            child: Row(
                              children: [
                                if (widget.checks != null)
                                  const SizedBox(width: 34),
                                ...groupHeaders(c),
                              ],
                            ),
                          ),
                        Container(
                          height: 28,
                          color: c.surfaceContainerLow,
                          child: cells(widget.headers, header: true),
                        ),
                        const Divider(),
                      ],
                      Expanded(
                        child: count == 0
                            ? Center(child: Text(widget.emptyLabel))
                            : Scrollbar(
                                controller: vertical,
                                child: ListView.builder(
                                  key: const Key('dense-table-scroll'),
                                  controller: vertical,
                                  itemExtent: rowHeight,
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
                                        color:
                                            (widget.selectedRows?.contains(
                                                  index,
                                                ) ??
                                                (widget.selected == index))
                                            ? c.primaryContainer
                                            : widget.emphasizedRows.contains(
                                                index,
                                              )
                                            ? const Color(0xffeaf2f7)
                                            : index.isOdd
                                            ? widget.reportStyle
                                                  ? reportStyleColor(
                                                          widget
                                                              .appearance?['stripe_color'],
                                                        ) ??
                                                        const Color(0xfff7fafc)
                                                  : const Color(0xfffafbfd)
                                            : widget.reportStyle
                                            ? Colors.white
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
                                        renderWidths: renderWidths,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                      SizedBox(height: total > box.maxWidth ? 8 : 0),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    if (!widget.reportStyle) return table;
    final framedTable = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xffd3dfe7)),
        ),
        child: ClipRRect(borderRadius: BorderRadius.circular(6), child: table),
      ),
    );
    final phone =
        MediaQuery.sizeOf(context).width < 640 ||
        Uri.base.queryParameters['client'] == 'android';
    if (!phone) return framedTable;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '当前页 $count 条',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                key: const Key('mobile-report-view-toggle'),
                style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                onPressed: () => setState(() => phoneTable = !phoneTable),
                icon: Icon(
                  phoneTable
                      ? Icons.view_agenda_outlined
                      : Icons.table_chart_outlined,
                  size: 18,
                ),
                label: Text(phoneTable ? '卡片视图' : '表格视图'),
              ),
            ],
          ),
        ),
        Expanded(
          child: phoneTable
              ? framedTable
              : MobileReportRecords(
                  headers: widget.headers,
                  groups: widget.headerGroups,
                  groupKeys: widget.headerGroupKeys,
                  count: count,
                  rowBuilder: (i) =>
                      widget.rowBuilder?.call(i) ?? widget.rows[i],
                  onSelect: widget.onSelect,
                  selected: widget.selected,
                  emphasized: widget.emphasizedRows,
                  checks: widget.checks,
                  onCheck: widget.onCheck,
                  rowKey: widget.rowKey,
                  cellKey: widget.cellKey,
                  emptyLabel: widget.emptyLabel,
                ),
        ),
      ],
    );
  }

  List<Widget> groupHeaders(ColorScheme colors) {
    final groups = widget.headerGroups!;
    final keys = widget.headerGroupKeys ?? groups;
    final out = <Widget>[];
    for (var i = 0; i < widget.headers.length;) {
      final label = groups[i];
      var end = i + 1;
      while (end < groups.length && keys[end] == keys[i]) {
        end++;
      }
      final width = widths.sublist(i, end).fold(0.0, (a, b) => a + b);
      out.add(
        Container(
          width: width,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(color: colors.outlineVariant),
              bottom: BorderSide(color: colors.outlineVariant),
            ),
          ),
          child: Tooltip(
            message: label,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
          ),
        ),
      );
      i = end;
    }
    return out;
  }
}
