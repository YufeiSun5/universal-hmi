bool get backendManagementAvailable => false;
Future<void> manageBackend(
  String action,
  void Function(Map<String, dynamic>) update,
) async => throw UnsupportedError('请使用本机安装的开发端管理后台。');
