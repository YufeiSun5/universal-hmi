import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';

class ProcessFile {
  const ProcessFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

Future<ProcessFile?> pickProcessFile({required bool image}) async {
  final file = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        label: image ? 'PNG / JPEG 图片' : '工艺画面 JSON',
        extensions: image ? ['png', 'jpg', 'jpeg'] : ['json'],
        mimeTypes: image ? ['image/png', 'image/jpeg'] : ['application/json'],
        uniformTypeIdentifiers: image
            ? ['public.png', 'public.jpeg']
            : ['public.json'],
      ),
    ],
  );
  if (file == null) return null;
  final limit = image ? 2 * 1024 * 1024 : 8 * 1024 * 1024;
  if (await file.length() > limit) {
    throw FormatException(image ? '单张图片不能超过 2 MiB' : '画面文件不能超过 8 MiB');
  }
  return ProcessFile(file.name, await file.readAsBytes());
}

Future<ProcessFile?> pickProcessTransferFile() async {
  final file = await openFile(
    acceptedTypeGroups: [
      const XTypeGroup(
        label: '工艺资料 JSON / XLSX / CSV',
        extensions: ['json', 'xlsx', 'csv'],
      ),
    ],
  );
  if (file == null) return null;
  if (await file.length() > 32 * 1024 * 1024) {
    throw const FormatException('文件不能超过 32 MiB');
  }
  return ProcessFile(file.name, await file.readAsBytes());
}
