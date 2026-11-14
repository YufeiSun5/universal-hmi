import 'dart:js_interop';
import 'package:web/web.dart' as web;

void Function() watchMaterialUnload(bool Function() dirty) {
  final listener = ((web.Event event) {
    if (!dirty()) return;
    event.preventDefault();
    (event as web.BeforeUnloadEvent).returnValue = '';
  }).toJS;
  web.window.addEventListener('beforeunload', listener);
  return () => web.window.removeEventListener('beforeunload', listener);
}
