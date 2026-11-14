import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'query_control_theme.dart';

/// Uses the server's filtered total (or the complete local collection). It
/// never estimates a last page from the number of rows in the current page.
class PaginationBar extends StatefulWidget {
  const PaginationBar({
    super.key,
    required this.total,
    required this.offset,
    required this.pageSize,
    required this.onChanged,
    this.busy = false,
    this.label = '条',
    this.trailing,
    this.maxOffset,
    this.note,
    this.minHeight = 0,
  });
  final int total, offset, pageSize;
  final ValueChanged<int> onChanged;
  final bool busy;
  final String label;
  final Widget? trailing;
  final int? maxOffset;
  final String? note;
  final double minHeight;
  @override
  State<PaginationBar> createState() => _PaginationBarState();
}

class _PaginationBarState extends State<PaginationBar> {
  final jump = TextEditingController();
  String? error;
  int get totalPages =>
      (math.max(0, widget.total) / math.max(1, widget.pageSize)).ceil();
  int get pages => widget.maxOffset == null
      ? totalPages
      : math.min(totalPages, widget.maxOffset! ~/ widget.pageSize + 1);
  int get current => widget.offset ~/ math.max(1, widget.pageSize) + 1;
  @override
  void initState() {
    super.initState();
    jump.text = '$current';
  }

  @override
  void didUpdateWidget(PaginationBar old) {
    super.didUpdateWidget(old);
    if (old.offset != widget.offset ||
        old.total != widget.total ||
        old.pageSize != widget.pageSize) {
      jump.text = '$current';
      error = null;
    }
  }

  @override
  void dispose() {
    jump.dispose();
    super.dispose();
  }

  void go(int page) {
    if (widget.busy) return;
    if (page < 1 || page > pages) {
      setState(() => error = '请输入 1–$pages');
      return;
    }
    setState(() => error = null);
    if (page != current) widget.onChanged((page - 1) * widget.pageSize);
  }

  List<int> numbers(int window) {
    if (pages == 0) return [1];
    final center = current.clamp(1, pages).toInt();
    final start = (center - window ~/ 2)
        .clamp(1, math.max(1, pages - window + 1))
        .toInt();
    final set = <int>{
      1,
      pages,
      for (var p = start; p <= math.min(pages, start + window - 1); p++) p,
    };
    return set.toList()..sort();
  }

  String get summaryText =>
      '第 $current 页 · 共 ${widget.total} ${widget.label} / $totalPages 页';

  Future<void> showJump() async {
    final page = await showDialog<int>(
      context: context,
      builder: (_) => _PageJumpDialog(
        current: current,
        pages: pages,
        summary: summaryText,
        note: [
          if (widget.note != null) widget.note!,
          if (pages < totalPages) '当前查询最多浏览 $pages 页，请缩小筛选范围查看其余记录。',
        ].join('\n'),
      ),
    );
    if (mounted && page != null) go(page);
  }

