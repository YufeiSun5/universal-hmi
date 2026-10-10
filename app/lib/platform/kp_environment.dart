abstract interface class KpEnvironment {
  bool get embedded;
  String? takeTicket();
  String? readToken();
  void writeToken(String? token);
  bool readLogoutRequested();
  void writeLogoutRequested(bool requested);
  void close();
}
