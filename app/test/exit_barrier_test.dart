import 'dart:async';
import 'dart:ui' show AppExitResponse, FrameTiming;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/platform/backend_native.dart';
import 'package:universal_hmi/platform/backend_process.dart';
import 'package:universal_hmi/platform/exit_barrier.dart';

FrameTiming timing(int frameNumber) => FrameTiming(
  vsyncStart: 0,
  buildStart: 1,
  buildFinish: 2,
  rasterStart: 3,
  rasterFinish: 4,
  rasterFinishWallTime: 4,
  frameNumber: frameNumber,
);

class TimerProbe extends StatefulWidget {
  const TimerProbe({super.key, required this.onTick, required this.onDispose});
  final VoidCallback onTick, onDispose;

  @override
  State<TimerProbe> createState() => _TimerProbeState();
}

class _TimerProbeState extends State<TimerProbe> {
  late final Timer timer = Timer.periodic(
    const Duration(milliseconds: 10),
    (_) => widget.onTick(),
  );

  @override
  void initState() {
    super.initState();
    timer;
  }

  @override
  void dispose() {
    timer.cancel();
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('Running');
}

void main() {
  testWidgets(
    'Exit disposes timers, detaches views and rejects stale timings',
    (tester) async {
      var ticks = 0, disposed = false, completed = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: TimerProbe(
            onTick: () => ticks++,
            onDispose: () => disposed = true,
          ),
        ),
      );
      final draining = drainRenderingForExit(
        binding: tester.binding,
        currentFrameNumber: () => 42,
      ).then((_) => completed = true);
      await tester.pump();
      expect(disposed, isTrue);
      final stoppedAt = ticks;
      tester.binding.platformDispatcher.onReportTimings!([
        timing(41),
        timing(43),
      ]);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.renderViews, isEmpty);
      expect(ticks, stoppedAt);
      expect(completed, isFalse);
      tester.binding.platformDispatcher.onReportTimings!([timing(42)]);
      await draining;
      expect(completed, isTrue);
    },
  );

  testWidgets('Exact raster timing alone does not bypass view detachment', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    var completed = false;
    final draining = drainRenderingForExit(
      binding: tester.binding,
      currentFrameNumber: () => 7,
    ).then((_) => completed = true);
    await tester.pump();
    tester.binding.platformDispatcher.onReportTimings!([timing(7)]);
    await Future<void>.value();
    expect(completed, isFalse);
    await tester.pump();
    await draining;
    expect(tester.binding.renderViews, isEmpty);
  });

  testWidgets('Missing raster timing fails and removes the timing callback', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final stages = <String>[];
    final draining = drainRenderingForExit(
      binding: tester.binding,
      currentFrameNumber: () => 12,
      onStage: stages.add,
      timeout: const Duration(milliseconds: 50),
    );
    final failure = expectLater(draining, throwsA(isA<TimeoutException>()));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    await failure;
    tester.binding.platformDispatcher.onReportTimings?.call([timing(12)]);
    expect(stages, isNot(contains('final frame rasterized: 12')));
  });

  testWidgets('Concurrent exit requests share one renderer drain', (
    tester,
  ) async {
    final drained = Completer<void>();
    var drains = 0;
    final backend = LocalBackendProcess(
      isReady: () async => true,
      launch: () async => null,
    );
    final listener = listenForBackendExit(
      backend,
      drainRendering: () {
        drains++;
        return drained.future;
      },
    );
    addTearDown(listener.dispose);
    final requests = Future.wait([
      listener.didRequestAppExit(),
      listener.didRequestAppExit(),
    ]);
    await tester.pump();
    expect(drains, 1);
    drained.complete();
    expect(await requests, [AppExitResponse.exit, AppExitResponse.exit]);
    expect(await listener.didRequestAppExit(), AppExitResponse.exit);
    expect(drains, 1);
  });

  testWidgets('Drain failure cancels native exit and permits retry', (
    tester,
  ) async {
    var attempts = 0;
    final listener = listenForBackendExit(
      LocalBackendProcess(isReady: () async => true, launch: () async => null),
      drainRendering: () async {
        if (++attempts == 1) {
          throw TimeoutException('Missing final raster frame');
        }
      },
    );
    addTearDown(listener.dispose);
    expect(await listener.didRequestAppExit(), AppExitResponse.cancel);
    expect(await listener.didRequestAppExit(), AppExitResponse.exit);
    expect(attempts, 2);
  });
}
