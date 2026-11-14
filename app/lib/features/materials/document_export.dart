import 'dart:convert';
import '../../platform/save.dart';
import '../../shared/api.dart';
import 'session.dart';

Future<String> exportMaterialDocument(PlatformApi api, Json record) async {
  final result = await api.request(
    'GET',
    '$materialsBase/documents/${record['id']}/export',
    query: const {'encoding': 'base64'},
  );
  final saved = await saveFile(
    base64Decode(materialText(result, 'data')),
    materialText(result, 'name'),
  );
  return saved ? 'Excel已生成，已交给文件保存功能。' : '已取消文件保存，出库记录不变。';
}
