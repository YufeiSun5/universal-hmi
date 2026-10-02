import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/api.dart';
import '../shared/theme.dart';

/// A bounded viewport of live variables; no cell is created for offscreen data.
class VariableMatrix extends StatefulWidget {
  const VariableMatrix({
    super.key,
    required this.itemCount,
    required this.pointBuilder,
    required this.liveBuilder,
    required this.online,
    required this.onSelect,
    this.selectedID = '',
    this.onContext,
    this.compact = true,
    this.showStation = false,
    this.initialScrollOffset = 0,
    this.onScroll,
  });

  final int itemCount;
  final Json Function(int) pointBuilder;
  final Json Function(String) liveBuilder;
  final bool online, compact, showStation;
  final String selectedID;
  final ValueChanged<int> onSelect;
  final void Function(int, Offset)? onContext;
  final double initialScrollOffset;
  final ValueChanged<double>? onScroll;

  @override
  State<VariableMatrix> createState() => _VariableMatrixState();
}

class _VariableMatrixState extends State<VariableMatrix> {
  late final ScrollController scroll = ScrollController(
    initialScrollOffset: widget.initialScrollOffset,
    keepScrollOffset: false,
  )..addListener(() => widget.onScroll?.call(scroll.offset));
  final focus = FocusNode();
  int activeIndex = -1;
  int focusedIndex = -1;

  @override
  void dispose() {
    scroll.dispose();
    focus.dispose();
    super.dispose();
  }

  void select(int index) {
    activeIndex = index;
    focus.requestFocus();
    widget.onSelect(index);
  }

  void step(int delta, int columns, double extent, {int? target}) {
    if (widget.itemCount == 0) return;
    final index = (target ?? activeIndex + delta).clamp(
      0,
      widget.itemCount - 1,
    );
    select(index);
    if (!scroll.hasClients) return;
    final top = (index ~/ columns) * extent;
    final viewport = scroll.position.viewportDimension;
    if (top < scroll.offset || top + extent > scroll.offset + viewport) {
      scroll.jumpTo(
        (top - (delta > 0 ? viewport - extent : 0)).clamp(
          0,
          scroll.position.maxScrollExtent,
        ),
      );
    }
  }

