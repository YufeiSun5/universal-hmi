import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:universal_hmi/features/login.dart';
import 'package:universal_hmi/shared/api.dart';

void main() {
  for (final minimum in [5, 7]) {
    testWidgets('Setup shows server password minimum $minimum', (tester) async {
      final api = PlatformClient(
        Uri.parse('http://127.0.0.1:18153'),
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'enabled': true,
              'authenticated': false,
              'setup_required': true,
              'security_model': 'identity-v1',
              'password_min_length': minimum,
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );
      await api.readSession();
      expect(api.session!.passwordMinLength, minimum);
      await tester.pumpWidget(MaterialApp(home: LoginScreen(api: api)));
      expect(find.text('创建首个管理员'), findsOneWidget);
      expect(find.textContaining('设置$minimum–128个字符'), findsOneWidget);
      expect(find.textContaining('15–128'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      api.dispose();
    });
  }
}