  @override
  Widget build(BuildContext context) => QueryControlTheme(
    minHeight: widget.minHeight,
    child: LayoutBuilder(
      builder: (context, box) {
        final height = math.max(
          widget.minHeight,
          QueryControlTheme.controlHeight(context),
        );
        final iconExtent = math.max(
          widget.minHeight,
          QueryControlTheme.isTouch(context) ? 44.0 : 34.0,
        );
        final compact =
            box.maxWidth < 1000 ||
            MediaQuery.textScalerOf(context).scale(13) > 16;
        final selected = numbers(box.maxWidth < 500 ? 1 : 5);
        final buttons = <Widget>[
          Tooltip(
            message: '上一页',
            child: TextButton(
              style: compact
                  ? TextButton.styleFrom(
                      minimumSize: Size(iconExtent, iconExtent),
                      fixedSize: Size(iconExtent, iconExtent),
                      padding: EdgeInsets.zero,
                    )
                  : null,
              onPressed: widget.busy || widget.offset == 0
                  ? null
                  : () => widget.total == 0
                        ? widget.onChanged(0)
                        : go((current - 1).clamp(1, pages)),
              child: compact
                  ? const Icon(Icons.chevron_left)
                  : const Text('上一页'),
            ),
          ),
          for (var i = 0; i < selected.length; i++) ...[
            if (i > 0 && selected[i] > selected[i - 1] + 1)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 3),
                child: Text('…'),
              ),
            Semantics(
              selected: selected[i] == current,
              child: Tooltip(
                message: '第 ${selected[i]} 页',
                child: TextButton(
                  key: ValueKey('page-${selected[i]}'),
                  style: TextButton.styleFrom(
                    minimumSize: Size(height, height),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    backgroundColor: selected[i] == current
                        ? const Color(0xffdce6ef)
                        : Colors.transparent,
                    foregroundColor: const Color(0xff36536b),
                  ),
                  onPressed: widget.busy || pages == 0 || selected[i] == current
                      ? null
                      : () => go(selected[i]),
                  child: Text(
                    '${selected[i]}',
                    style: TextStyle(
                      fontWeight: selected[i] == current
                          ? FontWeight.w700
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
          ],
          Tooltip(
            message: '下一页',
            child: TextButton(
              style: compact
                  ? TextButton.styleFrom(
                      minimumSize: Size(iconExtent, iconExtent),
                      fixedSize: Size(iconExtent, iconExtent),
                      padding: EdgeInsets.zero,
                    )
                  : null,
              onPressed: widget.busy || current >= pages
                  ? null
                  : () => go(current + 1),
              child: compact
                  ? const Icon(Icons.chevron_right)
                  : const Text('下一页'),
            ),
          ),
        ];
        final summary = Text(summaryText, style: const TextStyle(fontSize: 12));
        final target = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('到', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 8),
            SizedBox(
              width: 58,
              child: TextField(
                key: const ValueKey('page-jump'),
                controller: jump,
                enabled: !widget.busy && pages > 0,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ],
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  isDense: false,
                  contentPadding: EdgeInsets.symmetric(horizontal: 6),
                  hintText: '页码',
                ),
                onSubmitted: (_) => go(int.tryParse(jump.text) ?? 0),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: widget.busy || pages == 0
                  ? null
                  : () => go(int.tryParse(jump.text) ?? 0),
              child: const Text('跳转'),
            ),
          ],
        );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (compact && widget.trailing is Text)
                Align(alignment: Alignment.centerLeft, child: widget.trailing!),
              if (!compact)
                Row(
                  children: [
                    Expanded(child: summary),
                    if (widget.trailing != null) widget.trailing!,
                    for (final b in buttons) ...[b, const SizedBox(width: 8)],
                    const SizedBox(width: 12),
                    target,
                  ],
                )
              else
                Row(
                  children: [
                    if (widget.trailing != null && widget.trailing is! Text)
                      widget.trailing!,
                    buttons.first,
                    const SizedBox(width: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final b
                                in buttons
                                    .skip(1)
                                    .take(buttons.length - 2)) ...[
                              b,
                              const SizedBox(width: 8),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    buttons.last,
                    const SizedBox(width: 8),
                    Tooltip(
                      message:
                          '$summaryText${widget.note == null ? '' : '\n${widget.note}'}',
                      child: IconButton(
                        tooltip: '跳转页码',
                        constraints: BoxConstraints.tightFor(
                          width: iconExtent,
                          height: iconExtent,
                        ),
                        onPressed: widget.busy || pages == 0 ? null : showJump,
                        icon: const Icon(Icons.more_horiz),
                      ),
                    ),
                  ],
                ),
              if (error != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (!compact && pages < totalPages)
                Text(
                  '当前查询最多浏览 $pages 页，请缩小筛选范围查看其余记录。',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        );
      },
    ),
  );
}

class _PageJumpDialog extends StatefulWidget {
  const _PageJumpDialog({
    required this.current,
    required this.pages,
    required this.summary,
    required this.note,
  });
  final int current, pages;
  final String summary, note;
  @override
  State<_PageJumpDialog> createState() => _PageJumpDialogState();
}

class _PageJumpDialogState extends State<_PageJumpDialog> {
  late final input = TextEditingController(text: '${widget.current}');
  String? error;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void submit() {
    final page = int.tryParse(input.text) ?? 0;
    if (page < 1 || page > widget.pages) {
      setState(() => error = '请输入 1–${widget.pages}');
    } else {
      Navigator.pop(context, page);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('跳转页码'),
    content: SizedBox(
      width: 280,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.summary),
            if (widget.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(widget.note),
              ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('page-jump'),
              controller: input,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              decoration: InputDecoration(labelText: '页码', errorText: error),
              onSubmitted: (_) => submit(),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('跳转')),
    ],
  );
}
