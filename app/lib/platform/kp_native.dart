import 'kp_environment.dart';

KpEnvironment createKpEnvironment() => _NativeKpEnvironment();

class _NativeKpEnvironment implements KpEnvironment {
  @override
  bool get embedded => false;
  @override
  String? takeTicket() => null;
  @override
  String? readToken() => null;
  @override
  void writeToken(String? token) {}
  @override
  bool readLogoutRequested() => false;
  @override
  void writeLogoutRequested(bool requested) {}
  @override
  void close() {}
}
