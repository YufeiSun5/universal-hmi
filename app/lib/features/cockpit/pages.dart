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
    timer = Timer.periodic(const Duration(seconds: 8), (_) {
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

class CockpitScroll extends StatefulWidget {
  const CockpitScroll({
    super.key,
    required this.pageStart,
    required this.child,
  });

  final int pageStart;
  final Widget child;

  @override
  State<CockpitScroll> createState() => _CockpitScrollState();
}

class _CockpitScrollState extends State<CockpitScroll>
    with SingleTickerProviderStateMixin {
  late final AnimationController motion;
  CockpitScroll? previousPage;

  @override
  void initState() {
    super.initState();
    motion =
        AnimationController(
          vsync: this,
          value: 1,
          duration: const Duration(milliseconds: 1100),
          animationBehavior: AnimationBehavior.preserve,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && previousPage != null) {
            setState(() => previousPage = null);
          }
        });
  }

  @override
  void didUpdateWidget(covariant CockpitScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageStart != widget.pageStart) {
      previousPage = oldWidget;
      motion.forward(from: 0);
    }
  }

  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedBuilder(
      animation: motion,
      builder: (context, _) {
        final offset = Curves.easeInOutCubic.transform(motion.value);
        return Stack(
          fit: StackFit.expand,
          children: [
            if (previousPage case final old?)
              FractionalTranslation(
                key: ValueKey(old.pageStart),
                translation: Offset(0, -offset),
                child: old.child,
              ),
            FractionalTranslation(
              key: ValueKey(widget.pageStart),
              translation: Offset(0, 1 - offset),
              child: widget.child,
            ),
          ],
        );
      },
    ),
  );
}
