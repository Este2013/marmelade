/// The portable form of everything a person entered by hand.
///
/// The problem this exists for: the same music lives on two computers, and
/// everything the app is *for* -- split credits, aliases, tags, ratings,
/// playlists -- lives only in the database of whichever machine did the work.
/// Copying the audio files across carries none of it, so the work would have
/// to be done twice.
///
/// Three rules shape the format:
///
///   * **Nothing machine-local.** No row ids, no absolute paths, no artwork
///     file paths. Rows are identified by what they *are* -- a normalised
///     name, a content hash, a track's file fingerprint -- so the same bundle
///     means the same thing on a machine that has never seen this library.
///   * **References are bundle-local.** Inside one bundle, entities point at
///     each other by [TransferEntity.id], which is just the exporting
///     machine's row id: convenient, self-consistent, and meaningless outside
///     the file. An importer maps them to its own ids as it goes. This keeps
///     the file readable and avoids repeating an identity block at every
///     reference.
///   * **Additive by nature.** A bundle says what exists, never what was
///     deleted, because a bundle written last week must not delete a tag
///     added here yesterday. Deletions do not travel; see
///     `LibraryImporter` for what that means when merging.
///
/// Written as JSON rather than a database copy on purpose. A copy would carry
/// the other machine's file paths and row ids, would overwrite rather than
/// merge, and could not be read by a human wondering what went wrong.
library;

import 'dart:convert';

/// Bundle format version.
///
/// Bumped only for a change an older reader could not survive. New optional
/// fields do not need it: every reader treats an unknown key as "not mine"
/// and a missing key as null.
const transferSchemaVersion = 1;

/// Marker so a stray JSON file is not mistaken for a bundle.
const transferBundleKind = 'marmelade-library';

/// The file a bundle's metadata is written to inside its folder.
const transferBundleFileName = 'library.json';

/// Where artwork goes inside a bundle folder, when it is included.
const transferArtworkDirName = 'artwork';

/// Where audio files go inside a bundle folder, when they are included.
///
/// Opt-in and off by default: a library's audio is gigabytes, and a bundle is
/// often headed somewhere metered -- a cloud folder, a phone tether.
const transferAudioDirName = 'audio';

/// Anything carrying a bundle-local id.
abstract class TransferEntity {
  const TransferEntity({required this.id});

  /// The exporting machine's row id. Used only to resolve references *within*
  /// this bundle; it has no meaning on the importing machine.
  final int id;
}

// --------------------------------------------------------------------- helpers

/// Reads a list of objects, tolerating a missing key.
List<T> _list<T>(
  Object? raw,
  T Function(Map<String, Object?>) parse,
) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map<String, Object?>) parse(item),
  ];
}

List<int> _ints(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is int) item,
  ];
}

String _str(Object? raw, [String fallback = '']) =>
    raw is String ? raw : fallback;

String? _strOrNull(Object? raw) =>
    raw is String && raw.isNotEmpty ? raw : null;

int _int(Object? raw, [int fallback = 0]) => raw is int ? raw : fallback;

int? _intOrNull(Object? raw) => raw is int ? raw : null;

double? _doubleOrNull(Object? raw) =>
    raw is num ? raw.toDouble() : null;

bool _bool(Object? raw, [bool fallback = false]) =>
    raw is bool ? raw : fallback;

