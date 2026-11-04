import 'package:web/web.dart' as web;

void openAndroidConnection() {
  if (Uri.base.queryParameters['client'] == 'android') {
    web.window.location.assign('/_hmi_native/connection');
  }
}
