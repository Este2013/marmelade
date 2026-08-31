import 'package:drift/drift.dart';

import '../enums.dart';
import 'catalog.dart';
import 'images.dart';

/// A playlist, a smart playlist, or a folder of playlists.
///
/// [PlaylistKind.smart] playlists store a query in [query] rather than a list
/// of tracks, so they re-evaluate whenever the library changes: add a track
/// that matches and it appears, delete one and it leaves. [PlaylistKind.hybrid]
/// combines a query with manual additions and exclusions.
///
/// Playlists nest through [parentId], which is what makes collections of
/// playlists possible.
@TableIndex(name: 'idx_playlists_parent', columns: {#parentId})
class Playlists extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get name => text()();

  /// Normalised [name], for matching.
  TextColumn get nameKey => text()();

  TextColumn get description => text().nullable()();

  IntColumn get imageId => integer()
      .nullable()
      .references(Images, #id, onDelete: KeyAction.setNull)();

  TextColumn get kind =>
      textEnum<PlaylistKind>().withDefault(const Constant('manual'))();

  /// Parent playlist, for nesting. Null means top level.
  IntColumn get parentId => integer()
      .nullable()
      .references(Playlists, #id, onDelete: KeyAction.cascade)();

  /// The search expression, for smart and hybrid playlists.
  ///
  /// Stored as the user typed it, in the app's search grammar
  /// (`artist:Nanahira tag:hardcore -tag:remix added:<30d`), so it stays
  /// editable and legible rather than becoming an opaque blob.
  TextColumn get query => text().nullable()();

  /// Cap on the number of tracks a smart query yields. Null means unlimited.
  IntColumn get queryLimit => integer().nullable()();

  /// Sort key applied to smart results, e.g. `added:desc`, `random`.
  TextColumn get querySort => text().nullable()();

  /// Whether the smart query re-runs automatically as the library changes.
  BoolColumn get autoUpdate => boolean().withDefault(const Constant(true))();

  /// How the tracks are ordered on screen, as a [PlaylistSort] name.
  ///
  /// Separate from [querySort], which orders what a smart query *finds*. This
  /// one orders what is shown, and applies to manual playlists too -- so a
  /// playlist can be kept in the order things were added while still being
  /// read album by album.
  TextColumn get displaySort =>
      textEnum<PlaylistSort>().withDefault(const Constant('added'))();

  /// Whether [displaySort] runs backwards.
  BoolColumn get sortDescending =>
      boolean().withDefault(const Constant(false))();

  /// What the tracks are grouped under, as a [PlaylistGrouping] name.
  TextColumn get groupBy =>
      textEnum<PlaylistGrouping>().withDefault(const Constant('none'))();

  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
}

/// An entry in a playlist: either a track, or another playlist included
/// wholesale.
///
/// Exactly one of [trackId] and [childPlaylistId] is set; the check constraint
/// enforces it. Including a playlist inside another keeps the child live -
/// changes to it show through - rather than copying its tracks.
@TableIndex(name: 'idx_playlist_items_playlist', columns: {#playlistId, #position})
@TableIndex(name: 'idx_playlist_items_track', columns: {#trackId})
class PlaylistItems extends Table {
  IntColumn get id => integer().autoIncrement()();

  @ReferenceName('playlistEntries')
  IntColumn get playlistId =>
      integer().references(Playlists, #id, onDelete: KeyAction.cascade)();

  IntColumn get trackId => integer()
      .nullable()
      .references(Tracks, #id, onDelete: KeyAction.cascade)();

  /// A nested playlist included at this position.
  @ReferenceName('inclusionsOfThisPlaylist')
  IntColumn get childPlaylistId => integer()
      .nullable()
      .references(Playlists, #id, onDelete: KeyAction.cascade)();

  IntColumn get position => integer()();

  /// For hybrid playlists: when true this row *removes* a track the query
  /// would otherwise have included.
  BoolColumn get isExclusion => boolean().withDefault(const Constant(false))();

  /// Optional per-entry note ("the good remix").
  TextColumn get note => text().nullable()();

  DateTimeColumn get addedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  List<String> get customConstraints => [
        'CHECK ((track_id IS NULL) <> (child_playlist_id IS NULL))',
      ];
}

/// A hand-made order for the tracks a query found.
///
/// Manual playlists do not need this: their rows already carry a position, and
/// that position *is* the order. A smart playlist has no rows -- it is a query
/// -- so an order someone arranged by hand has to be recorded against the
/// tracks themselves.
///
/// Keyed by (playlist, track), which is why manual playlists cannot use it: a
/// manual playlist may hold the same track twice on purpose, and two copies
/// cannot share one key.
///
/// A track here that the query no longer finds is simply ignored, and its row
/// left alone. That is what makes "the order survives a change to the query"
/// work: narrow the query and widen it again, and the arrangement is still
/// there.
@TableIndex(name: 'idx_playlist_order', columns: {#playlistId, #position})
class PlaylistTrackOrder extends Table {
  @ReferenceName('trackOrderOfThisPlaylist')
  IntColumn get playlistId =>
      integer().references(Playlists, #id, onDelete: KeyAction.cascade)();

  @ReferenceName('orderedInPlaylists')
  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();

  IntColumn get position => integer()();

  @override
  Set<Column> get primaryKey => {playlistId, trackId};
}
