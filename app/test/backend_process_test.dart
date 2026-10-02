import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/platform/backend_process.dart';

class Child extends Fake implements Process {
  final exit = Completer<int>();
  final signals = <ProcessSignal>[];
  bool ignoreTerm = false;
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if ((!ignoreTerm || signal == ProcessSignal.sigkill) && !exit.isCompleted) {
      exit.complete(0);
    }
    return true;
  }
}

void main() {
  test('Existing healthy backend is reused and never owned', () async {
    var launches = 0;
    final backend = LocalBackendProcess(
      isReady: () async => true,
      launch: () async {
        launches++;
        return Child();
      },
    );
    await backend.start();
    await backend.stop();
    expect(launches, 0);
  });
  test(
    'Concurrent start shares launch and normal stop terminates owned child once',
    () async {
      var calls = 0;
      var launches = 0;
      final child = Child();
      final backend = LocalBackendProcess(
        isReady: () async => ++calls > 1,
        launch: () async {
          launches++;
          return child;
        },
      );
      await Future.wait([backend.start(), backend.start()]);
      await Future.wait([backend.stop(), backend.stop()]);
      expect(launches, 1);
      expect(child.signals, [ProcessSignal.sigterm]);
    },
  );
  test('Close during async launch cleans up late owned child', () async {
    final pending = Completer<Process?>();
    final child = Child();
    final backend = LocalBackendProcess(
      isReady: () async => false,
      launch: () => pending.future,
    );
    final starting = backend.start();
    await Future<void>.delayed(Duration.zero);
    final stopping = backend.stop();
    pending.complete(child);
    await Future.wait([starting, stopping]);
    expect(child.signals, [ProcessSignal.sigterm]);
  });
  test('Unhealthy child times out, reports error and does not leak', () async {
    final child = Child();
    final errors = <Object>[];
    final backend = LocalBackendProcess(
      isReady: () async => false,
      launch: () async => child,
      startupTimeout: const Duration(milliseconds: 10),
      pollInterval: const Duration(milliseconds: 1),
      onError: errors.add,
    );
    await backend.start();
    expect(errors.single, isA<TimeoutException>());
    expect(child.exit.isCompleted, true);
  });
  test(
    'Unresponsive owned child is force-killed within bounded shutdown',
    () async {
      var calls = 0;
      final child = Child()..ignoreTerm = true;
      final backend = LocalBackendProcess(
        isReady: () async => ++calls > 1,
        launch: () async => child,
        shutdownTimeout: const Duration(milliseconds: 10),
      );
      await backend.start();
      await backend.stop();
      expect(child.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
    },
  );
}
