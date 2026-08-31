/// Read models for the library screens.
///
/// These are shaped for what a screen actually renders, so a grid of five
/// hundred albums is one query returning five hundred rows rather than a query
/// per card. They are plain immutable data with no drift types, which keeps the
/// widget layer independent of how storage happens to be arranged.
library;

import '../../data/db/enums.dart';

/// A card in the albums grid.
class AlbumCard {
  const AlbumCard({
    required this.id,
    required this.title,
    required this.artistName,
    required this.artistId,
    required this.trackCount,
    required this.imagePath,
    this.releaseYear,
    this.isVariousArtists = false,
    this.isFavorite = false,
    this.totalDurationMs = 0,
  });

  final int id;
  final String title;

  /// Display name of the album artist, or a summary for compilations.
  final String artistName;

  /// Null for a various-artists release, so the UI knows not to offer a link.
  final int? artistId;

  final int trackCount;

  /// Path of the artwork within the art store, already resolved through the
  /// track/album/artist fallback chain. Null means no art anywhere.
  final String? imagePath;

  final int? releaseYear;
  final bool isVariousArtists;
  final bool isFavorite;
  final int totalDurationMs;

  Duration get totalDuration => Duration(milliseconds: totalDurationMs);
}

/// A track as it appears in a list.
class TrackRow {
  const TrackRow({
    required this.id,
    required this.title,
    required this.credits,
    required this.durationMs,
    this.albumId,
    this.albumTitle,
    this.trackNo,
    this.discNo,
    this.imagePath,
    this.rating,
    this.isFavorite = false,
    this.playCount = 0,
    this.releaseYear,
    this.isMissing = false,
    this.lossless = false,
  });

  final int id;
  final String title;

  /// Every credited artist, in credit order. The list, not a joined string, so
  /// each name can be its own tappable target - which is what makes "an artist
  /// name is always one click from its page" true in practice.
  final List<TrackCreditRef> credits;

  final int durationMs;
  final int? albumId;
  final String? albumTitle;
  final int? trackNo;
  final int? discNo;
  final String? imagePath;
  final int? rating;
  final bool isFavorite;
  final int playCount;

  /// The track's own release year, or its album's when it has none.
  final int? releaseYear;

  /// True when every file holding this track is currently missing.
  final bool isMissing;

  final bool lossless;

  Duration get duration => Duration(milliseconds: durationMs);

  /// Main artists only, for a compact one-line summary.
  List<TrackCreditRef> get mainCredits =>
      credits.where((c) => c.role == 'mainArtist').toList();

  /// Guest artists, shown after the main ones.
  List<TrackCreditRef> get featuredCredits =>
      credits.where((c) => c.role == 'featured').toList();
}

/// One artist credited on a track.
class TrackCreditRef {
  const TrackCreditRef({
    required this.artistId,
    required this.name,
    required this.role,
    this.creditedAs,
  });

  final int artistId;

  /// The artist's canonical name.
  final String name;

  /// A [CreditRole] name.
  final String role;

  /// How this track spelled the name, when it differs from [name].
  final String? creditedAs;

  /// What to show: the spelling this track used, falling back to the canonical
  /// name. Keeps a release's own presentation while still linking correctly.
  String get displayName => creditedAs?.isNotEmpty == true ? creditedAs! : name;
}

/// An entry in the artists list.
class ArtistCard {
  const ArtistCard({
    required this.id,
    required this.name,
    required this.kind,
    required this.trackCount,
    required this.albumCount,
    this.imagePath,
    this.aliasCount = 0,
    this.memberCount = 0,
    this.isFavorite = false,
  });

  final int id;
  final String name;

  /// An [ArtistKind] name; `group` and `orchestra` render differently.
  final String kind;

  final int trackCount;
  final int albumCount;
  final String? imagePath;
  final int aliasCount;

  /// Number of members, for groups.
  final int memberCount;

  final bool isFavorite;

  bool get isGroup => kind == 'group' || kind == 'orchestra';
}

/// An entry in the tag list.
class TagCard {
  const TagCard({
    required this.id,
    required this.name,
    required this.trackCount,
    this.categoryId,
    this.categoryName,
    this.color,
    this.imagePath,
    this.childCount = 0,
  });

