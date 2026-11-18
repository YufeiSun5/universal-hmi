export 'transport_stub.dart'
    if (dart.library.io) 'transport_native.dart'
    if (dart.library.js_interop) 'transport_web.dart';
