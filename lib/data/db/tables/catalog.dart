import 'package:drift/drift.dart';

import '../enums.dart';
import 'images.dart';
import 'library.dart';

/// A performer: a person, a group, an orchestra, or a fictional character.
///
/// Groups live in this same table rather than a separate one. That is what
/// makes "credit a group as the artist of a track" and "credit a person as the
/// artist of a track" the same operation, and lets group membership be a plain
/// self-relation (see [ArtistMemberships]).
@TableIndex(name: 'idx_artists_name_key', columns: {#nameKey})
@TableIndex(name: 'idx_artists_kind', columns: {#kind})
class Artists extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The canonical, true name, displayed as-is.
  TextColumn get name => text()();

  /// [name] normalised for matching: case-folded, width-folded, accents and
  /// punctuation stripped. Never displayed. See `domain/text/normalize.dart`.
  TextColumn get nameKey => text()();

  /// Optional explicit sort name ("Beatles, The").
  TextColumn get sortName => text().nullable()();

  TextColumn get kind =>
      textEnum<ArtistKind>().withDefault(const Constant('unknown'))();

  /// Free-text qualifier separating same-named artists ("UK punk band").
  TextColumn get disambiguation => text().nullable()();

  /// Markdown biography / notes.
  TextColumn get description => text().nullable()();

  IntColumn get imageId => integer()
      .nullable()
      .references(Images, #id, onDelete: KeyAction.setNull)();

  /// When true, the credit splitter must never break this name apart, even
  /// though it contains what looks like a separator. This is what keeps
  /// "AC/DC", "Simon & Garfunkel" and "Earth, Wind & Fire" whole.
  BoolColumn get neverSplit => boolean().withDefault(const Constant(false))();

  /// Set once the user has reviewed this artist. Verified rows are never
  /// silently rewritten by a rescan.
  BoolColumn get isVerified => boolean().withDefault(const Constant(false))();

  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  List<Set<Column>> get uniqueKeys => [
        // The same name is allowed only when disambiguated.
        {nameKey, disambiguation},
      ];
}

/// An additional searchable name for an artist.
///
/// This is how a Japanese-named artist stays reachable from a Latin keyboard:
/// the artist row for the native name carries an [AliasKind.romanization]
/// alias, and both feed the search index.
@TableIndex(name: 'idx_artist_aliases_key', columns: {#aliasKey})
class ArtistAliases extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get artistId =>
      integer().references(Artists, #id, onDelete: KeyAction.cascade)();

  TextColumn get alias => text()();

  /// Normalised form of [alias], for matching.
  TextColumn get aliasKey => text()();

  TextColumn get kind =>
      textEnum<AliasKind>().withDefault(const Constant('alias'))();

  /// BCP-47 language tag, when the alias is script- or language-specific.
  TextColumn get locale => text().nullable()();

  TextColumn get source =>
      textEnum<DataSource>().withDefault(const Constant('user'))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();

  @override
  List<Set<Column>> get uniqueKeys => [
        {artistId, aliasKey},
      ];
}

/// An external link shown on an artist page.
class ArtistLinks extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get artistId =>
      integer().references(Artists, #id, onDelete: KeyAction.cascade)();

  TextColumn get url => text()();
  TextColumn get label => text().nullable()();
  TextColumn get kind =>
      textEnum<LinkKind>().withDefault(const Constant('other'))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

/// Membership of an artist in a group. A self-relation on [Artists].
///
/// Lets a group page list its members, a member page list their groups, and a
/// search for a member surface the group's work.
@TableIndex(name: 'idx_memberships_member', columns: {#memberId})
class ArtistMemberships extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The group. Expected to be [ArtistKind.group] or [ArtistKind.orchestra],
  /// though this is not enforced.
  @ReferenceName('membersOfThisGroup')
  IntColumn get groupId =>
      integer().references(Artists, #id, onDelete: KeyAction.cascade)();

  @ReferenceName('groupsThisArtistIsIn')
  IntColumn get memberId =>
      integer().references(Artists, #id, onDelete: KeyAction.cascade)();

  /// Instrument or function within the group.
  TextColumn get role => text().nullable()();

  IntColumn get fromYear => integer().nullable()();
  IntColumn get toYear => integer().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {groupId, memberId, role},
      ];
}

/// A release: album, EP, single, compilation, soundtrack.
@TableIndex(name: 'idx_albums_name_key', columns: {#nameKey})
@TableIndex(name: 'idx_albums_album_artist', columns: {#albumArtistId})
class Albums extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get title => text()();

  /// Normalised [title], for matching.
  TextColumn get nameKey => text()();

  TextColumn get sortTitle => text().nullable()();

  TextColumn get kind =>
      textEnum<AlbumKind>().withDefault(const Constant('unknown'))();

  /// Release date, stored as separate parts because tags routinely carry only
  /// a year, and inventing a month and day would be a lie.
  IntColumn get releaseYear => integer().nullable()();
  IntColumn get releaseMonth => integer().nullable()();
  IntColumn get releaseDay => integer().nullable()();

  /// The album's primary artist. Null for genuine various-artists releases.
  IntColumn get albumArtistId => integer()
      .nullable()
      .references(Artists, #id, onDelete: KeyAction.setNull)();

  BoolColumn get isVariousArtists =>
      boolean().withDefault(const Constant(false))();

  IntColumn get totalTracks => integer().nullable()();
  IntColumn get totalDiscs => integer().nullable()();

  TextColumn get description => text().nullable()();

  IntColumn get imageId => integer()
      .nullable()
      .references(Images, #id, onDelete: KeyAction.setNull)();

  /// Directory the album was discovered in. A hint for re-matching and for
  /// finding sidecar artwork, not an authority.
  TextColumn get folderHint => text().nullable()();

  TextColumn get label => text().nullable()();
  TextColumn get catalogNumber => text().nullable()();

  BoolColumn get isVerified => boolean().withDefault(const Constant(false))();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
}

/// An additional searchable name for an album.
@TableIndex(name: 'idx_album_aliases_key', columns: {#aliasKey})
class AlbumAliases extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get albumId =>
      integer().references(Albums, #id, onDelete: KeyAction.cascade)();
  TextColumn get alias => text()();
  TextColumn get aliasKey => text()();
  TextColumn get kind =>
      textEnum<AliasKind>().withDefault(const Constant('alias'))();
  TextColumn get locale => text().nullable()();
  TextColumn get source =>
      textEnum<DataSource>().withDefault(const Constant('user'))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {albumId, aliasKey},
      ];
}

/// A song: the logical work, independent of which files hold it.
@TableIndex(name: 'idx_tracks_album', columns: {#albumId})
@TableIndex(name: 'idx_tracks_name_key', columns: {#nameKey})
@TableIndex(name: 'idx_tracks_last_played', columns: {#lastPlayedAt})
class Tracks extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get title => text()();

  /// Normalised [title], for matching and duplicate detection.
  TextColumn get nameKey => text()();

  TextColumn get sortTitle => text().nullable()();

  IntColumn get albumId => integer()
      .nullable()
      .references(Albums, #id, onDelete: KeyAction.setNull)();

  IntColumn get discNo => integer().nullable()();
  IntColumn get trackNo => integer().nullable()();

  IntColumn get durationMs => integer().nullable()();

  IntColumn get releaseYear => integer().nullable()();

  RealColumn get bpm => real().nullable()();

  /// Musical key as tagged ("F#m", "8A").
  TextColumn get initialKey => text().nullable()();

  TextColumn get comment => text().nullable()();

  /// Markdown notes the user attached to this track.
  TextColumn get notes => text().nullable()();

  /// 0-100. Null means unrated, which is distinct from a rating of zero.
  IntColumn get rating => integer().nullable()();

  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  IntColumn get playCount => integer().withDefault(const Constant(0))();
  IntColumn get skipCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastPlayedAt => dateTime().nullable()();

  /// Track-specific artwork, which wins over the album's and the artist's.
  IntColumn get imageId => integer()
      .nullable()
      .references(Images, #id, onDelete: KeyAction.setNull)();

  /// Which file to play when several hold this track. Null means "decide by
  /// the quality preference in settings".
  IntColumn get preferredFileId => integer()
      .nullable()
      .references(MediaFiles, #id, onDelete: KeyAction.setNull)();

  BoolColumn get isVerified => boolean().withDefault(const Constant(false))();

  DateTimeColumn get addedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
  DateTimeColumn get updatedAt =>
      dateTime().clientDefault(() => DateTime.now().toUtc())();
}

/// An additional searchable name for a track.
@TableIndex(name: 'idx_track_aliases_key', columns: {#aliasKey})
class TrackAliases extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();
  TextColumn get alias => text()();
  TextColumn get aliasKey => text()();
  TextColumn get kind =>
      textEnum<AliasKind>().withDefault(const Constant('alias'))();
  TextColumn get locale => text().nullable()();
  TextColumn get source =>
      textEnum<DataSource>().withDefault(const Constant('user'))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {trackId, aliasKey},
      ];
}

/// An artist's contribution to a track.
///
/// This table is the point of the whole schema. A track tagged
/// `artist = "Camellia x Nanahira"` becomes two rows here, both
/// [CreditRole.mainArtist], each pointing at a real artist row - which is
/// exactly why searching for either name finds the track.
///
/// [creditedAs] preserves the original spelling for *this* credit, so the
/// track can still be displayed the way its file spelled it while linking to
/// the canonical artist.
@TableIndex(name: 'idx_track_credits_artist', columns: {#artistId})
@TableIndex(name: 'idx_track_credits_role', columns: {#role})
class TrackCredits extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();

  IntColumn get artistId =>
      integer().references(Artists, #id, onDelete: KeyAction.cascade)();

  TextColumn get role =>
      textEnum<CreditRole>().withDefault(const Constant('mainArtist'))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// How this artist was spelled on this particular track.
  TextColumn get creditedAs => text().nullable()();

  TextColumn get source =>
      textEnum<DataSource>().withDefault(const Constant('fileMetadata'))();

  /// 0.0-1.0 for inferred credits. Low-confidence credits surface in the
  /// review queue instead of being applied silently.
  RealColumn get confidence => real().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {trackId, artistId, role},
      ];
}

/// An artist's contribution to an album. Same shape as [TrackCredits].
@TableIndex(name: 'idx_album_credits_artist', columns: {#artistId})
class AlbumCredits extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get albumId =>
      integer().references(Albums, #id, onDelete: KeyAction.cascade)();

  IntColumn get artistId =>
      integer().references(Artists, #id, onDelete: KeyAction.cascade)();

  TextColumn get role =>
      textEnum<CreditRole>().withDefault(const Constant('mainArtist'))();

  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  TextColumn get creditedAs => text().nullable()();
  TextColumn get source =>
      textEnum<DataSource>().withDefault(const Constant('fileMetadata'))();

  @override
  List<Set<Column>> get uniqueKeys => [
        {albumId, artistId, role},
      ];
}
