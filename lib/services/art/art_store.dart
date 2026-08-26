import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../data/fs/image_probe.dart';

/// A stored image, ready to be recorded in the database.
class StoredImage {
  const StoredImage({
    required this.sha256,
    required this.storedPath,
    required this.mimeType,
    required this.byteSize,
    required this.width,
    required this.height,
    required this.wasAlreadyStored,
  });

  /// Lower-case hex digest. The store's identity for this image.
  final String sha256;

  /// Path relative to the store root, as recorded in the database.
  final String storedPath;

  final String mimeType;
  final int byteSize;
  final int? width;
  final int? height;

  /// True when an identical image was already on disk and nothing was written.
  final bool wasAlreadyStored;

  @override
  String toString() => 'StoredImage($sha256, ${width}x$height, $mimeType)';
}

/// A content-addressed store for artwork.
///
/// Files live at `<root>/<first two hex chars>/<digest>.<ext>`. Naming by
/// content digest means the same cover embedded in fifty tracks is written
/// once, an album and its tracks can share one row, and re-importing a library
/// is idempotent. The two-character prefix keeps directory sizes sane on
/// filesystems that dislike a hundred thousand entries in one folder.
///
/// Nothing here mutates the database; callers record the returned
/// [StoredImage] themselves.
class ArtStore {
  ArtStore(this.root);

  /// Root directory of the store.
  final Directory root;

  /// Opens a store rooted at [root], creating it if needed.
  ///
  /// The location is supplied by the caller so this layer stays free of
  /// `path_provider`, and therefore of Flutter. See `app/storage_paths.dart`.
  static Future<ArtStore> open(Directory root) async {
    await root.create(recursive: true);
    return ArtStore(root);
  }

  /// Stores [bytes], or recognises them as already stored.
  ///
  /// Returns null when the bytes are not a recognisable image, which is common
  /// enough in the wild that it is not treated as an error.
  Future<StoredImage?> putBytes(Uint8List bytes) async {
    if (bytes.isEmpty) return null;
    final info = ImageProbe.probeBytes(bytes);
    if (info == null) return null;

    final digest = sha256.convert(bytes).toString();
    final relative = _relativePathFor(digest, info.mimeType);
    final target = File(p.join(root.path, relative));

    if (await target.exists()) {
      final existingLength = await target.length();
      if (existingLength == bytes.length) {
        return StoredImage(
          sha256: digest,
          storedPath: relative,
          mimeType: info.mimeType,
          byteSize: bytes.length,
          width: info.width,
          height: info.height,
          wasAlreadyStored: true,
        );
      }
      // Same digest, different length: a truncated earlier write. Replace it.
    }

    await target.parent.create(recursive: true);
    // Write to a temporary name and rename, so a crash mid-write cannot leave
    // a corrupt file sitting at a content-addressed path where its name is a
    // promise about its contents.
    final temp = File('${target.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);

    return StoredImage(
      sha256: digest,
      storedPath: relative,
      mimeType: info.mimeType,
      byteSize: bytes.length,
      width: info.width,
      height: info.height,
      wasAlreadyStored: false,
    );
  }

  /// Copies an image file into the store.
  Future<StoredImage?> putFile(File file) async {
    try {
      return await putBytes(await file.readAsBytes());
    } on FileSystemException {
      return null;
    }
  }

  /// Absolute path of a stored image, from the relative path in the database.
  File fileFor(String storedPath) => File(p.join(root.path, storedPath));

  /// Whether the bytes for [storedPath] are still present.
  Future<bool> exists(String storedPath) => fileFor(storedPath).exists();

  /// Deletes a stored image.
  ///
  /// Only safe once nothing references it; the caller owns that decision.
  Future<void> delete(String storedPath) async {
    final file = fileFor(storedPath);
    if (await file.exists()) await file.delete();
  }

  /// Total bytes held by the store, for the settings screen.
  Future<int> totalBytes() async {
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // A file removed mid-walk is not worth failing over.
        }
      }
    }
    return total;
  }

  /// Removes stored images whose digests are not in [referenced].
  ///
  /// Returns how many files were deleted. Exposed as a maintenance action
  /// rather than run automatically, because an orphan costs only disk space
  /// while a wrong deletion costs artwork.
  Future<int> pruneUnreferenced(Set<String> referenced) async {
    if (!await root.exists()) return 0;
    var deleted = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final stem = p.basenameWithoutExtension(entity.path);
      if (stem.endsWith('.tmp')) {
        await entity.delete();
        deleted++;
        continue;
      }
      if (!referenced.contains(stem)) {
        await entity.delete();
        deleted++;
      }
    }
    return deleted;
  }

  static String _relativePathFor(String digest, String mimeType) {
    final extension = ImageProbe.extensionForMime(mimeType);
    return p.join(digest.substring(0, 2), '$digest.$extension');
  }
}
