import '../db/enums.dart';
import 'file_identity.dart';
import 'library_scanner.dart';

/// A file the library already has a row for, reduced to what reconciliation
/// needs to know.
class KnownFile {
  const KnownFile({
    required this.id,
    required this.relativePath,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.status,
    this.fileName,
    this.quickKey,
    this.contentKey,
  });

  final int id;
  final String relativePath;
  final int sizeBytes;
  final DateTime modifiedAt;
  final FileStatus status;

  final String? fileName;

  /// Tag-invariant cheap hash recorded when the file was last indexed.
  ///
  /// This is what makes move detection possible at all: once a file is gone
  /// from disk it cannot be re-hashed, so its identity has to already be in
  /// the database.
  final String? quickKey;

  final String? contentKey;

  @override
  String toString() => 'KnownFile($id, $relativePath, $status)';
}

/// Something reconciliation decided to do about one file.
sealed class FileOperation {
  const FileOperation();
}

/// The file is exactly as last seen. Nothing to do but touch `lastSeenAt`.
class KeepFile extends FileOperation {
  const KeepFile(this.id);
  final int id;
}

/// Same path, changed content or timestamp. Re-read and update in place.
class UpdateFile extends FileOperation {
  const UpdateFile({
    required this.id,
    required this.scanned,
    required this.identity,
    this.wasMissing = false,
  });

  final int id;
  final ScannedFile scanned;
  final FileIdentity identity;

  /// True when a file the library had given up on came back - a reconnected
  /// drive, a restored backup.
  final bool wasMissing;
}

/// The same content turned up at a new path. Repoint the existing row.
///
/// This is the quiet-update case: no track is created, no play count is lost,
/// no artwork is re-imported. The library simply notices the file moved.
class MoveFile extends FileOperation {
  const MoveFile({
    required this.id,
    required this.fromPath,
    required this.scanned,
    required this.identity,
    required this.confirmedByContentKey,
  });

  final int id;
  final String fromPath;
  final ScannedFile scanned;
  final FileIdentity identity;

  /// Whether the full payload hash was compared, not just the cheap key.
  final bool confirmedByContentKey;

  String get toPath => scanned.relativePath;
}

/// Genuinely new. Parse it and create rows.
class AddFile extends FileOperation {
  const AddFile({required this.scanned, required this.identity});
  final ScannedFile scanned;
  final FileIdentity identity;
}

/// Recorded but no longer on disk.
///
/// Marked missing rather than deleted, so ratings, play counts, tags and
/// hand-made edits survive an unplugged drive.
class MarkMissing extends FileOperation {
  const MarkMissing(this.id, this.relativePath);
  final int id;
  final String relativePath;
}

/// The full set of operations for one folder.
class ReconciliationPlan {
  ReconciliationPlan({
    required this.keep,
    required this.update,
    required this.moves,
    required this.adds,
    required this.missing,
    required this.hashedFiles,
  });

  final List<KeepFile> keep;
  final List<UpdateFile> update;
  final List<MoveFile> moves;
  final List<AddFile> adds;
  final List<MarkMissing> missing;

  /// How many files had to be hashed to produce this plan, for the debug view.
  final int hashedFiles;

  /// Everything, in the order it should be applied.
  ///
  /// Moves precede adds so a moved row is repointed before anything could
  /// claim its new path.
  List<FileOperation> get all => [...moves, ...update, ...adds, ...missing, ...keep];

  bool get isEmpty =>
      update.isEmpty && moves.isEmpty && adds.isEmpty && missing.isEmpty;

  int get changeCount =>
      update.length + moves.length + adds.length + missing.length;

  @override
  String toString() => 'ReconciliationPlan(keep: ${keep.length}, '
      'update: ${update.length}, moves: ${moves.length}, '
      'adds: ${adds.length}, missing: ${missing.length})';
}

/// Works out what changed between the database and the disk.
///
/// The interesting part is move detection. A file that disappears from one
/// path while unfamiliar content appears at another is, in the overwhelming
/// majority of cases, the same file: the user reorganised their folders. Naive
/// indexers treat that as a delete plus an insert and throw away everything
/// the user had accumulated about the track.
///
/// Identity comes from a tag-invariant hash of the audio payload, so a file
/// that was moved *and* retagged in the same breath is still recognised.
class FileReconciler {
  FileReconciler({
    FileHasher? hasher,
    this.confirmMovesWithContentKey = true,
  }) : _hasher = hasher ?? const FileHasher();

  final FileHasher _hasher;

