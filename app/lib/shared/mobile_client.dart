import 'package:flutter/foundation.dart';

/// Native Flutter builds are desktop apps. Mobile browsers and the Android
/// WebView share the same staged product surface, regardless of orientation.
bool isMobileProductClient({bool androidClient = false}) =>
    androidClient ||
    (kIsWeb &&
        (Uri.base.queryParameters['client'] == 'android' ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS));
