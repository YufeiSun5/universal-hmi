import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'charts.dart';

/// Moves only the rows. The panel and its pinned labels stay outside the viewport.
class CockpitRoster extends StatefulWidget {
  const CockpitRoster({
    super.key,
    required this.count,
    required this.minimumRowHeight,
    required this.buildRow,
    required this.buildPanel,
    this.formatRange,
    this.idleDetail,
  });

  final int count;
  final double minimumRowHeight;
  final Widget Function(int index) buildRow;
  final Widget Function(Widget rows, Widget range) buildPanel;
  final String Function(int first, int last)? formatRange;
  final String? idleDetail;

  @override
  State<CockpitRoster> createState() => _CockpitRosterState();
}

class _CockpitRosterState extends State<CockpitRoster>
    with SingleTickerProviderStateMixin {
  final scroll = ScrollController(keepScrollOffset: false);
  final range = ValueNotifier<String?>(null);
  late final Ticker ticker;
  Duration? lastTick;
  double phase = 0, previousExtent = 0, rowExtent = 0;
  int visibleRows = 0;

  bool get overflowing => visibleRows > 0 && widget.count > visibleRows;

  @override
  void initState() {
    super.initState();
    ticker = createTicker(move);
  }

  // Layout decides how many readable rows fit. Update the pinned title after
  // the body layout, so a resize can start or stop scrolling without a jump.
  void syncViewport(Duration _) {
    if (!mounted) return;
    if (overflowing && !ticker.isActive) ticker.start();
    if (!overflowing && ticker.isActive) {
      ticker.stop();
      lastTick = null;
      phase = previousExtent = 0;
    }
    updateRange(overflowing && scroll.hasClients ? scroll.offset : 0);
  }

  void updateRange(double offset) {
    if (!overflowing) {
      range.value = widget.idleDetail;
      return;
    }
    final start = (offset / rowExtent).round().clamp(
      0,
      widget.count - visibleRows,
    );
    final first = start + 1, last = start + visibleRows;
    range.value =
        widget.formatRange?.call(first, last) ??
        '$first–$last / ${widget.count}';
  }

  void move(Duration elapsed) {
    final previous = lastTick ?? elapsed;
    lastTick = elapsed;
    if (!scroll.hasClients || !scroll.position.hasContentDimensions) return;
    final position = scroll.position;
    final extent = position.maxScrollExtent;
    if (extent <= 0 || rowExtent <= 0) return;
    if (extent != previousExtent) {
      final returning = phase > previousExtent;
      final current = position.pixels.clamp(0.0, extent);
      phase = returning ? 2 * extent - current : current;
      previousExtent = extent;
    }
    // Ignore most of a suspended frame so resuming a hidden tab never jumps.
    final seconds = math.min(0.05, (elapsed - previous).inMicroseconds / 1e6);
    final advanced = phase + seconds * 12;
    final reachedBottom = phase < extent && advanced >= extent;
    final reachedTop = advanced >= 2 * extent;
    phase = advanced % (2 * extent);
    final distance = math.min(phase, 2 * extent - phase);
    final edge = math.min(7.0, extent / 2);
    double easeTurn(double d) {
      final t = d / edge;
      return edge * t * t * (2 - t);
    }

    // Land exactly on each edge even when it falls between display frames.
    final next = reachedTop
        ? 0.0
        : reachedBottom
        ? extent
        : distance < edge
        ? easeTurn(distance)
        : extent - distance < edge
        ? extent - easeTurn(extent - distance)
        : distance;
    if (position.pixels != next) scroll.jumpTo(next);

    updateRange(next);
  }

  @override
  void dispose() {
    ticker.dispose();
    scroll.dispose();
    range.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.count == 0) {
      visibleRows = 0;
      WidgetsBinding.instance.addPostFrameCallback(syncViewport);
    }
    return widget.buildPanel(
      LayoutBuilder(
        builder: (context, box) {
          visibleRows = box.maxHeight <= 0
              ? 0
              : math.min(
                  widget.count,
                  math.max(
                    1,
                    (box.maxHeight / widget.minimumRowHeight).floor(),
                  ),
                );
          WidgetsBinding.instance.addPostFrameCallback(syncViewport);
          if (visibleRows == 0) {
            return const SizedBox.shrink();
          }
          rowExtent = overflowing
              ? box.maxHeight / visibleRows
              : math.min(box.maxHeight, widget.minimumRowHeight);
          if (!overflowing) {
            return Column(
              children: [
                for (var i = 0; i < visibleRows; i++)
                  SizedBox(height: rowExtent, child: widget.buildRow(i)),
              ],
            );
          }
          return ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: ListView.builder(
              controller: scroll,
              primary: false,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.count,
              itemExtent: rowExtent,
              itemBuilder: (context, index) => widget.buildRow(index),
            ),
          );
        },
      ),
      ValueListenableBuilder(
        valueListenable: range,
        builder: (context, value, _) => value == null
            ? const SizedBox.shrink()
            : Text(value, style: const TextStyle(color: dim, fontSize: 12)),
      ),
    );
  }
}
