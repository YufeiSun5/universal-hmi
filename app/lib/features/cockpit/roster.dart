import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Moves only the rows. The panel and its pinned labels stay outside the viewport.
class CockpitRoster extends StatefulWidget {
  const CockpitRoster({
    super.key,
    required this.count,
    required this.visibleRows,
    required this.buildRow,
    required this.buildPanel,
  });

  final int count, visibleRows;
  final Widget Function(int index) buildRow;
  final Widget Function(Widget rows, String? range) buildPanel;

  @override
  State<CockpitRoster> createState() => _CockpitRosterState();
}

class _CockpitRosterState extends State<CockpitRoster>
    with SingleTickerProviderStateMixin {
  final scroll = ScrollController(keepScrollOffset: false);
  late final Ticker ticker;
  Duration? lastTick;
  double phase = 0, previousExtent = 0, rowExtent = 0;
  int first = 0;

  bool get overflowing => widget.count > widget.visibleRows;

  @override
  void initState() {
    super.initState();
    ticker = createTicker(move);
    if (overflowing) ticker.start();
  }

  @override
  void didUpdateWidget(covariant CockpitRoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    first = first.clamp(0, math.max(0, widget.count - widget.visibleRows));
    if (overflowing && !ticker.isActive) ticker.start();
    if (!overflowing && ticker.isActive) {
      ticker.stop();
      lastTick = null;
      phase = previousExtent = 0;
    }
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
    phase = (phase + seconds * 12) % (2 * extent);
    final distance = math.min(phase, 2 * extent - phase);
    final edge = math.min(7.0, extent / 2);
    double easeTurn(double d) {
      final t = d / edge;
      return edge * t * t * (2 - t);
    }

    final next = distance < edge
        ? easeTurn(distance)
        : extent - distance < edge
        ? extent - easeTurn(extent - distance)
        : distance;
    if (position.pixels != next) scroll.jumpTo(next);

    final start = ((next + 0.001) / rowExtent).floor().clamp(
      0,
      widget.count - widget.visibleRows,
    );
    if (first != start) setState(() => first = start);
  }

  @override
  void dispose() {
    ticker.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final range = overflowing
        ? '${first + 1}–${first + widget.visibleRows} / ${widget.count}'
        : null;
    return widget.buildPanel(
      LayoutBuilder(
        builder: (context, box) {
          final visible = math.min(widget.count, widget.visibleRows);
          if (visible == 0 || box.maxHeight <= 0) {
            return const SizedBox.shrink();
          }
          rowExtent = box.maxHeight / visible;
          if (!overflowing) {
            return Column(
              children: [
                for (var i = 0; i < widget.count; i++)
                  Expanded(child: widget.buildRow(i)),
              ],
            );
          }
          return ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false),
            child: ListView.builder(
              controller: scroll,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: widget.count,
              itemExtent: rowExtent,
              itemBuilder: (context, index) => widget.buildRow(index),
            ),
          );
        },
      ),
      range,
    );
  }
}
