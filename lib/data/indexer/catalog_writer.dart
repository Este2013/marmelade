import 'package:drift/drift.dart';

import '../../domain/credits/credit_resolver.dart';
import '../../domain/credits/credit_tokenizer.dart';
import '../../domain/text/normalize.dart';
import '../db/database.dart';

/// The result of an upsert: the row id, and whether it had to be created.
///
/// Callers need the distinction to report honest counts. Asking the resolver
/// whether an artist was new does not work, because its vocabulary is a
/// snapshot taken before the write pass, so it keeps calling artists new that
/// were created moments earlier in the same run.
typedef Upserted = ({int id, bool created});

/// Maps a tokenizer segment role onto the stored credit role.
CreditRole creditRoleFor(SegmentRole role) => switch (role) {
      SegmentRole.main => CreditRole.mainArtist,
      SegmentRole.featured => CreditRole.featured,
      SegmentRole.remixer => CreditRole.remixer,
    };

/// Writes artists, albums, tracks, credits and tags, keeping identity stable.
///
/// Every method here is an upsert keyed on a normalised name, so re-running a
/// scan is idempotent: it must never create a second "Camellia" because a file
/// spelled it differently.
///
/// User-authored data is never overwritten. Rows flagged `isVerified`, and
/// credits or tags whose source is [DataSource.user], survive a rescan
/// untouched - which is what makes it safe to let people correct the library
/// by hand.
class CatalogWriter {
  CatalogWriter(this.db);

  final MarmeladeDatabase db;

  // ------------------------------------------------------------------ artists

  /// Finds or creates an artist by name, and registers [aliases].
  ///
  /// [candidateIds] comes from the resolver: exactly one means the artist is
  /// already known, several means the name is ambiguous and the first is used
  /// while the ambiguity is recorded for review.
  Future<Upserted> upsertArtist(
    String name, {
    List<int> candidateIds = const [],
    List<String> aliases = const [],
    ArtistKind kind = ArtistKind.unknown,
    bool neverSplit = false,
  }) async {
    if (candidateIds.isNotEmpty) {
      final id = candidateIds.first;
      aliasesAdded += await _addAliases(id, aliases);
      return (id: id, created: false);
    }

    final key = normalizeKey(name);
    final existing = await (db.select(db.artists)
          ..where((t) => t.nameKey.equals(key))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) {
      aliasesAdded += await _addAliases(existing.id, aliases);
      return (id: existing.id, created: false);
    }

    final id = await db.into(db.artists).insert(
          ArtistsCompanion.insert(
            name: name,
            nameKey: key,
            sortName: Value(sortKeyFor(name)),
            kind: Value(kind),
            neverSplit: Value(neverSplit),
          ),
        );
    aliasesAdded += await _addAliases(id, aliases);
    return (id: id, created: true);
  }

  /// How many aliases this writer has actually inserted.
  ///
  /// Accumulated here rather than returned, because aliases are added as a side
  /// effect of several operations and threading the count back through each of
  /// them would clutter every signature.
  int aliasesAdded = 0;

  Future<int> _addAliases(int artistId, List<String> aliases) async {
    var added = 0;
    for (final alias in aliases) {
      if (await addArtistAlias(artistId, alias)) added++;
    }
    return added;
  }

