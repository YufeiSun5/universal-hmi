bool get autostartAvailable => false;
Future<Map<String, dynamic>> readAutostart() async =>
    throw UnsupportedError('请在服务器本机安装的Windows开发端配置自启动。');
Future<void> configureAutostart() async =>
    throw UnsupportedError('请在服务器本机安装的Windows开发端配置自启动。');
