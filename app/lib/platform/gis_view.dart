export 'gis_view_stub.dart'
    if (dart.library.io) 'gis_view_native.dart'
    if (dart.library.js_interop) 'gis_view_web.dart';
