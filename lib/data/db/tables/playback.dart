import 'package:drift/drift.dart';

import '../enums.dart';
import 'catalog.dart';

/// The play queue, persisted so it survives a restart.
///
/// [position] is a sparse integer: gaps are left between entries so inserting
/// "play next" is a single row write instead of renumbering the tail.
@TableIndex(name: 'idx_queue_position', columns: {#position})
class QueueItems extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();

  /// Sparse ordering key.
  IntColumn get position => integer()();

  TextColumn get source =>
      textEnum<QueueSource>().withDefault(const Constant('user'))();

  /// Id of whatever the track came from - an album, playlist, artist or tag -
  /// so the UI can show "from `<album>`" and jump back to it.
  IntColumn get sourceRefId => integer().nullable()();

  /// Ordering before the last shuffle, so a shuffle can be undone.
  IntColumn get unshuffledPosition => integer().nullable()();

  DateTimeColumn get addedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  /// Set when the entry has been played through, so history-aware repeat modes
  /// can tell "already heard" from "not yet reached".
  DateTimeColumn get playedAt => dateTime().nullable()();
}

/// One listening event. The raw log behind play counts and statistics.
///
/// Kept separate from the counters on [Tracks] so statistics can be
/// recomputed, and so "most played this month" is answerable.
@TableIndex(name: 'idx_history_track', columns: {#trackId})
@TableIndex(name: 'idx_history_started', columns: {#startedAt})
class PlayHistory extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();

  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime().nullable()();

  /// Milliseconds actually heard, which is not the same as the track's length
  /// once seeking and skipping are involved.
  IntColumn get msPlayed => integer().withDefault(const Constant(0))();

  /// Whether enough was heard to count as a play rather than a skip. The
  /// threshold is a setting.
  BoolColumn get completed => boolean().withDefault(const Constant(false))();

  TextColumn get source =>
      textEnum<QueueSource>().withDefault(const Constant('user'))();
}

/// A lyrics document for a track.
///
/// Lyrics may live inline in [content] or in an external markdown file
/// referenced by [filePath] - the latter being the "link a markdown file"
/// workflow, where the file stays the source of truth and can be edited in any
/// editor.
///
/// Several rows per track are allowed, one per [language], so translations sit
/// alongside the original.
@TableIndex(name: 'idx_lyrics_track', columns: {#trackId})
class Lyrics extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();

  TextColumn get format =>
      textEnum<LyricsFormat>().withDefault(const Constant('markdown'))();

  /// Absolute path to an external lyrics file, when linked rather than inline.
  TextColumn get filePath => text().nullable()();

  /// Inline lyrics text. Also used as a cache of [filePath] contents so the
  /// viewer can render before the file is read.
  TextColumn get content => text().nullable()();

  /// True when the document carries `[mm:ss.cc]` timestamps and can scroll in
  /// time with playback.
  BoolColumn get isSynced => boolean().withDefault(const Constant(false))();

  /// BCP-47 language tag. Null means "the original", whatever that is.
  TextColumn get language => text().nullable()();

  /// Global timing offset in milliseconds, for lyrics that run early or late.
  IntColumn get offsetMs => integer().withDefault(const Constant(0))();

  TextColumn get source =>
      textEnum<DataSource>().withDefault(const Constant('user'))();

  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  List<Set<Column>> get uniqueKeys => [
        {trackId, language},
      ];
}
