import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Cycles a fixed-size viewport so every record can be read on an unattended wall.
class CockpitPages extends StatefulWidget {
  const CockpitPages({
    super.key,
    required this.count,
    required this.pageSize,
    required this.buildPage,
  });

  final int count, pageSize;
  final Widget Function(int first, int last, String? range) buildPage;

  @override
  State<CockpitPages> createState() => _CockpitPagesState();
}

class _CockpitPagesState extends State<CockpitPages> {
  int page = 0;
  Timer? timer;
  int get pageCount =>
      math.max(1, (widget.count + widget.pageSize - 1) ~/ widget.pageSize);

  @override
  void initState() {
    super.initState();
    schedule();
  }

  @override
  void didUpdateWidget(covariant CockpitPages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.count != widget.count ||
        oldWidget.pageSize != widget.pageSize) {
      page = math.min(page, pageCount - 1);
      schedule();
    }
  }

  void schedule() {
    timer?.cancel();
    if (pageCount < 2) return;
    timer = Timer.periodic(const Duration(seconds: 12), (_) {
      setState(() => page = (page + 1) % pageCount);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final first = page * widget.pageSize;
    final last = math.min(first + widget.pageSize, widget.count);
    final range = pageCount > 1 ? '${first + 1}–$last / ${widget.count}' : null;
    return widget.buildPage(first, last, range);
  }
}
