import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_hmi/features/process/background_editor.dart';
import 'package:universal_hmi/features/process/image_validation.dart';
import 'package:universal_hmi/platform/process_files.dart';

const jpeg =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wgARCAADAAIDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUAQEAAAAAAAAAAAAAAAAAAAAE/9oADAMBAAIQAxAAAAGCHh//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAn//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/AX//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/AX//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/An//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/IX//2gAMAwEAAgADAAAAEPP/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EH//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/EH//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/EH//2Q==';

Uint8List pngHeader(int width, int height) {
  final bytes = Uint8List(33)
    ..setRange(0, 16, [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      13,
      73,
      72,
      68,
      82,
    ]);
  ByteData.sublistView(bytes)
    ..setUint32(16, width)
    ..setUint32(20, height);
  return bytes;
}

Uint8List jpegHeader(int marker, int width, int height) => Uint8List.fromList([
  255,
  216,
  255,
  224,
  0,
  4,
  0,
  0,
  255,
  marker,
  0,
  11,
  8,
  height >> 8,
  height & 255,
  width >> 8,
  width & 255,
  1,
  1,
  17,
  0,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'portable PNG and baseline/progressive JPEG dimensions respect bounded segments',
    () {
      expect(processImageHeader(pngHeader(320, 240)), (
        mime: 'image/png',
        width: 320,
        height: 240,
      ));
      for (final marker in [0xc0, 0xc2]) {
        expect(processImageHeader(jpegHeader(marker, 320, 240)), (
          mime: 'image/jpeg',
          width: 320,
          height: 240,
        ));
      }
      for (final bytes in [
        pngHeader(0, 240),
        pngHeader(8193, 1),
        pngHeader(4001, 4000),
        jpegHeader(0xc0, 0, 240),
        jpegHeader(0xc2, 8193, 1),
        jpegHeader(0xc2, 4001, 4000),
        Uint8List.fromList([255, 216, 255, 224, 255, 255]),
        Uint8List.fromList([255, 216, 255, 224, 0, 0]),
        Uint8List.fromList(pngHeader(20, 20).sublist(0, 24)),
      ]) {
        expect(() => processImageHeader(bytes), throwsFormatException);
      }
      final badSignature = pngHeader(20, 20)..[7] = 0;
      expect(() => processImageHeader(badSignature), throwsFormatException);
      final badIHDR = pngHeader(20, 20)..[11] = 12;
      expect(() => processImageHeader(badIHDR), throwsFormatException);
    },
  );
  testWidgets(
    'full cross-platform codec decodes progressive JPEG after header checks',
    (tester) async {
      final bytes = base64Decode(jpeg);
      expect(processImageHeader(bytes), (
        mime: 'image/jpeg',
        width: 2,
        height: 3,
      ));
      final asset = await tester.runAsync(
        () => backgroundImage(ProcessFile('valid.jpg', bytes)),
      );
      expect(asset!.mime, 'image/jpeg');
      expect(asset.bytes, bytes);
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAFElEQVR4nGOUCGhiYGBgYgADKAUAEUgA8HLThWgAAAAASUVORK5CYII=',
      );
      final pngAsset = await tester.runAsync(
        () => backgroundImage(ProcessFile('valid.png', png)),
      );
      expect(pngAsset!.mime, 'image/png');
      final invalid = pngHeader(2, 3);
      Object? failure;
      await tester.runAsync(() async {
        try {
          await backgroundImage(ProcessFile('invalid.png', invalid));
        } catch (e) {
          failure = e;
        }
      });
      expect(failure, isNotNull);
    },
  );
}
