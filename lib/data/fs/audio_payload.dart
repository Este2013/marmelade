import 'dart:io';
import 'dart:typed_data';

/// The byte range of an audio file that holds actual audio, excluding tags.
///
/// Knowing this range is what lets a file keep its identity through a
/// re-tagging. Editing a title rewrites the tag block and shifts every
/// subsequent byte, so any hash over the whole file changes; a hash over this
/// range does not.
class AudioPayloadRange {
  const AudioPayloadRange({
    required this.start,
    required this.length,
    required this.fileLength,
    this.exact = true,
  });

  /// Offset of the first audio byte.
  final int start;

  /// Number of audio bytes.
  final int length;

  /// Total size of the file on disk.
  final int fileLength;

  /// Whether the container was understood.
  ///
  /// False means the range is a fallback covering the whole file, so hashes
  /// over it are still stable for move detection but are not tag-invariant.
  final bool exact;

  int get end => start + length;

  /// A range covering an entire file, used when the container is unknown.
  factory AudioPayloadRange.wholeFile(int fileLength) => AudioPayloadRange(
        start: 0,
        length: fileLength,
        fileLength: fileLength,
        exact: false,
      );

  @override
  String toString() => 'AudioPayloadRange($start..$end of $fileLength'
      '${exact ? "" : ", inexact"})';
}

/// Locates the audio payload inside MP3, FLAC and WAV containers.
///
/// Reads only headers - a few kilobytes - never the whole file.
abstract final class AudioPayloadLocator {
  /// How much of the head and tail to read while looking for tag blocks.
  static const _probeSize = 64 * 1024;

