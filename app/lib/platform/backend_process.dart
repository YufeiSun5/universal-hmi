import 'dart:async';
import 'dart:io';

/// Owns only a child it starts. A healthy pre-existing backend remains external.
class LocalBackendProcess {
  LocalBackendProcess({
    required this.isReady,
    required this.launch,
    this.onError,
    this.startupTimeout = const Duration(seconds: 6),
    this.shutdownTimeout = const Duration(seconds: 6),
    this.pollInterval = const Duration(milliseconds: 100),
  });
  final Future<bool> Function() isReady;
  final Future<Process?> Function() launch;
  final void Function(Object)? onError;
  final Duration startupTimeout, shutdownTimeout, pollInterval;
  Process? _owned;
  Future<void>? _starting;
  Future<void>? _stopping;
  int _generation = 0;

  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    final generation = _generation;
    try {
      if (await isReady() || generation != _generation) return;
      final child = await launch();
      if (child == null) return;
      child.stdout.listen((_) {}, onError: (Object _) {});
      child.stderr.listen((_) {}, onError: (Object _) {});
      if (generation != _generation) {
        await _terminate(child);
        return;
      }
      _owned = child;
      var becameReady = false;
      unawaited(
        child.exitCode.then((code) {
          if (identical(_owned, child)) {
            _owned = null;
            if (!becameReady && generation == _generation) {
              onError?.call(
                StateError('Backend exited before readiness (exit $code)'),
              );
            }
          }
        }),
      );
      final elapsed = Stopwatch()..start();
      while (generation == _generation && identical(_owned, child)) {
        if (await isReady()) {
          becameReady = true;
          return;
        }
        if (elapsed.elapsed >= startupTimeout) {
          _owned = null;
          await _terminate(child);
          throw TimeoutException('Local backend health check timed out');
        }
        await Future<void>.delayed(pollInterval);
      }
    } catch (error) {
      onError?.call(error);
      final child = _owned;
      _owned = null;
      if (child != null) await _terminate(child);
    }
  }

  Future<void> stop() =>
      _stopping ??= _stop().whenComplete(() => _stopping = null);

  Future<void> _stop() async {
    _generation++;
    final child = _owned;
    _owned = null;
    if (child != null) await _terminate(child);
    await _starting;
  }

  Future<void> _terminate(Process child) async {
    child.kill();
    try {
      await child.exitCode.timeout(shutdownTimeout);
    } on TimeoutException {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode.timeout(const Duration(seconds: 2));
    }
  }
}
