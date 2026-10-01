import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';

Future<bool> saveFile(Uint8List bytes, String name) async {
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return false;
  await XFile.fromData(bytes, name: name).saveTo(location.path);
  return true;
}