  /// Finds the payload range of [file].
  ///
  /// Never throws: an unreadable or unrecognised file yields
  /// [AudioPayloadRange.wholeFile], which still works for move detection.
  static AudioPayloadRange locate(File file) {
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      final fileLength = handle.lengthSync();
      if (fileLength == 0) {
        return AudioPayloadRange.wholeFile(0);
      }

      final headLength = fileLength < _probeSize ? fileLength : _probeSize;
      final head = handle.readSync(headLength);

      if (_startsWith(head, 'fLaC')) {
        return _locateFlac(handle, head, fileLength);
      }
      if (_startsWith(head, 'RIFF') && _matchesAt(head, 8, 'WAVE')) {
        return _locateWav(handle, fileLength);
      }
      // MP3 either opens with an ID3v2 tag or straight into a frame sync.
      return _locateMp3(handle, head, fileLength);
    } catch (_) {
      return AudioPayloadRange.wholeFile(_safeLength(file));
    } finally {
      handle?.closeSync();
    }
  }

  // ------------------------------------------------------------------- MP3

  static AudioPayloadRange _locateMp3(
    RandomAccessFile handle,
    Uint8List head,
    int fileLength,
  ) {
    var start = 0;

    if (_startsWith(head, 'ID3') && head.length >= 10) {
      // ID3v2 size is four sync-safe bytes: seven significant bits each.
      final size = (head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9];
      final hasFooter = (head[5] & 0x10) != 0;
      start = 10 + size + (hasFooter ? 10 : 0);
    }

    var end = fileLength;

    // Trailing tags, innermost last: ID3v1 is always the final 128 bytes when
    // present, and APEv2 sits before it.
    final tailLength = fileLength < _probeSize ? fileLength : _probeSize;
    handle.setPositionSync(fileLength - tailLength);
    final tail = handle.readSync(tailLength);

    if (tailLength >= 128 && _matchesAt(tail, tailLength - 128, 'TAG')) {
      end -= 128;
    }

    // APEv2 footer: "APETAGEX", then a 4-byte version and a 4-byte size that
    // covers the tag body plus the footer itself.
    final apeFooterAt = _lastIndexOf(tail, 'APETAGEX', before: tailLength);
    if (apeFooterAt >= 0 && apeFooterAt + 16 <= tailLength) {
      final size = _readUint32LE(tail, apeFooterAt + 12);
      final absoluteFooter = fileLength - tailLength + apeFooterAt;
      // A header precedes the body when the flags say so; assume the common
      // footer-only layout and treat the footer position as the boundary.
      if (size > 0 && size < fileLength && absoluteFooter < end) {
        end = absoluteFooter;
      }
    }

    // Lyrics3v2 ends with a 6-digit size and the tag "LYRICS200".
    final lyrics3At = _lastIndexOf(tail, 'LYRICS200', before: tailLength);
    if (lyrics3At >= 0) {
      final absolute = fileLength - tailLength + lyrics3At;
      if (absolute < end) end = absolute;
    }

    if (start >= end) return AudioPayloadRange.wholeFile(fileLength);

    // Confirm there really is MPEG audio here before promising a tag-invariant
    // range. Without this check any 2 KB of noise would be reported as an
    // exact payload, and the caller would trust a hash that guarantees
    // nothing. Some files also carry junk between the tag and the first frame,
    // so the sync search doubles as a way to skip it.
    final syncAt = _findFrameSync(handle, head, start, end);
    if (syncAt == null) return AudioPayloadRange.wholeFile(fileLength);

    return AudioPayloadRange(
      start: syncAt,
      length: end - syncAt,
      fileLength: fileLength,
    );
  }

  /// Finds the first MPEG frame sync at or after [from], within a window.
  ///
  /// A sync is eleven set bits: 0xFF followed by a byte whose top three bits
  /// are set.
  static int? _findFrameSync(
    RandomAccessFile handle,
    Uint8List head,
    int from,
    int end,
  ) {
    const window = 16 * 1024;
    final limit = (from + window) < end ? from + window : end;
    if (from >= limit) return null;

    final bytes = _byteAt(handle, head, from, limit - from);
    if (bytes == null || bytes.length < 2) return null;

    for (var i = 0; i < bytes.length - 1; i++) {
      if (bytes[i] == 0xFF && (bytes[i + 1] & 0xE0) == 0xE0) {
        return from + i;
      }
    }
    return null;
  }

  // ------------------------------------------------------------------ FLAC

  static AudioPayloadRange _locateFlac(
    RandomAccessFile handle,
    Uint8List head,
    int fileLength,
  ) {
    // "fLaC" then a chain of metadata blocks: one byte carrying the
    // last-block flag and type, then a 24-bit big-endian length.
    var offset = 4;
    var guard = 0;
    while (offset + 4 <= fileLength && guard++ < 1024) {
      final header = _byteAt(handle, head, offset, 4);
      if (header == null) break;
      final isLast = (header[0] & 0x80) != 0;
      final blockLength = (header[1] << 16) | (header[2] << 8) | header[3];
      offset += 4 + blockLength;
      if (isLast) break;
    }
    if (offset <= 4 || offset >= fileLength) {
      return AudioPayloadRange.wholeFile(fileLength);
    }
    return AudioPayloadRange(
      start: offset,
      length: fileLength - offset,
      fileLength: fileLength,
    );
  }

  // ------------------------------------------------------------------- WAV

  static AudioPayloadRange _locateWav(
    RandomAccessFile handle,
    int fileLength,
  ) {
    // Walk the RIFF chunk list looking for "data". Tag chunks (LIST/INFO, id3)
    // may sit either side of it.
    var offset = 12;
    var guard = 0;
    while (offset + 8 <= fileLength && guard++ < 1024) {
      handle.setPositionSync(offset);
      final header = handle.readSync(8);
      if (header.length < 8) break;
      final id = String.fromCharCodes(header.sublist(0, 4));
      var size = _readUint32LE(header, 4);
      if (id == 'data') {
        // A truncated file can claim more data than it holds.
        final available = fileLength - (offset + 8);
        if (size > available) size = available;
        return AudioPayloadRange(
          start: offset + 8,
          length: size,
          fileLength: fileLength,
        );
      }
      // Chunks are word-aligned, so an odd size is followed by a pad byte.
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    return AudioPayloadRange.wholeFile(fileLength);
  }

  // --------------------------------------------------------------- helpers

  /// Reads [length] bytes at [offset], preferring the already-loaded [head].
  static Uint8List? _byteAt(
    RandomAccessFile handle,
    Uint8List head,
    int offset,
    int length,
  ) {
    if (offset + length <= head.length) {
      return Uint8List.sublistView(head, offset, offset + length);
    }
    try {
      handle.setPositionSync(offset);
      final bytes = handle.readSync(length);
      return bytes.length < length ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  static bool _startsWith(Uint8List bytes, String ascii) =>
      _matchesAt(bytes, 0, ascii);

  static bool _matchesAt(Uint8List bytes, int offset, String ascii) {
    if (offset < 0 || offset + ascii.length > bytes.length) return false;
    for (var i = 0; i < ascii.length; i++) {
      if (bytes[offset + i] != ascii.codeUnitAt(i)) return false;
    }
    return true;
  }

  static int _lastIndexOf(Uint8List bytes, String ascii, {required int before}) {
    for (var i = before - ascii.length; i >= 0; i--) {
      if (_matchesAt(bytes, i, ascii)) return i;
    }
    return -1;
  }

  static int _readUint32LE(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return 0;
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }

  static int _safeLength(File file) {
    try {
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }
}
