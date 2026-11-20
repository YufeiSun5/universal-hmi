export 'external_link_stub.dart'
    if (dart.library.io) 'external_link_native.dart'
    if (dart.library.js_interop) 'external_link_web.dart';
