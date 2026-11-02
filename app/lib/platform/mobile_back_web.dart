import 'dart:js_interop';

@JS('hmiAndroidBack')
external set _back(JSFunction? callback);

void Function() registerMobileBack(bool Function() handler) {
  if (Uri.base.queryParameters['client'] != 'android') return () {};
  _back = (() => handler().toJS).toJS;
  return () => _back = null;
}
