import 'dart:convert';
import 'dart:io';
import 'backend_management_native.dart' show backendManagementAvailable;

File get _script => File(
  '${File(Platform.resolvedExecutable).parent.path}/Autostart-Settings.ps1',
);
bool get autostartAvailable =>
    backendManagementAvailable && _script.existsSync();
List<String> _arguments(bool inspect) => [
  '-NoProfile',
  '-WindowStyle',
  'Hidden',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  _script.path,
  '-ProjectRoot',
  Directory(Platform.environment['HMI_PROJECT_DIR']!).parent.path,
  if (inspect) '-Inspect',
];
String get _powershell =>
    '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}/System32/WindowsPowerShell/v1.0/powershell.exe';
Future<Map<String, dynamic>> readAutostart() async {
  if (!autostartAvailable) throw StateError('请使用本机完整安装的Windows开发端。');
  final result = await Process.run(
    _powershell,
    _arguments(true),
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError('无法读取Windows自启动配置：${result.stderr}');
  }
  return Map<String, dynamic>.from(jsonDecode(result.stdout as String) as Map);
}

Future<void> configureAutostart() async {
  if (!autostartAvailable) throw StateError('请使用本机完整安装的Windows开发端。');
  final result = await Process.run(
    _powershell,
    _arguments(false),
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError('Windows自启动配置未完成，请重新读取状态；需要完成Windows管理员确认。');
  }
}
