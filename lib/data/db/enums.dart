/// Enumerations stored in the database as text.
///
/// These are persisted by *name*, so renaming a value is a breaking schema
/// change. Add new values at the end and never reuse a removed name.
library;

// Separators are domain knowledge, not storage detail; re-exported here so
// table definitions keep a single enum import.
export '../../domain/credits/separator.dart' show SeparatorKind;

/// What kind of entity an artist row represents.
///
/// Groups are artists too: a group can be credited on a track or album exactly
/// like a person, and can additionally have members (see `ArtistMemberships`).
enum ArtistKind {
  person,
  group,
  orchestra,

  /// Fictional performers - vocal synths, in-universe bands, VTuber personas.
  character,
  unknown,
}

/// Why an alternative name exists. Drives how aliases are displayed and how
/// aggressively they are trusted when matching file metadata.
enum AliasKind {
  /// A genuinely different name for the same entity.
  alias,

  /// Latin-script rendering of a non-Latin name ("PinocchioP" for ピノキオピー).
  romanization,

  /// The name in its original script.
  nativeScript,

  /// "EWF" for "Earth, Wind & Fire".
  abbreviation,

  /// A common misspelling, kept so searches for it still land.
  misspelling,

  /// A name the entity used previously.
  formerName,

  /// Name used purely for sorting ("Beatles, The").
  sortName,
}

/// Category of an external link, used to pick an icon.
enum LinkKind {
  website,
  youtube,
  twitter,
  bluesky,
  mastodon,
  bandcamp,
  booth,
  soundcloud,
  spotify,
  appleMusic,
  niconico,
  pixiv,
  musicbrainz,
  vgmdb,
  wikipedia,
  other,
}

/// Release type of an album.
enum AlbumKind {
  album,
  ep,
  single,
  compilation,
  soundtrack,
  live,
  remixAlbum,
  demo,
  mixtape,
  unknown,
}

/// How an artist contributed to a track or album.
///
/// [mainArtist] is the primary credit and drives default display and grouping;
/// everything else is supplementary.
enum CreditRole {
  mainArtist,
  featured,
  composer,
  lyricist,
  arranger,
  producer,
  remixer,
  vocalist,
  performer,
  conductor,
  band,

  /// Artist of the work this track is a cover or arrangement of.
  originalArtist,
  illustrator,
  mixEngineer,
  masteringEngineer,
  other,
}

/// Where a piece of information came from. Anything marked [user] is never
/// overwritten by a rescan.
enum DataSource {
  /// Read straight out of the file's tags.
  fileMetadata,

  /// Entered or corrected by the user.
  user,

  /// Produced by splitting a multi-artist credit string.
  inferredFromSplit,

  /// Guessed from the file or folder name.
  inferredFromPath,

  /// Produced by a rule the app learned from an earlier user correction.
  learnedRule,
}

/// Lifecycle of a file the library knows about.
enum FileStatus {
  /// Seen on disk at its recorded location.
  present,

  /// Recorded but not found on the last scan. Kept, not deleted, so play
  /// counts and edits survive a disconnected drive.
  missing,

  /// Discovered but not yet parsed.
  pendingScan,

  /// Found but could not be read or parsed.
  unreadable,

  /// Recognised as not being a supported audio file.
  unsupported,
}

/// Where an image came from.
enum ImageKind {
  /// Extracted from a tag inside an audio file.
  embedded,

  /// A separate image file found next to the audio ("cover.jpg").
  sidecar,

  /// Supplied by the user.
  userProvided,
}

/// What an image depicts, so the right one is picked when several exist.
enum ImageRole {
  front,
  back,
  disc,
  booklet,
  artist,
  banner,
  logo,
  other,
}

/// Kind of playlist.
/// How a playlist's tracks are ordered on screen.
enum PlaylistSort {
  /// The order they were put there, which is the default: a playlist is a
  /// sequence somebody built, and rearranging it by default would throw that
  /// away.
  added,

  /// An order arranged by hand, by dragging.
  custom,

  title,
  artist,
  album,
  releaseYear,
  duration,
  rating,
  playCount,
  random;

  /// What to call it in a menu.
  String get label => switch (this) {
        PlaylistSort.added => 'As added',
        PlaylistSort.custom => 'Custom order',
        PlaylistSort.title => 'Title',
        PlaylistSort.artist => 'Artist',
        PlaylistSort.album => 'Album',
        PlaylistSort.releaseYear => 'Release year',
        PlaylistSort.duration => 'Length',
        PlaylistSort.rating => 'Rating',
        PlaylistSort.playCount => 'Times played',
        PlaylistSort.random => 'Shuffled',
      };

