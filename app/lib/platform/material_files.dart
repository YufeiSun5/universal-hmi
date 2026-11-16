import 'package:file_selector/file_selector.dart';
import 'process_files.dart';

Future<ProcessFile?> pickRequisitionFile({bool excelOnly = false}) async {
  final file = await openFile(
    acceptedTypeGroups: [
      XTypeGroup(
        label: excelOnly ? 'Excel 请购清单' : '申请附件',
        extensions: excelOnly
            ? ['xlsx']
            : ['xlsx', 'pdf', 'png', 'jpg', 'jpeg'],
      ),
    ],
  );
  if (file == null) return null;
  if (await file.length() > 10 * 1024 * 1024) {
    throw FormatException('${file.name} 超过10 MiB');
  }
  return ProcessFile(file.name, await file.readAsBytes());
}

Future<List<ProcessFile>> pickMaterialImages({bool multiple = true}) async {
  const types = [
    XTypeGroup(
      label: 'JPEG / PNG 图片',
      extensions: ['jpg', 'jpeg', 'png'],
      mimeTypes: ['image/jpeg', 'image/png'],
      uniformTypeIdentifiers: ['public.jpeg', 'public.png'],
    ),
  ];
  final files = multiple
      ? await openFiles(acceptedTypeGroups: types)
      : [?await openFile(acceptedTypeGroups: types)];
  if (files.length > 10) throw const FormatException('每单最多10张图片');
  final result = <ProcessFile>[];
  for (final file in files) {
    if (await file.length() > 10 * 1024 * 1024) {
      throw FormatException('${file.name} 超过10 MiB');
    }
    result.add(ProcessFile(file.name, await file.readAsBytes()));
  }
  return result;
}
