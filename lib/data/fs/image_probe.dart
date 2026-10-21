import 'dart:io';
import 'dart:typed_data';

/// Format, dimensions and MIME type of an image, read from its header.
class ImageInfo {
  const ImageInfo({
    required this.mimeType,
    required this.width,
    required this.height,
    required this.byteSize,
  });

  final String mimeType;
  final int width;
  final int height;
  final int byteSize;

  /// Whether the image is big enough to be worth showing as cover art.
  ///
  /// Small square images in music folders are usually icons rather than
  /// artwork.
  bool get isPlausibleArtwork => width >= 100 && height >= 100;

  double get aspectRatio => height == 0 ? 1 : width / height;

  @override
  String toString() => 'ImageInfo($mimeType, ${width}x$height, $byteSize B)';
}

/// Reads image dimensions without decoding pixels.
///
/// Parsing headers rather than decoding matters during a scan: cover art is
/// routinely several megabytes, and a library has thousands of them. Also
/// avoids needing a Flutter binding, so it works in plain Dart tools and tests.
abstract final class ImageProbe {
  /// How much of the file to read. JPEG segment chains can be long, but the
  /// dimensions always appear well before this.
  static const _headerBytes = 64 * 1024;

  /// Probes [file], or returns null if it is not a recognisable image.
  static ImageInfo? probeFile(File file) {
    try {
      final length = file.lengthSync();
      if (length < 12) return null;
      final handle = file.openSync();
      try {
        final take = length < _headerBytes ? length : _headerBytes;
        final bytes = handle.readSync(take);
        return probeBytes(bytes, totalLength: length);
      } finally {
        handle.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  /// Probes an in-memory image, such as one extracted from a tag.
  static ImageInfo? probeBytes(Uint8List bytes, {int? totalLength}) {
    final size = totalLength ?? bytes.length;
    if (bytes.length < 12) return null;

    final png = _png(bytes, size);
    if (png != null) return png;
    final gif = _gif(bytes, size);
    if (gif != null) return gif;
    final bmp = _bmp(bytes, size);
    if (bmp != null) return bmp;
    final webp = _webp(bytes, size);
    if (webp != null) return webp;
    return _jpeg(bytes, size);
  }

  /// [bytes] with any leading junk removed, or null if no image is in there.
  ///
  /// Normally returns [bytes] untouched. It exists for tag frames: an ID3
  /// `APIC` with a UTF-16 description comes back from the metadata package
  /// with the tail of that description still glued to the front of the
  /// picture, so a perfectly good JPEG arrives as `...o.v.e.r..` then `FFD8`.
  /// Those bytes are not an image file, and everything downstream -- the
  /// probe, the store, the decoder -- is right to refuse them. Measured on a
  /// real library: 270 of 334 album-less tracks lost their cover this way.
  ///
  /// Only signatures long enough to not appear by accident are searched for,
  /// which rules out BMP: `BM` is two bytes, and a description is text.
  static Uint8List? trimToImage(Uint8List bytes, {int searchWindow = 1024}) {
    if (probeBytes(bytes) != null) return bytes;
    final last = bytes.length - 12;
    final limit = searchWindow < last ? searchWindow : last;
    for (var offset = 1; offset <= limit; offset++) {
      if (!_startsImage(bytes, offset)) continue;
      final candidate = Uint8List.sublistView(bytes, offset);
      if (probeBytes(candidate) != null) return candidate;
    }
    return null;
  }

  static bool _startsImage(Uint8List b, int o) =>
      (b[o] == 0xFF && b[o + 1] == 0xD8 && b[o + 2] == 0xFF) ||
      (b[o] == 0x89 && _ascii(b, o + 1, 'PNG')) ||
      _ascii(b, o, 'GIF8') ||
      (_ascii(b, o, 'RIFF') && _ascii(b, o + 8, 'WEBP'));

  // ------------------------------------------------------------------- PNG

  static ImageInfo? _png(Uint8List b, int size) {
    const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (var i = 0; i < signature.length; i++) {
      if (b[i] != signature[i]) return null;
    }
    // IHDR is always the first chunk: 8 bytes signature, 4 length, 4 type,
    // then width and height as big-endian 32-bit values.
    if (b.length < 24) return null;
    return ImageInfo(
      mimeType: 'image/png',
      width: _uint32BE(b, 16),
      height: _uint32BE(b, 20),
      byteSize: size,
    );
  }

  // ------------------------------------------------------------------- GIF

  static ImageInfo? _gif(Uint8List b, int size) {
    if (!_ascii(b, 0, 'GIF8')) return null;
    return ImageInfo(
      mimeType: 'image/gif',
      width: _uint16LE(b, 6),
      height: _uint16LE(b, 8),
      byteSize: size,
    );
  }

  // ------------------------------------------------------------------- BMP

  static ImageInfo? _bmp(Uint8List b, int size) {
    if (!_ascii(b, 0, 'BM')) return null;
    if (b.length < 26) return null;
    return ImageInfo(
      mimeType: 'image/bmp',
      width: _uint32LE(b, 18),
      // Height is signed; a negative value means a top-down bitmap.
      height: _uint32LE(b, 22).abs(),
      byteSize: size,
    );
  }

  // ------------------------------------------------------------------ WebP

  static ImageInfo? _webp(Uint8List b, int size) {
    if (!_ascii(b, 0, 'RIFF') || !_ascii(b, 8, 'WEBP')) return null;
    if (b.length < 30) return null;
    final format = String.fromCharCodes(b.sublist(12, 16));
    switch (format) {
      case 'VP8 ':
        // Lossy: a 3-byte frame tag, a 3-byte sync code, then 14-bit sizes.
        return ImageInfo(
          mimeType: 'image/webp',
          width: _uint16LE(b, 26) & 0x3FFF,
          height: _uint16LE(b, 28) & 0x3FFF,
          byteSize: size,
        );
      case 'VP8L':
        // Lossless: 14-bit width and height minus one, bit-packed.
        final bits = _uint32LE(b, 21);
        return ImageInfo(
          mimeType: 'image/webp',
          width: (bits & 0x3FFF) + 1,
          height: ((bits >> 14) & 0x3FFF) + 1,
          byteSize: size,
        );
      case 'VP8X':
        // Extended: 24-bit canvas width and height minus one.
        return ImageInfo(
          mimeType: 'image/webp',
          width: (b[24] | (b[25] << 8) | (b[26] << 16)) + 1,
          height: (b[27] | (b[28] << 8) | (b[29] << 16)) + 1,
          byteSize: size,
        );
      default:
        return null;
    }
  }

  // ------------------------------------------------------------------ JPEG

  static ImageInfo? _jpeg(Uint8List b, int size) {
    if (b[0] != 0xFF || b[1] != 0xD8) return null;

    // Walk the segment chain to a Start Of Frame marker, which carries the
    // dimensions. Everything before it is metadata of one kind or another.
    var offset = 2;
    while (offset + 9 < b.length) {
      if (b[offset] != 0xFF) {
        offset++;
        continue;
      }
      final marker = b[offset + 1];
      // Padding and standalone markers carry no length field.
      if (marker == 0xFF) {
        offset++;
        continue;
      }
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
        offset += 2;
        continue;
      }
      final segmentLength = _uint16BE(b, offset + 2);
      // SOF0-SOF15, excluding DHT (C4), JPGA (C8) and DAC (CC).
      final isStartOfFrame = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isStartOfFrame) {
        return ImageInfo(
          mimeType: 'image/jpeg',
          height: _uint16BE(b, offset + 5),
          width: _uint16BE(b, offset + 7),
          byteSize: size,
        );
      }
      if (segmentLength < 2) return null;
      offset += 2 + segmentLength;
    }
    return null;
  }

  // --------------------------------------------------------------- helpers

  static bool _ascii(Uint8List b, int offset, String text) {
    if (offset + text.length > b.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (b[offset + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  static int _uint16BE(Uint8List b, int o) => (b[o] << 8) | b[o + 1];
  static int _uint16LE(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
  static int _uint32BE(Uint8List b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  static int _uint32LE(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  /// Extension normally used for a MIME type, for naming stored files.
  static String extensionForMime(String mimeType) => switch (mimeType) {
        'image/png' => 'png',
        'image/gif' => 'gif',
        'image/bmp' => 'bmp',
        'image/webp' => 'webp',
        _ => 'jpg',
      };
}