  final int id;
  final String name;
  final int trackCount;
  final int? categoryId;
  final String? categoryName;

  /// ARGB colour, from the tag or its category.
  final int? color;

  final String? imagePath;

  /// Nested tags beneath this one.
  final int childCount;
}

/// A playlist as it appears in the sidebar or a list.
class PlaylistCard {
  const PlaylistCard({
    required this.id,
    required this.name,
    required this.kind,
    required this.trackCount,
    this.parentId,
    this.imagePath,
    this.query,
    this.querySort,
    this.displaySort = PlaylistSort.added,
    this.sortDescending = false,
    this.grouping = PlaylistGrouping.none,
    this.childCount = 0,
    this.isPinned = false,
    this.depth = 0,
    this.description,
    this.totalDurationMs = 0,
  });

  final int id;
  final String name;

  /// A [PlaylistKind] name.
  final String kind;

  final int trackCount;
  final int? parentId;
  final String? imagePath;

  /// The search expression, for smart playlists.
  final String? query;

  /// The order applied to what the query finds, as a stored sort key.
  final String? querySort;

  /// How the tracks are ordered on screen.
  final PlaylistSort displaySort;
  final bool sortDescending;

  /// What the tracks are grouped under on screen.
  final PlaylistGrouping grouping;

  final int childCount;
  final bool isPinned;

  /// How deep in the nesting tree, for indentation. Zero at the top level.
  final int depth;

  final String? description;

  /// Total duration of the tracks directly in this playlist.
  final int totalDurationMs;

  Duration get totalDuration => Duration(milliseconds: totalDurationMs);

  bool get isSmart => kind == 'smart' || kind == 'hybrid';
  bool get isFolder => kind == 'folder';
}

/// Everything needed to actually play a track.
class PlayableTrack {
  const PlayableTrack({
    required this.trackId,
    required this.filePath,
    required this.title,
    required this.artistLine,
    required this.durationMs,
    this.albumId,
    this.albumTitle,
    this.imagePath,
    this.replayGainDb,
    this.lossless = false,
    this.codec,
    this.bitrate,
    this.sampleRate,
  });

  final int trackId;

  /// Absolute path of the file to hand to the engine.
  final String filePath;

  final String title;

  /// Pre-joined artist names, for the compact player bar.
  final String artistLine;

  final int durationMs;
  final int? albumId;
  final String? albumTitle;
  final String? imagePath;

  /// Track gain in dB, when the file carried ReplayGain.
  final double? replayGainDb;

  final bool lossless;
  final String? codec;
  final int? bitrate;
  final int? sampleRate;

  Duration get duration => Duration(milliseconds: durationMs);

  /// Short technical summary, e.g. "FLAC 44.1 kHz".
  String get formatLabel {
    final parts = <String>[];
    if (codec != null) parts.add(codec!.toUpperCase());
    if (sampleRate != null) {
      parts.add('${(sampleRate! / 1000).toStringAsFixed(1)} kHz');
    }
    if (!lossless && bitrate != null) {
      parts.add('${(bitrate! / 1000).round()} kbps');
    }
    return parts.join(' · ');
  }
}

/// How a library list is ordered.
enum LibrarySort {
  nameAscending,
  /// Disc then track number. Only meaningful within a single release.
  trackNumber,

  /// Grouped by release, then disc and track number within it.
  ///
  /// The right default for an artist's tracks: an artist page lists work from
  /// several releases, and alphabetical order scatters each album's running
  /// order, which then becomes the play order too.
  albumThenTrack,
  nameDescending,
  recentlyAdded,
  recentlyPlayed,
  mostPlayed,
  releaseYear,
  trackCount,
  duration,
  random;

  String get label => switch (this) {
        LibrarySort.nameAscending => 'Name (A–Z)',
        LibrarySort.trackNumber => 'Track number',
        LibrarySort.albumThenTrack => 'Album',
        LibrarySort.nameDescending => 'Name (Z–A)',
        LibrarySort.recentlyAdded => 'Recently added',
        LibrarySort.recentlyPlayed => 'Recently played',
        LibrarySort.mostPlayed => 'Most played',
        LibrarySort.releaseYear => 'Release year',
        LibrarySort.trackCount => 'Track count',
        LibrarySort.duration => 'Duration',
        LibrarySort.random => 'Random',
      };
}
