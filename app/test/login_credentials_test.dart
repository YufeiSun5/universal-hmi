import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/login.dart';
import 'package:universal_hmi/platform/login_credentials.dart';
import 'auth_ui_test.dart' show AuthFixture;

class MemoryCredentials implements LoginCredentialStore {
  final values = <String, String>{
    'first': 'fixture-only',
    'second': 'second-test',
  };
  String selected = 'first';
  int saves = 0;
  RememberedLogin snapshot() => RememberedLogin(
    accounts: values.keys.toList(),
    username: selected,
    password: values[selected] ?? '',
  );
  @override
  Future<RememberedLogin> load() async => snapshot();
  @override
  Future<RememberedLogin> select(String name) async {
    selected = name;
    return snapshot();
  }

  @override
  Future<RememberedLogin> save(String name, String password) async {
    saves++;
    values[name] = password;
    selected = name;
    return snapshot();
  }

  @override
  Future<RememberedLogin> remove(String name) async {
    values.remove(name);
    selected = '';
    return snapshot();
  }

  @override
  Future<RememberedLogin> clear() async {
    values.clear();
    selected = '';
    return snapshot();
  }
}

void main() {
  testWidgets(
    'Android remembered accounts fill, switch, forget and only save successful login',
    (t) async {
      t.view.physicalSize = const Size(420, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final api = AuthFixture().api;
      final store = MemoryCredentials();
      await api.readSession();
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LoginScreen(
              api: api,
              androidClient: true,
              credentialStore: store,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      String field(String key) =>
          t.widget<TextField>(find.byKey(Key(key))).controller!.text;
      expect(field('login-username'), 'first');
      expect(field('login-password'), 'fixture-only');
      await t.tap(find.byTooltip('选择已记住的账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('second'));
      await t.pumpAndSettle();
      expect(field('login-password'), 'second-test');
      await t.tap(find.byKey(const Key('login-submit')));
      await t.pumpAndSettle();
      expect(store.saves, 0);
      await t.enterText(
        find.byKey(const Key('login-password')),
        'fixture-only',
      );
      await t.tap(find.byKey(const Key('login-submit')));
      await t.pumpAndSettle();
      expect(store.saves, 1);
      expect(store.values['second'], 'fixture-only');
      await t.tap(find.text('清除全部已记住密码'));
      await t.pumpAndSettle();
      expect(store.values, isEmpty);
      expect(field('login-password'), '');
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      api.close();
    },
  );
}
