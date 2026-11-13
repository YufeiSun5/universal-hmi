export 'external_site_view_stub.dart'
    if (dart.library.io) 'external_site_view_native.dart'
    if (dart.library.js_interop) 'external_site_view_web.dart';
