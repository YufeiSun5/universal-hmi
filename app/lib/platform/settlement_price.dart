import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'settlement_price_stub.dart'
    if (dart.library.js_interop) 'settlement_price_web.dart'
    as mobile;

String settlementPriceKey(String server, String user) =>
    'heat-settlement.price.v1.${base64Url.encode(utf8.encode(jsonEncode([server, user])))}';

Future<String?> loadSettlementPrice(String server, String user) async {
  if (mobile.supported) return mobile.load(user);
  return (await SharedPreferences.getInstance()).getString(
    settlementPriceKey(server, user),
  );
}

Future<void> saveSettlementPrice(
  String server,
  String user,
  String price,
) async {
  if (mobile.supported) return mobile.save(user, price);
  final prefs = await SharedPreferences.getInstance();
  final key = settlementPriceKey(server, user);
  final ok = price.isEmpty
      ? await prefs.remove(key)
      : await prefs.setString(key, price);
  if (!ok) throw StateError('本机单价保存失败');
}