  /// Adds an alias, choosing its kind from the script it is written in.
  ///
  /// Ignored when the alias is the artist's own name, or already present.
  /// Returns whether a new row was written.
  Future<bool> addArtistAlias(
    int artistId,
    String alias, {
    AliasKind? kind,
    DataSource source = DataSource.inferredFromSplit,
  }) async {
    final key = normalizeKey(alias);
    if (key.isEmpty) return false;

    final artist = await (db.select(db.artists)
          ..where((t) => t.id.equals(artistId)))
        .getSingleOrNull();
    if (artist == null || artist.nameKey == key) return false;

    final already = await (db.select(db.artistAliases)
          ..where((t) => t.artistId.equals(artistId) & t.aliasKey.equals(key))
          ..limit(1))
        .getSingleOrNull();
    if (already != null) return false;

    final resolvedKind = kind ??
        (containsCjk(alias)
            ? AliasKind.nativeScript
            : containsCjk(artist.name)
                ? AliasKind.romanization
                : AliasKind.alias);

    // insertOrIgnore, not insertOnConflictUpdate: the uniqueness that matters
    // here is (artist_id, alias_key), while conflict-update resolves on the
    // primary key, so it would throw on an alias the artist already has. An
    // alias that is already present needs nothing done to it.
    await db.into(db.artistAliases).insert(
          ArtistAliasesCompanion.insert(
            artistId: artistId,
            alias: alias,
            aliasKey: key,
            kind: Value(resolvedKind),
            source: Value(source),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return true;
  }

  /// Loads every artist name and alias into a vocabulary for the resolver.
  ///
  /// One query per table rather than a lookup per credit: a scan resolves
  /// thousands of credits and must not issue thousands of round trips.
  Future<MapArtistVocabulary> loadVocabulary() async {
    final vocabulary = MapArtistVocabulary();
    for (final artist in await db.select(db.artists).get()) {
      vocabulary.add(artist.name, artist.id, neverSplit: artist.neverSplit);
    }
    for (final alias in await db.select(db.artistAliases).get()) {
      vocabulary.add(alias.alias, alias.artistId);
    }
    return vocabulary;
  }

  /// Seeds evidence with the credit strings already recorded in the library.
  ///
  /// Without this, a scan of a second folder would reason only about the files
  /// in front of it and could reach a different conclusion than the first scan.
  Future<void> seedEvidenceFromLibrary(
    MapCreditEvidence evidence,
    CreditTokenizer tokenizer,
  ) async {
    final rows = await db
        .customSelect(
          'SELECT DISTINCT credited_as FROM track_credits '
          "WHERE credited_as IS NOT NULL AND role = 'mainArtist'",
        )
        .get();
    for (final row in rows) {
      final value = row.read<String?>('credited_as');
      if (value != null && value.trim().isNotEmpty) {
        evidence.observe(value, tokenizer);
      }
    }
  }

  // ------------------------------------------------------------------- albums

  /// Finds or creates an album.
  ///
  /// Matched on the normalised title plus its album artist, so two different
  /// artists can both have a "Greatest Hits" without colliding.
  Future<Upserted> upsertAlbum({
    required String title,
    int? albumArtistId,
    int? year,
    int? month,
    int? day,
    int? totalTracks,
    int? totalDiscs,
    String? folderHint,
    bool isVariousArtists = false,
    AlbumKind kind = AlbumKind.unknown,
  }) async {
    final key = normalizeKey(title);
    final query = db.select(db.albums)
      ..where((t) => t.nameKey.equals(key))
      ..limit(1);
    if (albumArtistId != null) {
      query.where((t) => t.albumArtistId.equals(albumArtistId));
    } else {
      query.where((t) => t.albumArtistId.isNull());
    }

    final existing = await query.getSingleOrNull();
    if (existing != null) {
      // Fill in gaps without overwriting anything already known, and never
      // touch an album the user has verified.
      if (!existing.isVerified) {
        await (db.update(db.albums)..where((t) => t.id.equals(existing.id)))
            .write(AlbumsCompanion(
          releaseYear: existing.releaseYear == null && year != null
              ? Value(year)
              : const Value.absent(),
          releaseMonth: existing.releaseMonth == null && month != null
              ? Value(month)
              : const Value.absent(),
          releaseDay: existing.releaseDay == null && day != null
              ? Value(day)
              : const Value.absent(),
          totalTracks: existing.totalTracks == null && totalTracks != null
              ? Value(totalTracks)
              : const Value.absent(),
          totalDiscs: existing.totalDiscs == null && totalDiscs != null
              ? Value(totalDiscs)
              : const Value.absent(),
          folderHint: existing.folderHint == null && folderHint != null
              ? Value(folderHint)
              : const Value.absent(),
          updatedAt: Value(DateTime.now().toUtc()),
        ));
      }
      return (id: existing.id, created: false);
    }

    final id = await db.into(db.albums).insert(
          AlbumsCompanion.insert(
            title: title,
            nameKey: key,
            sortTitle: Value(sortKeyFor(title)),
            kind: Value(kind),
            albumArtistId: Value(albumArtistId),
            isVariousArtists: Value(isVariousArtists),
            releaseYear: Value(year),
            releaseMonth: Value(month),
            releaseDay: Value(day),
            totalTracks: Value(totalTracks),
            totalDiscs: Value(totalDiscs),
            folderHint: Value(folderHint),
          ),
        );
    return (id: id, created: true);
  }

  // ------------------------------------------------------------------- tracks

  /// Finds an existing track that [contentKey] or the tag identity points at.
  ///
  /// Two files holding the same song - an MP3 and a FLAC of one album track -
  /// should share one track row, so ratings and play counts are not split
  /// between formats.
  Future<int?> findExistingTrack({
    String? contentKey,
    required String title,
    int? albumId,
    int? trackNo,
    int? discNo,
  }) async {
    // Identical audio is conclusive.
    if (contentKey != null) {
      final row = await db
          .customSelect(
            'SELECT track_id FROM media_files '
            'WHERE content_key = ? AND track_id IS NOT NULL LIMIT 1',
            variables: [Variable(contentKey)],
          )
          .getSingleOrNull();
      final id = row?.read<int?>('track_id');
      if (id != null) return id;
    }

    // Otherwise, the same numbered track on the same album is the same song.
    // Requiring the album and the track number keeps this from merging
    // unrelated songs that happen to share a title.
    if (albumId != null && trackNo != null) {
      final key = normalizeKey(title);
      final query = db.select(db.tracks)
        ..where((t) =>
            t.albumId.equals(albumId) &
            t.trackNo.equals(trackNo) &
            t.nameKey.equals(key))
        ..limit(1);
      if (discNo != null) {
        query.where((t) => t.discNo.equalsNullable(discNo) | t.discNo.isNull());
      }
      final existing = await query.getSingleOrNull();
      if (existing != null) return existing.id;
    }
    return null;
  }

  /// Creates a track.
  Future<int> insertTrack({
    required String title,
    int? albumId,
    int? trackNo,
    int? discNo,
    int? durationMs,
    int? year,
    double? bpm,
    String? initialKey,
    String? comment,
    int? rating,
  }) =>
      db.into(db.tracks).insert(
            TracksCompanion.insert(
              title: title,
              nameKey: normalizeKey(title),
              sortTitle: Value(sortKeyFor(title)),
              albumId: Value(albumId),
              trackNo: Value(trackNo),
              discNo: Value(discNo),
              durationMs: Value(durationMs),
              releaseYear: Value(year),
              bpm: Value(bpm),
              initialKey: Value(initialKey),
              comment: Value(comment),
              rating: Value(rating),
            ),
          );

  /// Updates a track from freshly-read tags, leaving verified rows alone.
  Future<void> refreshTrack(
    int trackId, {
    required String title,
    int? albumId,
    int? trackNo,
    int? discNo,
    int? durationMs,
    int? year,
  }) async {
    final existing = await (db.select(db.tracks)
          ..where((t) => t.id.equals(trackId)))
        .getSingleOrNull();
    if (existing == null || existing.isVerified) return;

    await (db.update(db.tracks)..where((t) => t.id.equals(trackId)))
        .write(TracksCompanion(
      title: Value(title),
      nameKey: Value(normalizeKey(title)),
      sortTitle: Value(sortKeyFor(title)),
      albumId: albumId == null ? const Value.absent() : Value(albumId),
      trackNo: Value(trackNo),
      discNo: Value(discNo),
      durationMs: durationMs == null ? const Value.absent() : Value(durationMs),
      releaseYear: year == null ? const Value.absent() : Value(year),
      updatedAt: Value(DateTime.now().toUtc()),
    ));
  }

  // ------------------------------------------------------------------ credits

  /// Replaces the tag-derived credits of a track.
  ///
  /// Credits the user added or corrected are left in place: only rows whose
  /// source is a file or an inference are cleared, so a rescan cannot undo
  /// somebody's work.
  Future<void> replaceTrackCredits(
    int trackId,
    List<TrackCreditsCompanion> credits,
  ) async {
    await (db.delete(db.trackCredits)
          ..where((t) =>
              t.trackId.equals(trackId) &
              t.source.isNotValue(DataSource.user.name)))
        .go();

    for (final credit in credits) {
      await db
          .into(db.trackCredits)
          .insert(credit, mode: InsertMode.insertOrIgnore);
    }
  }

  /// Records an album-level credit.
  Future<void> upsertAlbumCredit({
    required int albumId,
    required int artistId,
    CreditRole role = CreditRole.mainArtist,
    String? creditedAs,
    int sortOrder = 0,
  }) =>
      db.into(db.albumCredits).insert(
            AlbumCreditsCompanion.insert(
              albumId: albumId,
              artistId: artistId,
              role: Value(role),
              creditedAs: Value(creditedAs),
              sortOrder: Value(sortOrder),
            ),
            mode: InsertMode.insertOrIgnore,
          );

  // --------------------------------------------------------------------- tags

  /// Finds or creates a tag category by slug.
  Future<int> upsertTagCategory(String slug, String displayName) async {
    final existing = await (db.select(db.tagCategories)
          ..where((t) => t.slug.equals(slug)))
        .getSingleOrNull();
    if (existing != null) return existing.id;
    return db.into(db.tagCategories).insert(
          TagCategoriesCompanion.insert(name: displayName, slug: slug),
        );
  }

  /// Finds or creates a tag within a category.
  Future<int> upsertTag({
    required String name,
    int? categoryId,
  }) async {
    final key = normalizeKey(name);
    final query = db.select(db.tags)
      ..where((t) => t.nameKey.equals(key))
      ..limit(1);
    if (categoryId != null) {
      query.where((t) => t.categoryId.equals(categoryId));
    } else {
      query.where((t) => t.categoryId.isNull());
    }
    final existing = await query.getSingleOrNull();
    if (existing != null) return existing.id;

    return db.into(db.tags).insert(
          TagsCompanion.insert(
            name: name,
            nameKey: key,
            categoryId: Value(categoryId),
          ),
        );
  }

  /// Attaches tags from file metadata to a track.
  ///
  /// Replaces only tags that came from files, so hand-applied tags survive.
  Future<void> replaceMetadataTags(int trackId, List<int> tagIds) async {
    await (db.delete(db.trackTags)
          ..where((t) =>
              t.trackId.equals(trackId) &
              t.source.equals(DataSource.fileMetadata.name)))
        .go();

    for (final tagId in tagIds) {
      await db.into(db.trackTags).insert(
            TrackTagsCompanion.insert(
              trackId: trackId,
              tagId: tagId,
              source: const Value(DataSource.fileMetadata),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }

  // ------------------------------------------------------------------- images

  /// Records a stored image, reusing the row when the digest is already known.
  Future<int> upsertImage({
    required String sha256,
    required String storedPath,
    required String mimeType,
    required int byteSize,
    int? width,
    int? height,
    required ImageKind kind,
    ImageRole role = ImageRole.front,
    int? sourceFileId,
    String? sourceDescription,
  }) async {
    final existing = await (db.select(db.images)
          ..where((t) => t.sha256.equals(sha256)))
        .getSingleOrNull();
    if (existing != null) return existing.id;

    return db.into(db.images).insert(
          ImagesCompanion.insert(
            sha256: sha256,
            kind: kind,
            role: Value(role),
            mimeType: mimeType,
            byteSize: byteSize,
            width: Value(width),
            height: Value(height),
            storedPath: storedPath,
            sourceFileId: Value(sourceFileId),
            sourceDescription: Value(sourceDescription),
          ),
        );
  }

  /// Sets a track's artwork unless it already has some.
  Future<void> setTrackImageIfAbsent(int trackId, int imageId) =>
      (db.update(db.tracks)
            ..where((t) => t.id.equals(trackId) & t.imageId.isNull()))
          .write(TracksCompanion(imageId: Value(imageId)));

  /// Sets an album's artwork unless it already has some.
  Future<void> setAlbumImageIfAbsent(int albumId, int imageId) =>
      (db.update(db.albums)
            ..where((t) => t.id.equals(albumId) & t.imageId.isNull()))
          .write(AlbumsCompanion(imageId: Value(imageId)));

  /// Sets an artist's portrait unless they already have one.
  Future<void> setArtistImageIfAbsent(int artistId, int imageId) =>
      (db.update(db.artists)
            ..where((t) => t.id.equals(artistId) & t.imageId.isNull()))
          .write(ArtistsCompanion(imageId: Value(imageId)));

  // ------------------------------------------------------------------ review

  /// Parks a credit the resolver was not confident enough to apply.
  Future<void> recordPendingCredit({
    required int trackId,
    required String rawCredit,
    required String suggestionsJson,
  }) async {
    final existing = await (db.select(db.pendingCredits)
          ..where((t) =>
              t.trackId.equals(trackId) &
              t.rawCredit.equals(rawCredit) &
              t.resolvedAt.isNull()))
        .getSingleOrNull();
    if (existing != null) return;

    await db.into(db.pendingCredits).insert(
          PendingCreditsCompanion.insert(
            trackId: trackId,
            rawCredit: rawCredit,
            suggestions: suggestionsJson,
          ),
        );
  }
}