  /// Whether to compare full payload hashes before accepting a move.
  ///
  /// The cheap key is already strong, but a move is a destructive-feeling
  /// operation if it is wrong, so the default is to confirm. Only ever costs a
  /// full read for files that are already believed to match.
  final bool confirmMovesWithContentKey;

  /// Builds a plan for one folder.
  ///
  /// [identify] is injectable so the logic can be tested without real files.
  ReconciliationPlan reconcile({
    required List<ScannedFile> scanned,
    required List<KnownFile> known,
    FileIdentity Function(ScannedFile)? identify,
  }) {
    final identifier = identify ?? ((f) => _hasher.quickIdentify(f.file));
    var hashed = 0;

    final knownByPath = {for (final k in known) k.relativePath: k};
    final seenIds = <int>{};

    final keep = <KeepFile>[];
    final update = <UpdateFile>[];
    final adds = <AddFile>[];
    final pendingNew = <ScannedFile>[];

    for (final file in scanned) {
      final existing = knownByPath[file.relativePath];
      if (existing == null) {
        pendingNew.add(file);
        continue;
      }
      seenIds.add(existing.id);

      final unchanged = existing.sizeBytes == file.sizeBytes &&
          !existing.modifiedAt.isBefore(file.modifiedAt) &&
          !existing.modifiedAt.isAfter(file.modifiedAt);

      if (unchanged && existing.status == FileStatus.present) {
        keep.add(KeepFile(existing.id));
        continue;
      }

      hashed++;
      update.add(UpdateFile(
        id: existing.id,
        scanned: file,
        identity: identifier(file),
        wasMissing: existing.status == FileStatus.missing,
      ));
    }

    // Rows whose path no longer exists. Candidates for having moved.
    final vanished = [
      for (final k in known)
        if (!seenIds.contains(k.id) && k.status != FileStatus.missing) k,
    ];

    // Index vanished rows by their recorded cheap key.
    final vanishedByQuickKey = <String, List<KnownFile>>{};
    for (final k in vanished) {
      final key = k.quickKey;
      if (key == null) continue;
      (vanishedByQuickKey[key] ??= []).add(k);
    }

    final claimed = <int>{};
    final moves = <MoveFile>[];

    for (final file in pendingNew) {
      final identity = identifier(file);
      hashed++;

      final candidates = (vanishedByQuickKey[identity.quickKey] ?? const [])
          .where((k) => !claimed.contains(k.id))
          .toList();

      if (candidates.isEmpty) {
        adds.add(AddFile(scanned: file, identity: identity));
        continue;
      }

      final match = _pickBestCandidate(candidates, file);
      var confirmed = false;

      if (confirmMovesWithContentKey && match.contentKey != null) {
        // The vanished row recorded a full hash, so it can be checked. If it
        // disagrees, the cheap keys collided and this is not the same file.
        String? actual;
        try {
          actual = _hasher.contentKey(file.file);
        } catch (_) {
          actual = null;
        }
        if (actual != null && actual != match.contentKey) {
          adds.add(AddFile(scanned: file, identity: identity));
          continue;
        }
        confirmed = actual != null;
      }

      claimed.add(match.id);
      moves.add(MoveFile(
        id: match.id,
        fromPath: match.relativePath,
        scanned: file,
        identity: identity,
        confirmedByContentKey: confirmed,
      ));
    }

    final missing = [
      for (final k in vanished)
        if (!claimed.contains(k.id)) MarkMissing(k.id, k.relativePath),
    ];

    return ReconciliationPlan(
      keep: keep,
      update: update,
      moves: moves,
      adds: adds,
      missing: missing,
      hashedFiles: hashed,
    );
  }

  /// Chooses which vanished row a new file most likely came from.
  ///
  /// Only reached when several vanished files share a payload hash, which
  /// means the library held duplicates. Filename is the strongest remaining
  /// hint - a move usually keeps the name - then exact size.
  static KnownFile _pickBestCandidate(
    List<KnownFile> candidates,
    ScannedFile file,
  ) {
    if (candidates.length == 1) return candidates.single;

    final sameName = candidates.where((k) =>
        (k.fileName ?? _basename(k.relativePath)).toLowerCase() ==
        file.fileName.toLowerCase());
    if (sameName.length == 1) return sameName.single;

    final pool = sameName.isEmpty ? candidates : sameName.toList();
    final sameSize = pool.where((k) => k.sizeBytes == file.sizeBytes);
    if (sameSize.isNotEmpty) return sameSize.first;
    return pool.first;
  }

  static String _basename(String relativePath) {
    final index = relativePath.lastIndexOf('/');
    return index < 0 ? relativePath : relativePath.substring(index + 1);
  }
}
