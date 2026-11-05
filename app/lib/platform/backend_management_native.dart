import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'backend_endpoint.dart';

bool get backendManagementAvailable =>
    Platform.isWindows &&
    selectedRemoteBackendUri == null &&
    Platform.environment['HMI_PROJECT_DIR']?.isNotEmpty == true &&
    File(
      '${File(Platform.resolvedExecutable).parent.path}/Start-HMI.ps1',
    ).existsSync();

Future<void> manageBackend(
  String action,
  void Function(Map<String, dynamic>) update,
) async {
  if (!backendManagementAvailable ||
      !const ['restart', 'stop', 'start'].contains(action)) {
    throw StateError('此客户端没有本机后台管理入口，请使用本工程安装的开发端。');
  }
  final root = Directory(Platform.environment['HMI_PROJECT_DIR']!).parent;
  final script = File(
    '${File(Platform.resolvedExecutable).parent.path}/Start-HMI.ps1',
  );
  final status = File(
    '${root.path}/backend-operation-${DateTime.now().microsecondsSinceEpoch}.json',
  );
  String? previous;
  Future<void> readStatus() async {
    try {
      final value = await status.readAsString();
      if (value != previous) {
        previous = value;
        update(Map<String, dynamic>.from(jsonDecode(value) as Map));
      }
    } on FileSystemException {
      /* The atomic status file is not yet published. */
    }
  }

  final process = await Process.start(
    '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}/System32/WindowsPowerShell/v1.0/powershell.exe',
    [
      '-NoProfile',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      '-ProjectRoot',
      root.path,
      '-NoUI',
      '-StatusFile',
      status.path,
      if (action == 'restart') '-Restart',
      if (action == 'stop') '-Stop',
    ],
  );
  // Log output is intentionally not displayed: project paths can be private.
  final output = process.stdout.listen((_) {});
  final errors = process.stderr.listen((_) {});
  int? exitCode;
  unawaited(process.exitCode.then((value) => exitCode = value));
  while (exitCode == null) {
    await readStatus();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  // Descendants may inherit unrelated pipe handles on Windows. Completion is
  // the launcher exit plus its atomic status, never EOF from the backend tree.
  await output.cancel();
  await errors.cancel();
  await readStatus();
  if (previous == null) throw StateError('没有收到后台管理的验证结果，不能确认生效。');
  final finalState = jsonDecode(previous!) as Map;
  if (exitCode != 0 && finalState['phase'] != 'failed') {
    throw StateError('后台管理未正常结束，不能确认生效。请重新连接核对实际状态。');
  }
  if (exitCode == 0 &&
      !const ['applied', 'stopped'].contains(finalState['phase'])) {
    throw StateError('后台管理没有返回最终验证结果，请重新连接核对实际状态。');
  }
}
