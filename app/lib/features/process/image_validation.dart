import 'dart:typed_data';

/// Read bounded PNG IHDR / JPEG SOF metadata before asking any platform codec
/// to allocate pixels. This path also works on Flutter Web (no descriptors).
({String mime, int width, int height}) processImageHeader(Uint8List bytes) {
  if (bytes.length > 2 * 1024 * 1024) {
    throw const FormatException('仅支持不超过 2 MiB 的 PNG/JPEG 图片');
  }
  int u16(int offset) => (bytes[offset] << 8) | bytes[offset + 1];
  int u32(int offset) => ByteData.sublistView(bytes).getUint32(offset);
  ({String mime, int width, int height}) checked(
    String mime,
    int width,
    int height,
  ) {
    if (width < 1 ||
        height < 1 ||
        width > 8192 ||
        height > 8192 ||
        width * height > 16000000) {
      throw const FormatException('图片单边不超过8192像素，总像素不超过1600万');
    }
    return (mime: mime, width: width, height: height);
  }

  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length >= 8 &&
      List.generate(8, (i) => bytes[i] == signature[i]).every((v) => v)) {
    if (bytes.length < 33 ||
        u32(8) != 13 ||
        bytes[12] != 73 ||
        bytes[13] != 72 ||
        bytes[14] != 68 ||
        bytes[15] != 82) {
      throw const FormatException('PNG 图片头无效');
    }
    return checked('image/png', u32(16), u32(20));
  }
  if (bytes.length >= 4 && bytes[0] == 255 && bytes[1] == 216) {
    var offset = 2;
    while (offset < bytes.length) {
      if (bytes[offset++] != 255) break;
      while (offset < bytes.length && bytes[offset] == 255) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      // SOF must precede compressed scan data; standalone markers have no size.
      if (marker == 0 || marker == 0xda || marker == 0xd9) break;
      if (marker == 1 || marker >= 0xd0 && marker <= 0xd8) continue;
      if (offset + 2 > bytes.length) break;
      final length = u16(offset);
      if (length < 2 || offset + length > bytes.length) break;
      if (marker >= 0xc0 &&
          marker <= 0xcf &&
          !{0xc4, 0xc8, 0xcc}.contains(marker)) {
        if (length < 8) break;
        return checked('image/jpeg', u16(offset + 5), u16(offset + 3));
      }
      offset += length;
    }
    throw const FormatException('JPEG 图片头无效或不完整');
  }
  throw const FormatException('仅支持不超过 2 MiB 的 PNG/JPEG 图片');
}