  Widget tile(int index) {
    final point = widget.pointBuilder(index);
    final id = point['id'].toString();
    final live = widget.liveBuilder(id);
    final quality = widget.online
        ? '${live['quality'] ?? 'missing'}'
        : 'offline';
    final (label, icon, color, background) = switch (quality) {
      'good' => (
        '正常',
        Icons.check_circle_outline,
        const Color(0xff66717e),
        Colors.white,
      ),
      'bad' => (
        '坏质量',
        Icons.error_outline,
        const Color(0xffb42318),
        const Color(0xfffff5f3),
      ),
      'stale' => (
        '陈旧',
        Icons.schedule,
        const Color(0xff9a6700),
        const Color(0xfffffaef),
      ),
      'offline' => (
        '离线',
        Icons.cloud_off,
        const Color(0xff6c7380),
        const Color(0xffedf0f4),
      ),
      'imported' => (
        '导入',
        Icons.file_upload_outlined,
        const Color(0xff5573a8),
        const Color(0xfff4f7fc),
      ),
      _ => (
        '无数据',
        Icons.help_outline,
        WorkbenchColors.muted,
        const Color(0xfff4f6f9),
      ),
    };
    final mode = point['writable'] == true && point['rw_mode'] != 'R'
        ? '${point['rw_mode'] ?? 'RW'}'
        : 'R';
    final name = '${point['name'] ?? id}';
    final value = quality == 'missing' ? '—' : number(live['value']);
    final unit = '${point['unit'] ?? ''}';
    final selected = widget.selectedID == id;
    return Tooltip(
      waitDuration: const Duration(milliseconds: 350),
      message:
          '${point['station']} / $name\n$value $unit · $label · $mode\n'
          '源时间 ${matrixTime(live['source_time'])}\n'
          '接收时间 ${matrixTime(live['received_time'])}',
      child: Material(
        color: selected ? WorkbenchColors.selection : background,
        child: InkWell(
          key: Key('point-row-$id'),
          onTap: () => select(index),
          onFocusChange: (focused) => setState(() {
            focusedIndex = focused ? index : -1;
            if (focused) activeIndex = index;
          }),
          onSecondaryTapDown: (details) {
            activeIndex = index;
            focus.requestFocus();
            widget.onContext?.call(index, details.globalPosition);
          },
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: quality == 'good' ? Colors.transparent : color,
                  width: 3,
                ),
                bottom: BorderSide(
                  color: selected
                      ? const Color(0xff185adb)
                      : const Color(0xffd8dee5),
                  width: selected ? 2 : 1,
                ),
              ),
            ),
            foregroundDecoration: focusedIndex == index
                ? BoxDecoration(
                    border: Border.all(
                      color: const Color(0xff185adb),
                      width: 1.5,
                    ),
                  )
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.showStation)
                  Text(
                    '${point['station']}',
                    key: Key('matrix-station-$id'),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff596572),
                      height: 1.3,
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.2,
                          color: Color(0xff17212b),
                        ),
                      ),
                    ),
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          value,
                          key: Key('value-$id'),
                          maxLines: 1,
                          softWrap: false,
                          style: numericStyle.copyWith(
                            fontSize: widget.compact ? 20 : 24,
                            height: 1.2,
                            fontWeight: FontWeight.w400,
                            color: quality == 'good'
                                ? const Color(0xff17212b)
                                : color,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 3),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 36),
                      child: Text(
                        unit,
                        key: Key('unit-$id'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xff596572),
                        ),
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  children: [
                    Icon(
                      icon,
                      key: Key('quality-$id'),
                      size: 12,
                      color: color,
                      semanticLabel: label,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        color: color,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      mode,
                      key: Key('rw-$id'),
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        color: mode == 'R'
                            ? const Color(0xff596572)
                            : const Color(0xff185adb),
                      ),
                    ),
                  ],
                ),
                if (!widget.compact)
                  Text(
                    matrixTime(live['source_time'], timeOnly: true),
                    key: Key('source-age-$id'),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff596572),
                      height: 1.4,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final minimumWidth = widget.compact ? 124.0 : 164.0;
      final columns = math.max(
        1,
        ((box.maxWidth - 20) / (minimumWidth + 4)).floor(),
      );
      final extent =
          (widget.compact ? 60.0 : 80.0) + (widget.showStation ? 16 : 0);
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter): () {
            if (activeIndex >= 0) select(activeIndex);
          },
          const SingleActivator(LogicalKeyboardKey.space): () {
            if (activeIndex >= 0) select(activeIndex);
          },
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              step(columns, columns, extent + 4),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              step(-columns, columns, extent + 4),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              step(1, columns, extent + 4),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              step(-1, columns, extent + 4),
          const SingleActivator(LogicalKeyboardKey.home): () =>
              step(-1, columns, extent + 4, target: 0),
          const SingleActivator(LogicalKeyboardKey.end): () =>
              step(1, columns, extent + 4, target: widget.itemCount - 1),
        },
        child: Focus(
          focusNode: focus,
          child: widget.itemCount == 0
              ? const Center(child: Text('没有符合条件的数据'))
              : Scrollbar(
                  controller: scroll,
                  thumbVisibility: true,
                  child: GridView.builder(
                    key: const Key('point-grid-scroll'),
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    cacheExtent: 0,
                    itemCount: widget.itemCount,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisExtent: extent,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                    ),
                    itemBuilder: (context, index) => tile(index),
                  ),
                ),
        ),
      );
    },
  );
}

String matrixTime(Object? value, {bool timeOnly = false}) {
  final date = DateTime.tryParse('$value')?.toLocal();
  if (date == null) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
  return timeOnly
      ? time
      : '${date.year}-${two(date.month)}-${two(date.day)} $time';
}
