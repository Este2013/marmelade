import 'package:drift/drift.dart';

import '../enums.dart';
import 'catalog.dart';
import 'images.dart';
import 'playlists.dart';

/// A grouping of related tags, such as "Genre", "Language" or "Mood".
///
/// Categories exist so the tag list is navigable rather than a flat wall of
/// labels, and so the app can say meaningful things like "show me every
/// language I own music in". Genre and Language are created automatically from
/// file metadata; everything else is the user's to invent.
class TagCategories extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get name => text()();

  /// Stable machine identifier. System categories use reserved slugs
  /// (`genre`, `language`) that the indexer writes into.
  TextColumn get slug => text().unique()();

  TextColumn get description => text().nullable()();

  /// ARGB colour used for chips in this category.
  IntColumn get color => integer().nullable()();

  /// Material icon code point.
  IntColumn get icon => integer().nullable()();

  /// True for categories the indexer relies on. They can be renamed and
  /// recoloured but not deleted.
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();

  /// When false, a track may carry at most one tag from this category.
  BoolColumn get allowMultiple =>
      boolean().withDefault(const Constant(true))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
}

/// A label that can be attached to tracks, albums and artists.
///
/// Tags nest via [parentTagId], so "Electronic > Dubstep" is expressible and a
/// query for the parent can include its children.
@TableIndex(name: 'idx_tags_category', columns: {#categoryId})
@TableIndex(name: 'idx_tags_name_key', columns: {#nameKey})
@TableIndex(name: 'idx_tags_parent', columns: {#parentTagId})
class Tags extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// Null for an uncategorised tag.
  IntColumn get categoryId => integer()
      .nullable()
      .references(TagCategories, #id, onDelete: KeyAction.setNull)();

  TextColumn get name => text()();

  /// Normalised [name], for matching.
  TextColumn get nameKey => text()();

  TextColumn get description => text().nullable()();

  /// ARGB colour. Falls back to the category colour when null.
  IntColumn get color => integer().nullable()();

  IntColumn get imageId => integer()
      .nullable()
      .references(Images, #id, onDelete: KeyAction.setNull)();

  /// Parent tag, for hierarchies such as "Electronic > Dubstep".
  IntColumn get parentTagId => integer()
      .nullable()
      .references(Tags, #id, onDelete: KeyAction.setNull)();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  List<Set<Column>> get uniqueKeys => [
        {categoryId, nameKey},
      ];
}

/// An alternative name for a tag, so "EDM" and "Electronic Dance Music" reach
/// the same place.
@TableIndex(name: 'idx_tag_aliases_key', columns: {#aliasKey})
class TagAliases extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get tagId =>
      integer().references(Tags, #id, onDelete: KeyAction.cascade)();
  TextColumn get alias => text()();
  TextColumn get aliasKey => text()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {tagId, aliasKey},
      ];
}

/// A tag applied to a track.
@TableIndex(name: 'idx_track_tags_tag', columns: {#tagId})
class TrackTags extends Table {
  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(Tags, #id, onDelete: KeyAction.cascade)();

  TextColumn get source =>
      textEnum<DataSource>().withDefault(const Constant('user'))();

  RealColumn get confidence => real().nullable()();

  DateTimeColumn get addedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  Set<Column> get primaryKey => {trackId, tagId};
}

/// A tag applied to a whole album.
@TableIndex(name: 'idx_album_tags_tag', columns: {#tagId})
class AlbumTags extends Table {
  IntColumn get albumId =>
      integer().references(Albums, #id, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(Tags, #id, onDelete: KeyAction.cascade)();
  TextColumn get source =>
      textEnum<DataSource>().withDefault(const Constant('user'))();
  DateTimeColumn get addedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  Set<Column> get primaryKey => {albumId, tagId};
}

/// A tag applied to an artist or group.
@TableIndex(name: 'idx_artist_tags_tag', columns: {#tagId})
class ArtistTags extends Table {
  IntColumn get artistId =>
      integer().references(Artists, #id, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(Tags, #id, onDelete: KeyAction.cascade)();
  TextColumn get source =>
      textEnum<DataSource>().withDefault(const Constant('user'))();
  DateTimeColumn get addedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  Set<Column> get primaryKey => {artistId, tagId};
}

/// Tags on a playlist.
///
/// Like an album's tags, these reach the tracks: a playlist tagged "workout"
/// makes every track it resolves to a workout track, nested playlists included.
/// The cascade lives in `v_track_effective_tags` rather than in duplicated
/// rows, so removing the tag from the playlist removes it from the tracks with
/// no bookkeeping.
class PlaylistTags extends Table {
  IntColumn get playlistId =>
      integer().references(Playlists, #id, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(Tags, #id, onDelete: KeyAction.cascade)();
  TextColumn get source =>
      textEnum<DataSource>().withDefault(const Constant('user'))();
  DateTimeColumn get addedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  Set<Column> get primaryKey => {playlistId, tagId};
}
