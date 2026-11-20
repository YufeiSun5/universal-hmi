import 'package:web/web.dart' as web;

void openExternalLink(Uri uri) {
  web.window.open(uri.toString(), '_blank', 'noopener,noreferrer');
}
