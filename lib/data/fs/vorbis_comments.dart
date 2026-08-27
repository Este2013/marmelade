import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The raw contents of a Vorbis comment block.
///
/// Keys are upper-cased; values keep their original order, and repeats are
/// preserved. That last part is the whole point - see [FlacVorbisReader].
class VorbisCommentBlock {
  VorbisCommentBlock(this.fields);

  /// Upper-cased field name to every value it appeared with.
  final Map<String, List<String>> fields;

  /// Every value of [key], or an empty list.
  List<String> values(String key) => fields[key.toUpperCase()] ?? const [];

  /// The first value of the first present key among [keys].
  String? first(List<String> keys) {
    for (final key in keys) {
      final found = values(key);
      if (found.isNotEmpty) return found.first;
    }
    return null;
  }

  /// Every value of the first present key among [keys].
  List<String> all(List<String> keys) {
    for (final key in keys) {
      final found = values(key);
      if (found.isNotEmpty) return found;
    }
    return const [];
  }

  bool get isEmpty => fields.isEmpty;

  @override
  String toString() => 'VorbisCommentBlock(${fields.length} fields)';
}

/// Stream properties from a FLAC STREAMINFO block.
class FlacStreamInfo {
  const FlacStreamInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.totalSamples,
    required this.fileLength,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// Total interchannel samples, or zero when the encoder did not record it.
  final int totalSamples;

  final int fileLength;

  Duration? get duration => (sampleRate > 0 && totalSamples > 0)
      ? Duration(
          microseconds:
              (totalSamples * Duration.microsecondsPerSecond / sampleRate)
                  .round(),
        )
      : null;

  /// Average bitrate in bits per second.
  int? get bitrate {
    final seconds = duration?.inMicroseconds;
    if (seconds == null || seconds == 0) return null;
    return (fileLength * 8 * Duration.microsecondsPerSecond / seconds).round();
  }

  @override
  String toString() => 'FlacStreamInfo(${sampleRate}Hz, ${channels}ch, '
      '${bitsPerSample}bit, $totalSamples samples)';
}

/// Reads the Vorbis comment block out of a FLAC file.
///
/// This exists because `audio_metadata_reader` maps both `ARTIST` and
/// `ALBUMARTIST` into a single list. That has two consequences the credits
/// model cannot live with: the album artist becomes indistinguishable from a
/// track artist, and a file with one artist plus an album artist looks exactly
/// like a file that genuinely lists two artists.
///
/// Multi-value `ARTIST` is the most reliable multi-artist signal a file can
/// carry - it is the file stating the answer outright, with no heuristics
/// needed - so it is worth parsing correctly rather than inferring around.
///
/// Only the text fields are read here. Stream properties and pictures still
/// come from the package's parser, which handles them well.
abstract final class FlacVorbisReader {
  /// FLAC metadata block type for a Vorbis comment.
  static const _vorbisCommentBlockType = 4;

  /// Refuse absurd blocks rather than allocating whatever a corrupt header
  /// claims.
  static const _maxBlockBytes = 16 * 1024 * 1024;

  /// Reads [file], or returns null if it is not FLAC or has no comment block.
  static VorbisCommentBlock? read(File file) {
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      final magic = handle.readSync(4);
      if (magic.length < 4 ||
          magic[0] != 0x66 || // f
          magic[1] != 0x4C || // L
          magic[2] != 0x61 || // a
          magic[3] != 0x43) {
        return null;
      }

      // Metadata blocks: one byte of last-block flag plus type, then a 24-bit
      // big-endian length.
      var guard = 0;
      while (guard++ < 1024) {
        final header = handle.readSync(4);
        if (header.length < 4) return null;
        final isLast = (header[0] & 0x80) != 0;
        final type = header[0] & 0x7F;
        final length = (header[1] << 16) | (header[2] << 8) | header[3];

        if (type == _vorbisCommentBlockType) {
          if (length <= 0 || length > _maxBlockBytes) return null;
          final body = handle.readSync(length);
          if (body.length < length) return null;
          return _parse(body);
        }

        if (isLast) return null;
        handle.setPositionSync(handle.positionSync() + length);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      handle?.closeSync();
    }
  }

  /// Reads the STREAMINFO block of a FLAC file.
  ///
  /// Needed because the app cannot rely on the metadata package for a file the
  /// package refuses to parse, and a track with no duration is a track the UI
  /// cannot lay out properly.
  static FlacStreamInfo? readStreamInfo(File file) {
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      final fileLength = handle.lengthSync();
      final magic = handle.readSync(4);
      if (magic.length < 4 ||
          magic[0] != 0x66 ||
          magic[1] != 0x4C ||
          magic[2] != 0x61 ||
          magic[3] != 0x43) {
        return null;
      }
      // STREAMINFO is required to be the first metadata block.
      final header = handle.readSync(4);
      if (header.length < 4 || (header[0] & 0x7F) != 0) return null;
      final body = handle.readSync(34);
      if (body.length < 34) return null;

      // Bit-packed after the frame sizes: 20 bits sample rate, 3 bits
      // channels-1, 5 bits bits-per-sample-1, 36 bits total samples.
      final sampleRate = (body[10] << 12) | (body[11] << 4) | (body[12] >> 4);
      final channels = ((body[12] >> 1) & 0x07) + 1;
      final bitsPerSample =
          (((body[12] & 0x01) << 4) | (body[13] >> 4)) + 1;
      final totalSamples = ((body[13] & 0x0F) << 32) |
          (body[14] << 24) |
          (body[15] << 16) |
          (body[16] << 8) |
          body[17];

      return FlacStreamInfo(
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
        totalSamples: totalSamples,
        fileLength: fileLength,
      );
    } catch (_) {
      return null;
    } finally {
      handle?.closeSync();
    }
  }

  /// Parses a comment block body.
  ///
  /// Layout, all lengths little-endian 32-bit: vendor length, vendor string,
  /// comment count, then that many length-prefixed `KEY=value` strings.
  static VorbisCommentBlock? _parse(Uint8List body) {
    final view = ByteData.view(body.buffer, body.offsetInBytes, body.length);
    var offset = 0;

    if (body.length < 8) return null;
    final vendorLength = view.getUint32(offset, Endian.little);
    offset += 4;
    if (vendorLength < 0 || offset + vendorLength + 4 > body.length) return null;
    offset += vendorLength;

    final count = view.getUint32(offset, Endian.little);
    offset += 4;
    if (count > 100000) return null;

    final fields = <String, List<String>>{};
    for (var i = 0; i < count; i++) {
      if (offset + 4 > body.length) break;
      final length = view.getUint32(offset, Endian.little);
      offset += 4;
      if (length < 0 || offset + length > body.length) break;

      final raw = body.sublist(offset, offset + length);
      offset += length;

      // Comments are UTF-8 by specification, but real files are not always
      // well-formed; a malformed comment should not lose the whole block.
      final String text;
      try {
        text = utf8.decode(raw);
      } on FormatException {
        continue;
      }

      final separator = text.indexOf('=');
      if (separator <= 0) continue;
      final key = text.substring(0, separator).toUpperCase().trim();
      final value = text.substring(separator + 1);
      if (key.isEmpty || value.trim().isEmpty) continue;
      (fields[key] ??= []).add(value);
    }

    return fields.isEmpty ? null : VorbisCommentBlock(fields);
  }
}
