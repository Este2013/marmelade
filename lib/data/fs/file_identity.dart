import 'dart:io';
import 'dart:typed_data';

import 'package:xxh3/xxh3.dart';

import 'audio_payload.dart';

/// Content-derived identity of one audio file.
///
/// Three signals, cheapest first. Together they are what make the library
/// survive the filesystem being reorganised behind its back.
class FileIdentity {
  const FileIdentity({
    required this.sizeBytes,
    required this.payloadLength,
    required this.quickKey,
    this.contentKey,
    this.payloadExact = true,
  });

  /// Size of the file on disk.
  final int sizeBytes;

  /// Size of the audio payload, excluding tag blocks.
  final int payloadLength;

  /// Hash of the payload length plus its leading and trailing bytes.
  ///
  /// Cheap - a few hundred kilobytes read regardless of file size - and strong
  /// enough on its own to shortlist candidates. Because it is taken over the
  /// payload rather than the file, editing a title does not change it.
  final String quickKey;

  /// Hash of the entire audio payload. Null until computed.
  ///
  /// Only needed to confirm a match that [quickKey] already made likely, so it
  /// is computed on demand rather than for every file in a scan.
  final String? contentKey;

  /// False when the container was not understood and the hashes therefore
  /// cover the whole file, tags included.
  final bool payloadExact;

  FileIdentity withContentKey(String key) => FileIdentity(
        sizeBytes: sizeBytes,
        payloadLength: payloadLength,
        quickKey: quickKey,
        contentKey: key,
        payloadExact: payloadExact,
      );

  @override
  String toString() => 'FileIdentity(size: $sizeBytes, payload: $payloadLength,'
      ' quick: $quickKey, content: ${contentKey ?? "-"})';
}

/// Computes content hashes over the audio payload of a file.
///
/// Hashing the payload rather than the file is the whole point: a track that
/// gets retagged keeps its identity, so the app updates the row instead of
/// deciding an old file vanished and a new one appeared.
class FileHasher {
  const FileHasher({this.probeBytes = 128 * 1024, this.chunkBytes = 1 << 20});

  /// How many bytes to take from each end of the payload for the quick key.
  final int probeBytes;

  /// Read size when hashing a whole payload.
  final int chunkBytes;

  /// Computes the cheap identity of [file].
  ///
  /// Reads at most `2 * probeBytes`. Throws [FileSystemException] if the file
  /// cannot be read.
  FileIdentity quickIdentify(File file) {
    final range = AudioPayloadLocator.locate(file);
    final handle = file.openSync();
    try {
      final take = range.length < probeBytes ? range.length : probeBytes;
      final state = xxh3Stream();

      // Length first, so two files sharing head and tail but differing in size
      // cannot collide.
      state.update(_lengthBytes(range.length));

      if (take > 0) {
        handle.setPositionSync(range.start);
        state.update(handle.readSync(take));
      }
      // Only read a distinct tail; a short payload is already fully covered.
      if (range.length > probeBytes) {
        final tailStart = range.end - take;
        handle.setPositionSync(tailStart);
        state.update(handle.readSync(take));
      }

      return FileIdentity(
        sizeBytes: range.fileLength,
        payloadLength: range.length,
        quickKey: state.digestString(),
        payloadExact: range.exact,
      );
    } finally {
      handle.closeSync();
    }
  }

  /// Hashes the entire audio payload of [file].
  ///
  /// Linear in file size, so reserve it for confirming a suspected move.
  String contentKey(File file) {
    final range = AudioPayloadLocator.locate(file);
    final handle = file.openSync();
    try {
      final state = xxh3Stream();
      state.update(_lengthBytes(range.length));
      handle.setPositionSync(range.start);

      var remaining = range.length;
      while (remaining > 0) {
        final want = remaining < chunkBytes ? remaining : chunkBytes;
        final chunk = handle.readSync(want);
        if (chunk.isEmpty) break;
        state.update(chunk);
        remaining -= chunk.length;
      }
      return state.digestString();
    } finally {
      handle.closeSync();
    }
  }

  /// Full identity, including the expensive [FileIdentity.contentKey].
  FileIdentity fullyIdentify(File file) =>
      quickIdentify(file).withContentKey(contentKey(file));

  static Uint8List _lengthBytes(int length) {
    final bytes = Uint8List(8);
    ByteData.view(bytes.buffer).setUint64(0, length, Endian.little);
    return bytes;
  }
}
