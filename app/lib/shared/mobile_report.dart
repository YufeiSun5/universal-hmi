import 'package:flutter/material.dart';
import 'theme.dart';

/// The same projected/formatted report cells, presented as touch-sized records.
/// No query, calculation or CSV projection is performed in this view.
class MobileReportRecords extends StatefulWidget {
  const MobileReportRecords({
    super.key,
    required this.headers,
    required this.count,
    required this.rowBuilder,
    this.groups,
    this.groupKeys,
    this.onSelect,
    this.selected = -1,
    this.emphasized = const {},
    this.checks,
    this.onCheck,
    this.rowKey,
    this.cellKey,
    required this.emptyLabel,
  });
  final List<String> headers;
  final List<String>? groups, groupKeys;
  final int count, selected;
  final List<String> Function(int) rowBuilder;
  final ValueChanged<int>? onSelect;
  final Set<int> emphasized;
  final Set<int>? checks;
  final void Function(int, bool)? onCheck;
  final Key Function(int)? rowKey;
  final Key? Function(int, int)? cellKey;
  final String emptyLabel;
  @override
  State<MobileReportRecords> createState() => _MobileReportRecordsState();
}

class _MobileReportRecordsState extends State<MobileReportRecords> {
  final expanded = <int>{};
  @override
  Widget build(BuildContext context) {
    if (widget.count == 0) return Center(child: Text(widget.emptyLabel));
    final colors = Theme.of(context).colorScheme;
    return ListView.builder(
      key: const Key('mobile-report-records'),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      itemCount: widget.count,
      itemBuilder: (context, index) {
        final row = widget.rowBuilder(index);
        final full = expanded.contains(index);
        final shown = full
            ? widget.headers.length
            : widget.headers.length.clamp(0, 6);
        return Card(
          key: widget.rowKey?.call(index),
          margin: const EdgeInsets.only(bottom: 8),
          elevation: 0,
          color: widget.selected == index
              ? colors.primaryContainer
              : widget.emphasized.contains(index)
              ? const Color(0xffeaf2f7)
              : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xffd5e0e7)),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onSelect == null
                ? null
                : () => widget.onSelect!(index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.checks != null)
                    Row(
                      children: [
                        Checkbox(
                          value: widget.checks!.contains(index),
                          onChanged: widget.onCheck == null
                              ? null
                              : (value) =>
                                    widget.onCheck!(index, value ?? false),
                        ),
                        const Text('选择此条记录'),
                      ],
                    ),
                  for (var column = 0; column < shown; column++) ...[
                    if (widget.groups != null &&
                        widget.groups![column].isNotEmpty &&
                        (column == 0 ||
                            (widget.groupKeys ?? widget.groups)![column] !=
                                (widget.groupKeys ?? widget.groups)![column -
                                    1]))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Text(
                          widget.groups![column],
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.primary,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: LayoutBuilder(
                        builder: (context, box) => box.maxWidth < 240
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.headers[column],
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  SelectableText(
                                    column < row.length ? row[column] : '',
                                    key: widget.cellKey?.call(index, column),
                                    style: numericStyle.copyWith(
                                      fontSize: 14,
                                      height: 1.4,
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: box.maxWidth * .4,
                                    child: Text(
                                      widget.headers[column],
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: SelectableText(
                                      column < row.length ? row[column] : '',
                                      key: widget.cellKey?.call(index, column),
                                      textAlign: TextAlign.right,
                                      style: numericStyle.copyWith(
                                        fontSize: 14,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                  if (widget.headers.length > 6)
                    TextButton.icon(
                      key: ValueKey('mobile-report-expand-$index'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 44),
                      ),
                      onPressed: () => setState(() {
                        if (full) {
                          expanded.remove(index);
                        } else {
                          expanded.add(index);
                        }
                      }),
                      icon: Icon(
                        full ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                      ),
                      label: Text(
                        full ? '收起详情' : '展开其余 ${widget.headers.length - 6} 项',
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