DateTime? _time(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// Drops null and empty-collection entries, so a bundle stays readable
/// instead of being mostly nulls.
Map<String, Object?> _prune(Map<String, Object?> map) {
  map.removeWhere(
    (_, value) =>
        value == null || (value is Iterable && value.isEmpty) ||
        (value is Map && value.isEmpty),
  );
  return map;
}

String? _iso(DateTime? time) => time?.toUtc().toIso8601String();

// ---------------------------------------------------------------------- pieces

/// An alternative name, for whichever entity carries it.
class TransferAlias {
  const TransferAlias({
    required this.alias,
    this.kind = 'alias',
    this.locale,
    this.source = 'user',
  });

  final String alias;
  final String kind;
  final String? locale;
  final String source;

  factory TransferAlias.fromJson(Map<String, Object?> json) => TransferAlias(
        alias: _str(json['alias']),
        kind: _str(json['kind'], 'alias'),
        locale: _strOrNull(json['locale']),
        source: _str(json['source'], 'user'),
      );

  Map<String, Object?> toJson() => _prune({
        'alias': alias,
        'kind': kind,
        'locale': locale,
        'source': source,
      });
}

/// An external link on an artist.
class TransferLink {
  const TransferLink({
    required this.url,
    this.label,
    this.kind = 'other',
    this.sortOrder = 0,
  });

  final String url;
  final String? label;
  final String kind;
  final int sortOrder;

  factory TransferLink.fromJson(Map<String, Object?> json) => TransferLink(
        url: _str(json['url']),
        label: _strOrNull(json['label']),
        kind: _str(json['kind'], 'other'),
        sortOrder: _int(json['sortOrder']),
      );

  Map<String, Object?> toJson() => _prune({
        'url': url,
        'label': label,
        'kind': kind,
        if (sortOrder != 0) 'sortOrder': sortOrder,
      });
}

/// One artist inside a group.
class TransferMembership {
  const TransferMembership({
    required this.memberId,
    this.role,
    this.fromYear,
    this.toYear,
    this.sortOrder = 0,
  });

  /// Bundle-local id of the member artist.
  final int memberId;
  final String? role;
  final int? fromYear;
  final int? toYear;
  final int sortOrder;

  factory TransferMembership.fromJson(Map<String, Object?> json) =>
      TransferMembership(
        memberId: _int(json['memberId'], -1),
        role: _strOrNull(json['role']),
        fromYear: _intOrNull(json['fromYear']),
        toYear: _intOrNull(json['toYear']),
        sortOrder: _int(json['sortOrder']),
      );

  Map<String, Object?> toJson() => _prune({
        'memberId': memberId,
        'role': role,
        'fromYear': fromYear,
        'toYear': toYear,
        if (sortOrder != 0) 'sortOrder': sortOrder,
      });
}

/// An artist credited on a track or an album.
class TransferCredit {
  const TransferCredit({
    required this.artistId,
    this.role = 'mainArtist',
    this.creditedAs,
    this.sortOrder = 0,
    this.source = 'fileMetadata',
    this.confidence,
  });

  /// Bundle-local artist id.
  final int artistId;
  final String role;

  /// The spelling this release used, when it differs from the artist's name.
  /// The whole point of the credit model, so it travels.
  final String? creditedAs;
  final int sortOrder;
  final String source;
  final double? confidence;

  factory TransferCredit.fromJson(Map<String, Object?> json) => TransferCredit(
        artistId: _int(json['artistId'], -1),
        role: _str(json['role'], 'mainArtist'),
        creditedAs: _strOrNull(json['creditedAs']),
        sortOrder: _int(json['sortOrder']),
        source: _str(json['source'], 'fileMetadata'),
        confidence: _doubleOrNull(json['confidence']),
      );

  Map<String, Object?> toJson() => _prune({
        'artistId': artistId,
        'role': role,
        'creditedAs': creditedAs,
        if (sortOrder != 0) 'sortOrder': sortOrder,
        'source': source,
        'confidence': confidence,
      });
}

/// How to recognise one of a track's files on another machine.
///
/// [quickKey] is the app's own payload fingerprint (see `FileIdentity`): it
/// covers the audio bytes only, so retagging a file does not change it, and a
/// file copied between machines keeps it exactly. It is a 64-bit
/// non-cryptographic hash, so it is paired with [sizeBytes] rather than
/// trusted alone.
class TransferFileIdentity {
  const TransferFileIdentity({
    this.quickKey,
    this.contentKey,
    required this.sizeBytes,
    required this.fileName,
    this.relativePath,
    this.durationMs,
  });

  final String? quickKey;

  /// Full-payload fingerprint. Rarely present -- the indexer only computes it
  /// on demand -- but conclusive when it is.
  final String? contentKey;

  final int sizeBytes;
  final String fileName;

  /// Path inside the library folder it was found in, forward-slashed. Useful
  /// when the same music sits under the same tree on both machines.
  final String? relativePath;

  final int? durationMs;

  factory TransferFileIdentity.fromJson(Map<String, Object?> json) =>
      TransferFileIdentity(
        quickKey: _strOrNull(json['quickKey']),
        contentKey: _strOrNull(json['contentKey']),
        sizeBytes: _int(json['sizeBytes'], -1),
        fileName: _str(json['fileName']),
        relativePath: _strOrNull(json['relativePath']),
        durationMs: _intOrNull(json['durationMs']),
      );

  Map<String, Object?> toJson() => _prune({
        'quickKey': quickKey,
        'contentKey': contentKey,
        'sizeBytes': sizeBytes,
        'fileName': fileName,
        'relativePath': relativePath,
        'durationMs': durationMs,
      });
}

/// A lyrics document, carried as text rather than as a file path.
class TransferLyrics {
  const TransferLyrics({
    required this.content,
    this.format = 'markdown',
    this.isSynced = false,
    this.language,
    this.offsetMs = 0,
    this.source = 'user',
    this.updatedAt,
  });

  final String content;
  final String format;
  final bool isSynced;
  final String? language;
  final int offsetMs;
  final String source;
  final DateTime? updatedAt;

  factory TransferLyrics.fromJson(Map<String, Object?> json) => TransferLyrics(
        content: _str(json['content']),
        format: _str(json['format'], 'markdown'),
        isSynced: _bool(json['isSynced']),
        language: _strOrNull(json['language']),
        offsetMs: _int(json['offsetMs']),
        source: _str(json['source'], 'user'),
        updatedAt: _time(json['updatedAt']),
      );

  Map<String, Object?> toJson() => _prune({
        'content': content,
        'format': format,
        if (isSynced) 'isSynced': isSynced,
        'language': language,
        if (offsetMs != 0) 'offsetMs': offsetMs,
        'source': source,
        'updatedAt': _iso(updatedAt),
      });
}

/// One row of a playlist: a track, or another playlist included whole.
class TransferPlaylistItem {
  const TransferPlaylistItem({
    required this.position,
    this.trackId,
    this.childPlaylistId,
    this.isExclusion = false,
    this.note,
  });

  final int position;

  /// Bundle-local track id. Exactly one of this and [childPlaylistId] is set,
  /// which the database enforces with a CHECK constraint.
  final int? trackId;
  final int? childPlaylistId;

  /// A track a queried playlist explicitly does not want.
  final bool isExclusion;
  final String? note;

  factory TransferPlaylistItem.fromJson(Map<String, Object?> json) =>
      TransferPlaylistItem(
        position: _int(json['position']),
        trackId: _intOrNull(json['trackId']),
        childPlaylistId: _intOrNull(json['childPlaylistId']),
        isExclusion: _bool(json['isExclusion']),
        note: _strOrNull(json['note']),
      );

  Map<String, Object?> toJson() => _prune({
        'position': position,
        'trackId': trackId,
        'childPlaylistId': childPlaylistId,
        if (isExclusion) 'isExclusion': isExclusion,
        'note': note,
      });
}

/// A hand-dragged position inside a queried playlist.
class TransferTrackOrder {
  const TransferTrackOrder({required this.trackId, required this.position});

  final int trackId;
  final int position;

  factory TransferTrackOrder.fromJson(Map<String, Object?> json) =>
      TransferTrackOrder(
        trackId: _int(json['trackId'], -1),
        position: _int(json['position']),
      );

  Map<String, Object?> toJson() =>
      {'trackId': trackId, 'position': position};
}

// -------------------------------------------------------------------- entities

/// An artist, with everything hanging off it that a person entered.
class TransferArtist extends TransferEntity {
  const TransferArtist({
    required super.id,
    required this.name,
    required this.nameKey,
    this.disambiguation,
    this.sortName,
    this.kind = 'unknown',
    this.description,
    this.neverSplit = false,
    this.isVerified = false,
    this.isFavorite = false,
    this.imageId,
    this.updatedAt,
    this.aliases = const [],
    this.links = const [],
    this.members = const [],
    this.tagIds = const [],
  });

  final String name;

  /// Normalised [name]; the portable identity, together with
  /// [disambiguation].
  final String nameKey;
  final String? disambiguation;
  final String? sortName;
  final String kind;
  final String? description;

  /// "Never split this credit string" -- a decision that took a person's
  /// attention, and the most annoying thing to lose.
  final bool neverSplit;
  final bool isVerified;
  final bool isFavorite;

  /// Bundle-local image id.
  final int? imageId;
  final DateTime? updatedAt;

  final List<TransferAlias> aliases;
  final List<TransferLink> links;
  final List<TransferMembership> members;
  final List<int> tagIds;

  factory TransferArtist.fromJson(Map<String, Object?> json) => TransferArtist(
        id: _int(json['id'], -1),
        name: _str(json['name']),
        nameKey: _str(json['nameKey']),
        disambiguation: _strOrNull(json['disambiguation']),
        sortName: _strOrNull(json['sortName']),
        kind: _str(json['kind'], 'unknown'),
        description: _strOrNull(json['description']),
        neverSplit: _bool(json['neverSplit']),
        isVerified: _bool(json['isVerified']),
        isFavorite: _bool(json['isFavorite']),
        imageId: _intOrNull(json['imageId']),
        updatedAt: _time(json['updatedAt']),
        aliases: _list(json['aliases'], TransferAlias.fromJson),
        links: _list(json['links'], TransferLink.fromJson),
        members: _list(json['members'], TransferMembership.fromJson),
        tagIds: _ints(json['tagIds']),
      );

  Map<String, Object?> toJson() => _prune({
        'id': id,
        'name': name,
        'nameKey': nameKey,
        'disambiguation': disambiguation,
        'sortName': sortName,
        'kind': kind,
        'description': description,
        if (neverSplit) 'neverSplit': neverSplit,
        if (isVerified) 'isVerified': isVerified,
        if (isFavorite) 'isFavorite': isFavorite,
        'imageId': imageId,
        'updatedAt': _iso(updatedAt),
        'aliases': [for (final a in aliases) a.toJson()],
        'links': [for (final l in links) l.toJson()],
        'members': [for (final m in members) m.toJson()],
        'tagIds': tagIds,
      });
}

/// A release.
class TransferAlbum extends TransferEntity {
  const TransferAlbum({
    required super.id,
    required this.title,
    required this.nameKey,
    this.sortTitle,
    this.kind = 'unknown',
    this.releaseYear,
    this.releaseMonth,
    this.releaseDay,
    this.albumArtistId,
    this.isVariousArtists = false,
    this.totalTracks,
    this.totalDiscs,
    this.description,
    this.label,
    this.catalogNumber,
    this.isVerified = false,
    this.isFavorite = false,
    this.imageId,
    this.updatedAt,
    this.aliases = const [],
    this.credits = const [],
    this.tagIds = const [],
  });

  final String title;
  final String nameKey;
  final String? sortTitle;
  final String kind;
  final int? releaseYear;
  final int? releaseMonth;
  final int? releaseDay;

  /// Bundle-local artist id.
  final int? albumArtistId;
  final bool isVariousArtists;
  final int? totalTracks;
  final int? totalDiscs;
  final String? description;
  final String? label;
  final String? catalogNumber;
  final bool isVerified;
  final bool isFavorite;
  final int? imageId;
  final DateTime? updatedAt;

  final List<TransferAlias> aliases;
  final List<TransferCredit> credits;
  final List<int> tagIds;

  factory TransferAlbum.fromJson(Map<String, Object?> json) => TransferAlbum(
        id: _int(json['id'], -1),
        title: _str(json['title']),
        nameKey: _str(json['nameKey']),
        sortTitle: _strOrNull(json['sortTitle']),
        kind: _str(json['kind'], 'unknown'),
        releaseYear: _intOrNull(json['releaseYear']),
        releaseMonth: _intOrNull(json['releaseMonth']),
        releaseDay: _intOrNull(json['releaseDay']),
        albumArtistId: _intOrNull(json['albumArtistId']),
        isVariousArtists: _bool(json['isVariousArtists']),
        totalTracks: _intOrNull(json['totalTracks']),
        totalDiscs: _intOrNull(json['totalDiscs']),
        description: _strOrNull(json['description']),
        label: _strOrNull(json['label']),
        catalogNumber: _strOrNull(json['catalogNumber']),
        isVerified: _bool(json['isVerified']),
        isFavorite: _bool(json['isFavorite']),
        imageId: _intOrNull(json['imageId']),
        updatedAt: _time(json['updatedAt']),
        aliases: _list(json['aliases'], TransferAlias.fromJson),
        credits: _list(json['credits'], TransferCredit.fromJson),
        tagIds: _ints(json['tagIds']),
      );

  Map<String, Object?> toJson() => _prune({
        'id': id,
        'title': title,
        'nameKey': nameKey,
        'sortTitle': sortTitle,
        'kind': kind,
        'releaseYear': releaseYear,
        'releaseMonth': releaseMonth,
        'releaseDay': releaseDay,
        'albumArtistId': albumArtistId,
        if (isVariousArtists) 'isVariousArtists': isVariousArtists,
        'totalTracks': totalTracks,
        'totalDiscs': totalDiscs,
        'description': description,
        'label': label,
        'catalogNumber': catalogNumber,
        if (isVerified) 'isVerified': isVerified,
        if (isFavorite) 'isFavorite': isFavorite,
        'imageId': imageId,
        'updatedAt': _iso(updatedAt),
        'aliases': [for (final a in aliases) a.toJson()],
        'credits': [for (final c in credits) c.toJson()],
        'tagIds': tagIds,
      });
}

/// A track, and the hand-entered state attached to it.
class TransferTrack extends TransferEntity {
  const TransferTrack({
    required super.id,
    required this.title,
    required this.nameKey,
    this.sortTitle,
    this.albumId,
    this.trackNo,
    this.discNo,
    this.durationMs,
    this.releaseYear,
    this.bpm,
    this.initialKey,
    this.comment,
    this.notes,
    this.rating,
    this.isFavorite = false,
    this.playCount = 0,
    this.skipCount = 0,
    this.lastPlayedAt,
    this.isVerified = false,
    this.addedAt,
    this.updatedAt,
    this.imageId,
    this.files = const [],
    this.credits = const [],
    this.aliases = const [],
    this.tagIds = const [],
    this.lyrics = const [],
  });

  final String title;
  final String nameKey;
  final String? sortTitle;

  /// Bundle-local album id.
  final int? albumId;
  final int? trackNo;
  final int? discNo;
  final int? durationMs;
  final int? releaseYear;
  final double? bpm;
  final String? initialKey;
  final String? comment;
  final String? notes;

  /// Null is "unrated", which is not the same as zero.
  final int? rating;
  final bool isFavorite;
  final int playCount;
  final int skipCount;
  final DateTime? lastPlayedAt;
  final bool isVerified;
  final DateTime? addedAt;
  final DateTime? updatedAt;
  final int? imageId;

  /// Every file that holds this track, so a match can be found by any of
  /// them. A track exported from a machine with both a FLAC and an MP3 lands
  /// on either one elsewhere.
  final List<TransferFileIdentity> files;

  final List<TransferCredit> credits;
  final List<TransferAlias> aliases;
  final List<int> tagIds;
  final List<TransferLyrics> lyrics;

  factory TransferTrack.fromJson(Map<String, Object?> json) => TransferTrack(
        id: _int(json['id'], -1),
        title: _str(json['title']),
        nameKey: _str(json['nameKey']),
        sortTitle: _strOrNull(json['sortTitle']),
        albumId: _intOrNull(json['albumId']),
        trackNo: _intOrNull(json['trackNo']),
        discNo: _intOrNull(json['discNo']),
        durationMs: _intOrNull(json['durationMs']),
        releaseYear: _intOrNull(json['releaseYear']),
        bpm: _doubleOrNull(json['bpm']),
        initialKey: _strOrNull(json['initialKey']),
        comment: _strOrNull(json['comment']),
        notes: _strOrNull(json['notes']),
        rating: _intOrNull(json['rating']),
        isFavorite: _bool(json['isFavorite']),
        playCount: _int(json['playCount']),
        skipCount: _int(json['skipCount']),
        lastPlayedAt: _time(json['lastPlayedAt']),
        isVerified: _bool(json['isVerified']),
        addedAt: _time(json['addedAt']),
        updatedAt: _time(json['updatedAt']),
        imageId: _intOrNull(json['imageId']),
        files: _list(json['files'], TransferFileIdentity.fromJson),
        credits: _list(json['credits'], TransferCredit.fromJson),
        aliases: _list(json['aliases'], TransferAlias.fromJson),
        tagIds: _ints(json['tagIds']),
        lyrics: _list(json['lyrics'], TransferLyrics.fromJson),
      );

  Map<String, Object?> toJson() => _prune({
        'id': id,
        'title': title,
        'nameKey': nameKey,
        'sortTitle': sortTitle,
        'albumId': albumId,
        'trackNo': trackNo,
        'discNo': discNo,
        'durationMs': durationMs,
        'releaseYear': releaseYear,
        'bpm': bpm,
        'initialKey': initialKey,
        'comment': comment,
        'notes': notes,
        'rating': rating,
        if (isFavorite) 'isFavorite': isFavorite,
        if (playCount != 0) 'playCount': playCount,
        if (skipCount != 0) 'skipCount': skipCount,
        'lastPlayedAt': _iso(lastPlayedAt),
        if (isVerified) 'isVerified': isVerified,
        'addedAt': _iso(addedAt),
        'updatedAt': _iso(updatedAt),
        'imageId': imageId,
        'files': [for (final f in files) f.toJson()],
        'credits': [for (final c in credits) c.toJson()],
        'aliases': [for (final a in aliases) a.toJson()],
        'tagIds': tagIds,
        'lyrics': [for (final l in lyrics) l.toJson()],
      });
}

/// A tag category. Identified by its slug, which is unique by schema.
class TransferTagCategory extends TransferEntity {
  const TransferTagCategory({
    required super.id,
    required this.name,
    this.slug,
    this.description,
    this.color,
    this.icon,
    this.isSystem = false,
    this.allowMultiple = true,
    this.sortOrder = 0,
  });

  final String name;
  final String? slug;
  final String? description;
  final int? color;
  final int? icon;
  final bool isSystem;
  final bool allowMultiple;
  final int sortOrder;

  factory TransferTagCategory.fromJson(Map<String, Object?> json) =>
      TransferTagCategory(
        id: _int(json['id'], -1),
        name: _str(json['name']),
        slug: _strOrNull(json['slug']),
        description: _strOrNull(json['description']),
        color: _intOrNull(json['color']),
        icon: _intOrNull(json['icon']),
        isSystem: _bool(json['isSystem']),
        allowMultiple: _bool(json['allowMultiple'], true),
        sortOrder: _int(json['sortOrder']),
      );

  Map<String, Object?> toJson() => _prune({
        'id': id,
        'name': name,
        'slug': slug,
        'description': description,
        'color': color,
        'icon': icon,
        if (isSystem) 'isSystem': isSystem,
        if (!allowMultiple) 'allowMultiple': allowMultiple,
        if (sortOrder != 0) 'sortOrder': sortOrder,
      });
}

/// A tag.
class TransferTag extends TransferEntity {
  const TransferTag({
    required super.id,
    required this.name,
    required this.nameKey,
    this.categoryId,
    this.description,
    this.color,
    this.parentTagId,
    this.sortOrder = 0,
    this.isFavorite = false,
    this.imageId,
    this.aliases = const [],
  });

  final String name;
  final String nameKey;

  /// Bundle-local category id.
  final int? categoryId;
  final String? description;
  final int? color;

  /// Bundle-local id of the tag this one nests under.
  final int? parentTagId;
  final int sortOrder;
  final bool isFavorite;
  final int? imageId;
  final List<TransferAlias> aliases;

  factory TransferTag.fromJson(Map<String, Object?> json) => TransferTag(
        id: _int(json['id'], -1),
        name: _str(json['name']),
        nameKey: _str(json['nameKey']),
        categoryId: _intOrNull(json['categoryId']),
        description: _strOrNull(json['description']),
        color: _intOrNull(json['color']),
        parentTagId: _intOrNull(json['parentTagId']),
        sortOrder: _int(json['sortOrder']),
        isFavorite: _bool(json['isFavorite']),
        imageId: _intOrNull(json['imageId']),
        aliases: _list(json['aliases'], TransferAlias.fromJson),
      );

  Map<String, Object?> toJson() => _prune({
        'id': id,
        'name': name,
        'nameKey': nameKey,
        'categoryId': categoryId,
        'description': description,
        'color': color,
        'parentTagId': parentTagId,
        if (sortOrder != 0) 'sortOrder': sortOrder,
        if (isFavorite) 'isFavorite': isFavorite,
        'imageId': imageId,
        'aliases': [for (final a in aliases) a.toJson()],
      });
}

/// A playlist, including the query behind a smart one.
class TransferPlaylist extends TransferEntity {
  const TransferPlaylist({
    required super.id,
    required this.name,
    required this.nameKey,
    this.parentId,
    this.description,
    this.kind = 'manual',
    this.query,
    this.queryLimit,
    this.querySort,
    this.autoUpdate = true,
    this.displaySort = 'added',
    this.sortDescending = false,
    this.groupBy = 'none',
    this.isPinned = false,
    this.sortOrder = 0,
    this.imageId,
    this.createdAt,
    this.updatedAt,
    this.items = const [],
    this.trackOrder = const [],
    this.tagIds = const [],
  });

  final String name;
  final String nameKey;

  /// Bundle-local id of the playlist this one sits inside.
  final int? parentId;
  final String? description;
  final String kind;

  /// The search expression, as typed. Portable by construction: it names
  /// artists and tags rather than row ids.
  final String? query;
  final int? queryLimit;
  final String? querySort;
  final bool autoUpdate;
  final String displaySort;
  final bool sortDescending;
  final String groupBy;
  final bool isPinned;
  final int sortOrder;
  final int? imageId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  final List<TransferPlaylistItem> items;
  final List<TransferTrackOrder> trackOrder;
  final List<int> tagIds;

  factory TransferPlaylist.fromJson(Map<String, Object?> json) =>
      TransferPlaylist(
        id: _int(json['id'], -1),
        name: _str(json['name']),
        nameKey: _str(json['nameKey']),
        parentId: _intOrNull(json['parentId']),
        description: _strOrNull(json['description']),
        kind: _str(json['kind'], 'manual'),
        query: _strOrNull(json['query']),
        queryLimit: _intOrNull(json['queryLimit']),
        querySort: _strOrNull(json['querySort']),
        autoUpdate: _bool(json['autoUpdate'], true),
        displaySort: _str(json['displaySort'], 'added'),
        sortDescending: _bool(json['sortDescending']),
        groupBy: _str(json['groupBy'], 'none'),
        isPinned: _bool(json['isPinned']),
        sortOrder: _int(json['sortOrder']),
        imageId: _intOrNull(json['imageId']),
        createdAt: _time(json['createdAt']),
        updatedAt: _time(json['updatedAt']),
        items: _list(json['items'], TransferPlaylistItem.fromJson),
        trackOrder: _list(json['trackOrder'], TransferTrackOrder.fromJson),
        tagIds: _ints(json['tagIds']),
      );

  Map<String, Object?> toJson() => _prune({
        'id': id,
        'name': name,
        'nameKey': nameKey,
        'parentId': parentId,
        'description': description,
        'kind': kind,
        'query': query,
        'queryLimit': queryLimit,
        'querySort': querySort,
        if (!autoUpdate) 'autoUpdate': autoUpdate,
        if (displaySort != 'added') 'displaySort': displaySort,
        if (sortDescending) 'sortDescending': sortDescending,
        if (groupBy != 'none') 'groupBy': groupBy,
        if (isPinned) 'isPinned': isPinned,
        if (sortOrder != 0) 'sortOrder': sortOrder,
        'imageId': imageId,
        'createdAt': _iso(createdAt),
        'updatedAt': _iso(updatedAt),
        'items': [for (final i in items) i.toJson()],
        'trackOrder': [for (final o in trackOrder) o.toJson()],
        'tagIds': tagIds,
      });
}

/// An image. Identified by its sha256, which is also its file name in the
/// artwork store -- so artwork dedupes across machines for free.
class TransferImage extends TransferEntity {
  const TransferImage({
    required super.id,
    required this.sha256,
    required this.mimeType,
    required this.byteSize,
    this.kind = 'userProvided',
    this.role = 'front',
    this.width,
    this.height,
    this.sourceDescription,

    /// File name inside the bundle's artwork folder, when the bytes travelled
    /// with it. Null means metadata only: the importer keeps the reference if
    /// it already has that image, and drops it otherwise.
    this.file,
  });

  final String sha256;
  final String mimeType;
  final int byteSize;
  final String kind;
  final String role;
  final int? width;
  final int? height;
  final String? sourceDescription;
  final String? file;

  factory TransferImage.fromJson(Map<String, Object?> json) => TransferImage(
        id: _int(json['id'], -1),
        sha256: _str(json['sha256']),
        mimeType: _str(json['mimeType'], 'image/jpeg'),
        byteSize: _int(json['byteSize']),
        kind: _str(json['kind'], 'userProvided'),
        role: _str(json['role'], 'front'),
        width: _intOrNull(json['width']),
        height: _intOrNull(json['height']),
        sourceDescription: _strOrNull(json['sourceDescription']),
        file: _strOrNull(json['file']),
      );

  Map<String, Object?> toJson() => _prune({
        'id': id,
        'sha256': sha256,
        'mimeType': mimeType,
        'byteSize': byteSize,
        'kind': kind,
        'role': role,
        'width': width,
        'height': height,
        'sourceDescription': sourceDescription,
        'file': file,
      });
}

/// A learned decision about how to split a credit string.
///
/// The highest-value thing in the whole bundle: each of these is a question
/// the app asked and a person answered.
class TransferSplitRule {
  const TransferSplitRule({
    required this.rawCredit,
    required this.rawCreditKey,
    this.isUserConfirmed = false,
    this.appliedCount = 0,
    this.parts = const [],
  });

  final String rawCredit;
  final String rawCreditKey;
  final bool isUserConfirmed;
  final int appliedCount;

  /// The resolution, with artists as bundle-local ids rather than the local
  /// row ids the database stores inside its JSON blob.
  final List<TransferCredit> parts;

  factory TransferSplitRule.fromJson(Map<String, Object?> json) =>
      TransferSplitRule(
        rawCredit: _str(json['rawCredit']),
        rawCreditKey: _str(json['rawCreditKey']),
        isUserConfirmed: _bool(json['isUserConfirmed']),
        appliedCount: _int(json['appliedCount']),
        parts: _list(json['parts'], TransferCredit.fromJson),
      );

  Map<String, Object?> toJson() => _prune({
        'rawCredit': rawCredit,
        'rawCreditKey': rawCreditKey,
        if (isUserConfirmed) 'isUserConfirmed': isUserConfirmed,
        if (appliedCount != 0) 'appliedCount': appliedCount,
        'parts': [for (final p in parts) p.toJson()],
      });
}

/// A separator token the credit splitter knows about, including whether the
/// user turned a built-in one off.
class TransferSeparator {
  const TransferSeparator({
    required this.token,
    this.kind = 'split',
    this.requiresSpaces = false,
    this.isAmbiguous = false,
    this.enabled = true,
    this.sortOrder = 0,
    this.isBuiltIn = false,
  });

  final String token;
  final String kind;
  final bool requiresSpaces;
  final bool isAmbiguous;
  final bool enabled;
  final int sortOrder;
  final bool isBuiltIn;

  factory TransferSeparator.fromJson(Map<String, Object?> json) =>
      TransferSeparator(
        token: _str(json['token']),
        kind: _str(json['kind'], 'split'),
        requiresSpaces: _bool(json['requiresSpaces']),
        isAmbiguous: _bool(json['isAmbiguous']),
        enabled: _bool(json['enabled'], true),
        sortOrder: _int(json['sortOrder']),
        isBuiltIn: _bool(json['isBuiltIn']),
      );

  Map<String, Object?> toJson() => _prune({
        'token': token,
        'kind': kind,
        if (requiresSpaces) 'requiresSpaces': requiresSpaces,
        if (isAmbiguous) 'isAmbiguous': isAmbiguous,
        if (!enabled) 'enabled': enabled,
        if (sortOrder != 0) 'sortOrder': sortOrder,
        if (isBuiltIn) 'isBuiltIn': isBuiltIn,
      });
}

// ---------------------------------------------------------------------- bundle

/// Who wrote a bundle, so a sync folder can hold one per machine and each
/// machine can tell which one is its own.
class TransferOrigin {
  const TransferOrigin({
    required this.machineId,
    required this.machineName,
    this.appVersion,
  });

  /// A random, stable id generated once per installation. Not derived from
  /// anything about the computer: a hostname changes, and hashing hardware
  /// identifiers to build a fingerprint is not something a music player
  /// should be doing.
  final String machineId;

  /// What to call this machine in the UI. The hostname, editable.
  final String machineName;
  final String? appVersion;

  factory TransferOrigin.fromJson(Map<String, Object?> json) => TransferOrigin(
        machineId: _str(json['machineId']),
        machineName: _str(json['machineName'], 'another computer'),
        appVersion: _strOrNull(json['appVersion']),
      );

  Map<String, Object?> toJson() => _prune({
        'machineId': machineId,
        'machineName': machineName,
        'appVersion': appVersion,
      });
}

/// Everything one machine knows, in portable form.
class TransferBundle {
  const TransferBundle({
    required this.origin,
    required this.exportedAt,
    this.schema = transferSchemaVersion,
    this.artists = const [],
    this.albums = const [],
    this.tracks = const [],
    this.tagCategories = const [],
    this.tags = const [],
    this.playlists = const [],
    this.images = const [],
    this.splitRules = const [],
    this.separators = const [],
  });

  final int schema;
  final TransferOrigin origin;
  final DateTime exportedAt;

  final List<TransferArtist> artists;
  final List<TransferAlbum> albums;
  final List<TransferTrack> tracks;
  final List<TransferTagCategory> tagCategories;
  final List<TransferTag> tags;
  final List<TransferPlaylist> playlists;
  final List<TransferImage> images;
  final List<TransferSplitRule> splitRules;
  final List<TransferSeparator> separators;

  /// Reads a bundle. Throws [TransferFormatException] on anything that is not
  /// one, rather than half-importing a file that happened to be JSON.
  factory TransferBundle.fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    if (kind != transferBundleKind) {
      throw const TransferFormatException(
        'That file is not a marmelade library bundle.',
      );
    }
    final schema = _int(json['schema'], 0);
    if (schema > transferSchemaVersion) {
      throw TransferFormatException(
        'That bundle was written by a newer version of marmelade '
        '(format $schema, this one reads up to $transferSchemaVersion). '
        'Update marmelade on this computer and try again.',
      );
    }

    return TransferBundle(
      schema: schema,
      origin: TransferOrigin.fromJson(
        json['origin'] is Map<String, Object?>
            ? json['origin'] as Map<String, Object?>
            : const {},
      ),
      exportedAt: _time(json['exportedAt']) ?? DateTime.utc(1970),
      artists: _list(json['artists'], TransferArtist.fromJson),
      albums: _list(json['albums'], TransferAlbum.fromJson),
      tracks: _list(json['tracks'], TransferTrack.fromJson),
      tagCategories: _list(json['tagCategories'], TransferTagCategory.fromJson),
      tags: _list(json['tags'], TransferTag.fromJson),
      playlists: _list(json['playlists'], TransferPlaylist.fromJson),
      images: _list(json['images'], TransferImage.fromJson),
      splitRules: _list(json['splitRules'], TransferSplitRule.fromJson),
      separators: _list(json['separators'], TransferSeparator.fromJson),
    );
  }

  static TransferBundle decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw TransferFormatException('That file is not valid JSON: ${error.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const TransferFormatException(
        'That file is not a marmelade library bundle.',
      );
    }
    return TransferBundle.fromJson(decoded);
  }

  Map<String, Object?> toJson() => {
        'kind': transferBundleKind,
        'schema': schema,
        'origin': origin.toJson(),
        'exportedAt': exportedAt.toUtc().toIso8601String(),
        'counts': counts,
        'artists': [for (final a in artists) a.toJson()],
        'albums': [for (final a in albums) a.toJson()],
        'tracks': [for (final t in tracks) t.toJson()],
        'tagCategories': [for (final c in tagCategories) c.toJson()],
        'tags': [for (final t in tags) t.toJson()],
        'playlists': [for (final p in playlists) p.toJson()],
        'images': [for (final i in images) i.toJson()],
        'splitRules': [for (final r in splitRules) r.toJson()],
        'separators': [for (final s in separators) s.toJson()],
      };

  /// Written into the file for a person reading it, and used by the UI to
  /// describe a bundle before importing it.
  Map<String, Object?> get counts => {
        'artists': artists.length,
        'albums': albums.length,
        'tracks': tracks.length,
        'tags': tags.length,
        'playlists': playlists.length,
        'images': images.length,
        'splitRules': splitRules.length,
      };

  /// Indented, because this file is meant to be readable when something has
  /// gone wrong. It compresses well in a cloud folder either way.
  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  bool get isEmpty =>
      artists.isEmpty &&
      albums.isEmpty &&
      tracks.isEmpty &&
      tags.isEmpty &&
      playlists.isEmpty;
}

/// A bundle that cannot be read, with a message meant for the person who
/// picked the file.
class TransferFormatException implements Exception {
  const TransferFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}
