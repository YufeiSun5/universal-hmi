import 'dart:io';

Future<void> openExternalLink(Uri uri) async {
  final url = uri.toString();
  if (Platform.isWindows) {
    await Process.start('rundll32.exe', ['url.dll,FileProtocolHandler', url]);
  } else if (Platform.isMacOS) {
    await Process.start('open', [url]);
  } else if (Platform.isLinux) {
    await Process.start('xdg-open', [url]);
  }
}
