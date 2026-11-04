class RememberedLogin {
  const RememberedLogin({
    this.accounts = const [],
    this.username = '',
    this.password = '',
  });
  final List<String> accounts;
  final String username;
  final String password;
}

abstract interface class LoginCredentialStore {
  Future<RememberedLogin> load();
  Future<RememberedLogin> select(String username);
  Future<RememberedLogin> save(String username, String password);
  Future<RememberedLogin> remove(String username);
  Future<RememberedLogin> clear();
}
