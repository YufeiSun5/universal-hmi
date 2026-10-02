import 'dart:async';
import 'dart:ui' show FrameTiming;
import 'package:flutter/widgets.dart';

/// Stops application widgets and drains their last scene before native exit.
///
/// Linux's compositor may need the GTK thread to finish presenting a scene.
/// Await its exact raster frame while GTK is still running, then leave no
/// RenderViews that could submit another scene during synchronous engine exit.
Future<void> drainRenderingForExit({
  WidgetsBinding? binding,
  int Function()? currentFrameNumber,
  void Function(String)? onStage,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final widgets = binding ?? WidgetsBinding.instance;
  final frameNumber =
      currentFrameNumber ??
      () => widgets.platformDispatcher.frameData.frameNumber;
  final rasterized = Completer<void>();
  final detached = Completer<void>();
  int? lastScene;
  var active = true;
  int? frameCallback;

  void onTimings(List<FrameTiming> timings) {
    if (!active || lastScene == null || rasterized.isCompleted) return;
    if (timings.any((timing) => timing.frameNumber == lastScene)) {
      onStage?.call('final frame rasterized: $lastScene');
      rasterized.complete();
    }
  }

  widgets.addTimingsCallback(onTimings);
  try {
    // Unlike runApp, this requests a regular engine frame rather than a warm-up
    // frame, whose engine frame number may be reused.
    frameCallback = widgets.scheduleFrameCallback((_) {
      if (!active) return;
      widgets.attachRootWidget(
        widgets.wrapWithDefaultView(const SizedBox.shrink()),
      );
      widgets.addPostFrameCallback((_) {
        if (!active) return;
        lastScene = frameNumber();
        onStage?.call('final frame submitted: $lastScene');

        // The next build removes every RenderView before the rendering phase.
        // Do this now, not after timing delivery: release timing batches can
        // arrive later, and a resize in between must not submit another scene.
        widgets.attachRootWidget(const ViewCollection(views: <Widget>[]));
        widgets.addPostFrameCallback((_) {
          if (!active) return;
          if (widgets.renderViews.isNotEmpty) {
            detached.completeError(StateError('Exit still has attached views'));
            return;
          }
          onStage?.call('render views detached');
          detached.complete();
        });
        widgets.scheduleFrame();
      });
    });
    await Future.wait([
      rasterized.future,
      detached.future,
    ], eagerError: true).timeout(timeout);
  } finally {
    active = false;
    if (frameCallback != null) widgets.cancelFrameCallbackWithId(frameCallback);
    widgets.removeTimingsCallback(onTimings);
  }
}