  static PlaylistSort of(String name) =>
      PlaylistSort.values.where((s) => s.name == name).firstOrNull ??
      PlaylistSort.added;
}

/// What a playlist's tracks are grouped under.
enum PlaylistGrouping {
  none,
  album,
  artist,
  releaseYear;

  String get label => switch (this) {
        PlaylistGrouping.none => 'No groups',
        PlaylistGrouping.album => 'By album',
        PlaylistGrouping.artist => 'By artist',
        PlaylistGrouping.releaseYear => 'By year',
      };

  static PlaylistGrouping of(String name) =>
      PlaylistGrouping.values.where((g) => g.name == name).firstOrNull ??
      PlaylistGrouping.none;
}

enum PlaylistKind {
  /// Explicit, ordered list of tracks the user curated.
  manual,

  /// Defined by a search query; re-evaluated as the library changes.
  smart,

  /// A smart query plus manual additions and exclusions.
  hybrid,

  /// Contains only other playlists; used purely for organisation.
  folder,
}

/// Storage format of a lyrics document.
enum LyricsFormat {
  /// Markdown, optionally with `[mm:ss.cc]` timestamps for syncing.
  markdown,

  /// Standard LRC.
  lrc,
  plainText,
}

/// What put a track into the play queue.
enum QueueSource {
  user,
  album,
  playlist,
  artist,
  tag,
  shuffle,
  search,

  /// Appended automatically when the queue ran dry.
  autoplay,
}

/// What started a library scan.
enum ScanTrigger {
  manual,
  startup,
  fileWatcher,
  folderAdded,
  scheduled,
  remoteCommand,
}

/// Outcome of a library scan.
enum ScanStatus { running, completed, failed, cancelled }

/// Something a scan could not resolve on its own.
enum ScanIssueKind {
  unreadableFile,
  unsupportedFormat,
  missingTags,

  /// A credit string the splitter was not confident about.
  ambiguousCredit,

  /// Two files claim to be the same track.
  duplicateContent,
  artworkFailed,
  permissionDenied,
}

/// How a home-page section lays its items out.
enum HomeLayout {
  /// A vertical list, capped at ten rows with a way through to the rest.
  list,

  /// A grid of artwork tiles.
  grid;

  String get label => switch (this) {
        HomeLayout.list => 'List',
        HomeLayout.grid => 'Grid',
      };
}

/// Where a home-page section's contents come from.
enum HomeSectionSource {
  /// Items the user put there by hand.
  curated,

  /// Computed from listening history rather than stored.
  recentlyPlayed;

  /// Whether the section's contents can be edited item by item.
  ///
  /// A computed section has no items to rearrange -- its order is a fact
  /// about what was played, and letting it be dragged would promise something
  /// the next play would silently undo.
  bool get isCurated => this == HomeSectionSource.curated;

  String get label => switch (this) {
        HomeSectionSource.curated => 'Chosen by hand',
        HomeSectionSource.recentlyPlayed => 'Recently played',
      };
}

/// What one item on the home page points at.
///
/// [collection] is both halves of "a hand-picked list of songs" and "a tile
/// that opens into more tiles": a collection holding tracks is the former,
/// one holding anything else is the latter, and the difference needs no
/// separate kind because nothing treats them differently.
enum HomeItemKind {
  album,
  artist,
  playlist,
  track,

  /// A container for other items, nestable without limit.
  ///
  /// Named "collection" rather than "group" because this app already uses
  /// "group" for a band -- an [ArtistKind] -- and a home page holding both
  /// would be using one word for two unrelated things.
  collection,

  /// A smart query, resolved to tracks when the section is shown.
  query;

  /// Whether this kind is drawn as a circle rather than a rounded square.
  ///
  /// The visual code is the library's, not the home page's: round means a
  /// person everywhere else in the app, and a home page that broke that
  /// would be teaching a second vocabulary for the same things.
  bool get isRound => this == HomeItemKind.artist;

  String get label => switch (this) {
        HomeItemKind.album => 'Album',
        HomeItemKind.artist => 'Artist',
        HomeItemKind.playlist => 'Playlist',
        HomeItemKind.track => 'Song',
        HomeItemKind.collection => 'Collection',
        HomeItemKind.query => 'Search',
      };
}
