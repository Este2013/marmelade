import 'package:drift/drift.dart';

import '../enums.dart';
import 'catalog.dart';

/// A folder the user registered for indexing.
@TableIndex(name: 'idx_library_folders_enabled', columns: {#enabled})
class LibraryFolders extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Absolute path, normalised and without a trailing separator.
  TextColumn get path => text().unique()();

  /// Optional friendly name shown instead of the raw path.
  TextColumn get displayName => text().nullable()();

  /// Whether this folder participates in scans and its tracks appear.
  ///
  /// Disabling hides a folder's music without discarding play counts,
  /// ratings or edits.
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// Whether to watch the filesystem for live changes.
  BoolColumn get watch => boolean().withDefault(const Constant(true))();

  BoolColumn get recursive => boolean().withDefault(const Constant(true))();

  /// JSON array of glob patterns to skip, relative to this folder.
  TextColumn get excludeGlobs =>
      text().withDefault(const Constant('[]'))();

  DateTimeColumn get addedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  DateTimeColumn get lastScanFinishedAt => dateTime().nullable()();
  IntColumn get lastScanDurationMs => integer().nullable()();

  /// Denormalised counter so the settings list can render without a COUNT(*).
  IntColumn get trackedFileCount => integer().withDefault(const Constant(0))();

  /// Sort order in the settings UI.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// A physical audio file on disk.
///
/// Kept deliberately separate from [Tracks]: one track may exist as several
/// files (an MP3 and a FLAC of the same song), and a file can be moved,
/// renamed or retagged without disturbing the track's identity, ratings or
/// play history.
///
/// Identity is established by content, not by path. Three signals, cheapest
/// first:
///   * [quickKey]     - hash of size + head + tail bytes. Cheap pre-filter.
///   * [contentKey]   - hash of the *audio payload only*, skipping tag blocks,
///                      so re-tagging a file does not change its identity.
///   * [volumeSerial] + [fileIndex] - the NTFS file ID, which survives a
///                      rename or a move within the same volume.
///
/// A file that disappears from one path while an unknown file with a matching
/// [contentKey] appears at another is treated as a move, and the row is
/// quietly repointed.
@TableIndex(name: 'idx_media_files_content_key', columns: {#contentKey})
@TableIndex(name: 'idx_media_files_quick_key', columns: {#quickKey})
@TableIndex(name: 'idx_media_files_track', columns: {#trackId})
@TableIndex(name: 'idx_media_files_status', columns: {#status})
@TableIndex(name: 'idx_media_files_ntfs_id', columns: {#volumeSerial, #fileIndex})
class MediaFiles extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get folderId => integer()
      .references(LibraryFolders, #id, onDelete: KeyAction.cascade)();

  /// Path relative to the owning folder, using forward slashes.
  ///
  /// Storing it relative means re-rooting a whole library (a drive letter
  /// change, a moved collection) is a single update to the folder row.
  TextColumn get relativePath => text()();

  TextColumn get fileName => text()();

  /// Lower-case, without the dot.
  TextColumn get extension => text()();

  IntColumn get sizeBytes => integer()();
  DateTimeColumn get modifiedAt => dateTime()();

  /// Hash of the audio payload, excluding tag blocks. Stable across retagging.
  TextColumn get contentKey => text().nullable()();

  /// Cheap hash of size plus head and tail bytes.
  TextColumn get quickKey => text().nullable()();

  /// Hash of the tag block, so a rescan can tell "tags changed" from
  /// "nothing changed" without a full reparse.
  TextColumn get tagsHash => text().nullable()();

  /// NTFS volume serial number, when obtainable.
  IntColumn get volumeSerial => integer().nullable()();

  /// NTFS file index, as a hex string (it can exceed 64 bits on ReFS).
  TextColumn get fileIndex => text().nullable()();

  // ---- Decoded audio properties ----
  TextColumn get codec => text().nullable()();
  IntColumn get bitrate => integer().nullable()();
  IntColumn get sampleRate => integer().nullable()();
  IntColumn get channels => integer().nullable()();
  IntColumn get bitDepth => integer().nullable()();
  BoolColumn get lossless => boolean().withDefault(const Constant(false))();
  IntColumn get durationMs => integer().nullable()();

  /// ReplayGain track gain in dB, when the file carries it.
  RealColumn get replayGainDb => real().nullable()();
  RealColumn get replayGainPeak => real().nullable()();

  TextColumn get status =>
      textEnum<FileStatus>().withDefault(const Constant('pendingScan'))();

  IntColumn get trackId =>
      integer().nullable().references(Tracks, #id, onDelete: KeyAction.setNull)();

  DateTimeColumn get firstSeenAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get lastSeenAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get lastIndexedAt => dateTime().nullable()();

  /// Populated when [status] is [FileStatus.unreadable].
  TextColumn get errorMessage => text().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {folderId, relativePath},
      ];
}
