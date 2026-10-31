import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'kp_environment.dart';

KpEnvironment createKpEnvironment() => _WebKpEnvironment();

class _WebKpEnvironment implements KpEnvironment {
  static const key = 'universal-hmi.kp.web-session.v1';
  late final JSFunction listener = ((web.Event event) {
    if (embedded && _ticket != null) web.window.location.reload();
  }).toJS;

  _WebKpEnvironment() {
    if (embedded) web.window.addEventListener('hashchange', listener);
  }

  @override
  bool get embedded => web.window.location.pathname.startsWith('/kp/');

  String? get _ticket => Uri.splitQueryString(
    web.window.location.hash.replaceFirst(RegExp('^#'), ''),
  )['ticket'];

  @override
  String? takeTicket() {
    final ticket = _ticket;
    if (ticket != null) {
      web.window.history.replaceState(
        null,
        '',
        '${web.window.location.pathname}${web.window.location.search}',
      );
    }
    return ticket;
  }

  @override
  String? readToken() {
    try {
      return web.window.sessionStorage.getItem(key);
    } catch (_) {
      return null;
    }
  }

  @override
  void writeToken(String? token) {
    try {
      if (token == null) {
        web.window.sessionStorage.removeItem(key);
      } else {
        web.window.sessionStorage.setItem(key, token);
      }
    } catch (_) {
      // Embedded storage may be disabled. The in-memory session remains usable;
      // a refresh will require entering again through KP.
    }
  }

  @override
  void close() => web.window.removeEventListener('hashchange', listener);

  @override
  bool readLogoutRequested() {
    try {
      return web.window.sessionStorage.getItem('$key.logout-pending') == '1';
    } catch (_) {
      return false;
    }
  }

  @override
  void writeLogoutRequested(bool requested) {
    try {
      if (requested) {
        web.window.sessionStorage.setItem('$key.logout-pending', '1');
      } else {
        web.window.sessionStorage.removeItem('$key.logout-pending');
      }
    } catch (_) {}
  }
}
