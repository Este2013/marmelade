import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../core/logging/app_log.dart';
import '../../domain/text/normalize.dart';
import '../../services/art/art_store.dart';
import '../db/database.dart';
import '../indexer/search_indexer.dart';
import 'transfer_bundle.dart';
import 'transfer_report.dart';

/// Merges another machine's bundle into this library.
///
/// The hard part is not copying fields across; it is that both computers were
/// used. A bundle exported at work on Tuesday knows nothing about the tag
/// added at home on Wednesday, and there is no reliable way to tell which
/// came first: favourite toggles and play counters are written with raw SQL
/// that never touches `updated_at`, so a last-writer-wins merge keyed on
/// timestamps would silently eat whichever side it liked less.
///
/// So this is deliberately **not** a sync in the "make both sides identical"
/// sense. It only ever adds:
///
///   * **Collections are unioned.** Tags, credits, aliases, links,
///     memberships and playlist entries from the bundle are added if absent
///     and never removed, because a bundle cannot distinguish "deleted over
///     there" from "added over here since the export".
///   * **Scalars fill blanks.** A rating, a sort name, a description or a
///     release year is written only where this machine has none. Where both
///     sides have a different value, this machine wins and the disagreement
///     is counted in [TransferReport.conflictsKept] -- so "nothing changed"
///     is never silent.
///   * **Flags are additive.** `isFavorite`, `isVerified` and `neverSplit`
///     are decisions someone made; a yes from either machine is kept, since
///     a plain `false` is indistinguishable from "never asked".
///   * **Counters take the larger side.** Play and skip counts are counters
///     and neither history is wrong.
///
/// [TransferConflictPolicy.preferTheirs] flips the scalar rules for a run
/// where the bundle is known to be the better copy. Nothing ever deletes.
///
/// A track that is not on this machine is skipped and reported, not created:
/// a track row with no file behind it is a ghost that shows up in every list
/// and plays nothing. Copy the audio across and import again -- which is
/// exactly what the bundle's opt-in audio folder is for.
class LibraryImporter {
  LibraryImporter({required this.db, this.artStore, this.searchIndexer});

  final MarmeladeDatabase db;

  /// Needed to bring artwork files in. Without it, image references are only
  /// honoured where this machine already has the same picture.
  final ArtStore? artStore;

  /// Rebuilt at the end, since new artists, albums and tags are invisible to
  /// search until it is.
  final SearchIndexer? searchIndexer;

  /// Applies [bundle].
  ///
  /// With [preview] the whole run happens inside a transaction that is rolled
  /// back, so the returned report describes exactly what *would* change
  /// without touching anything. That is the same code path as a real import
  /// rather than a second implementation of the estimate, which is the only
  /// way a preview can be trusted.
  Future<TransferReport> import(
    TransferBundle bundle, {
    Directory? bundleDirectory,
    TransferImportOptions options = const TransferImportOptions(),
    bool preview = false,
    void Function(TransferProgress)? onProgress,
  }) async {
    final started = DateTime.now();
    final report = TransferReport(
      origin: bundle.origin.machineName,
      exportedAt: bundle.exportedAt,
      preview: preview,
    );

    final run = _ImportRun(
      db: db,
      bundle: bundle,
      options: options,
      report: report,
      onProgress: onProgress,
    );

    // Artwork lands in the store before the transaction opens. The store is
    // content-addressed and idempotent, so a file written for an import that
    // then rolls back is at worst an orphan the artwork pruner will collect
    // -- whereas holding a transaction open across file copies would block
    // every other write for the length of the copy.
    if (options.importArtwork && !preview) {
      await run.stageArtwork(artStore: artStore, directory: bundleDirectory);
    }

    try {
      await db.transaction(() async {
        await run.apply();
        if (preview) throw const _PreviewRollback();
      });
    } on _PreviewRollback {
      // Expected: the transaction rolled back and the report survived.
    }

    if (!preview && report.changeCount > 0 && searchIndexer != null) {
      onProgress?.call(
        const TransferProgress(phase: TransferPhase.rebuildingIndex),
      );
      try {
        await searchIndexer!.rebuildAll();
      } catch (error, stack) {
        // A stale search index is a bad day, not a lost import: the rows are
        // committed either way, and the index can be rebuilt from settings.
        AppLog.instance.error(
          'search index rebuild after an import failed',
          tag: 'transfer',
          error: error,
          stack: stack,
        );
        report.problems.add(
          'The library was updated, but the search index could not be '
          'rebuilt. Rebuild it from Settings.',
        );
      }
    }

    onProgress?.call(const TransferProgress(phase: TransferPhase.done));

    AppLog.instance.info(
      preview ? 'import previewed' : 'import applied',
      tag: 'transfer',
      fields: {
        'from': bundle.origin.machineName,
        'changes': report.changeCount,
        'tracksMatched': report.tracksMatched,
        'tracksMissing': report.missingTracks.length,
        'conflictsKept': report.conflictsKept,
        'ms': DateTime.now().difference(started).inMilliseconds,
      },
    );

    return report;
  }
}

/// Thrown to roll back a preview run.
class _PreviewRollback implements Exception {
  const _PreviewRollback();
}

/// One import, and the id maps it builds as it goes.
///
/// A class rather than a pile of parameters because every step needs the
/// previous step's mapping: an album needs its artist, a track needs its
/// album, a playlist needs its tracks.
class _ImportRun {
  _ImportRun({
    required this.db,
    required this.bundle,
    required this.options,
    required this.report,
    this.onProgress,
  });

  final MarmeladeDatabase db;
  final TransferBundle bundle;
  final TransferImportOptions options;
  final TransferReport report;
  final void Function(TransferProgress)? onProgress;

  /// Bundle-local id to local row id, per entity kind.
  final _artists = <int, int>{};
  final _albums = <int, int>{};
  final _tracks = <int, int>{};
  final _tags = <int, int>{};
  final _categories = <int, int>{};
  final _playlists = <int, int>{};
  final _images = <int, int>{};

  /// Artwork copied into the store before the transaction, by bundle image id.
  final _staged = <int, StoredImage>{};

  bool get _preferTheirs =>
      options.conflicts == TransferConflictPolicy.preferTheirs;

  // ------------------------------------------------------------------ artwork

  /// Copies the bundle's artwork into this machine's store.
  ///
  /// Runs before the transaction; see [LibraryImporter.import]. Images the
  /// store already holds cost nothing, because the file name is the digest.
  Future<void> stageArtwork({
    required ArtStore? artStore,
    required Directory? directory,
  }) async {
    if (artStore == null || directory == null) return;
    final dir = Directory(p.join(directory.path, transferArtworkDirName));
    if (!await dir.exists()) return;

    var done = 0;
    for (final image in bundle.images) {
      done += 1;
      final name = image.file;
      if (name == null) continue;
      onProgress?.call(TransferProgress(
        phase: TransferPhase.copyingArtwork,
        completed: done,
        total: bundle.images.length,
      ));

      final source = File(p.join(dir.path, name));
      try {
        if (!await source.exists()) continue;
        final stored = await artStore.putFile(source);
        if (stored != null) _staged[image.id] = stored;
      } catch (error) {
        AppLog.instance.warn(
          'could not read artwork out of a bundle',
          tag: 'transfer',
          fields: {'file': name, 'error': '$error'},
        );
      }
    }
  }

  // -------------------------------------------------------------------- apply

  Future<void> apply() async {
    onProgress?.call(const TransferProgress(phase: TransferPhase.merging));

    await _applyImages();
    await _applyTagCategories();
    await _applyTags();
    await _applyArtists();
    await _applyAlbums();
    await _applyTracks();
    if (options.importPlaylists) await _applyPlaylists();
    await _applySplitRules();
    await _applySeparators();
  }

  // ------------------------------------------------------------------- images

  Future<void> _applyImages() async {
    if (bundle.images.isEmpty) return;

    final existing = {
      for (final row in await db
          .customSelect('SELECT id, sha256 FROM images', readsFrom: {db.images})
          .get())
        row.read<String>('sha256'): row.read<int>('id'),
    };

    for (final image in bundle.images) {
      final local = existing[image.sha256];
      if (local != null) {
        _images[image.id] = local;
        continue;
      }

      // No row here. Only worth creating one if the bytes actually arrived:
      // a row pointing at a file this machine does not have would render as
      // a broken picture everywhere it is referenced.
      final stored = _staged[image.id];
      if (stored == null) continue;

      final id = await db.into(db.images).insert(ImagesCompanion.insert(
            sha256: stored.sha256,
            kind: _enumOf(ImageKind.values, image.kind, ImageKind.userProvided),
            role: Value(_enumOf(ImageRole.values, image.role, ImageRole.front)),
            mimeType: stored.mimeType,
            byteSize: stored.byteSize,
            storedPath: stored.storedPath,
            width: Value(stored.width ?? image.width),
            height: Value(stored.height ?? image.height),
            sourceDescription: Value(image.sourceDescription),
          ));
      _images[image.id] = id;
      existing[stored.sha256] = id;
      report.imagesAdded += 1;
    }
  }

  // --------------------------------------------------------------------- tags

  Future<void> _applyTagCategories() async {
    final rows = await db
        .customSelect(
          'SELECT id, slug, name FROM tag_categories',
          readsFrom: {db.tagCategories},
        )
        .get();
    final bySlug = {
      for (final row in rows) row.read<String>('slug'): row.read<int>('id'),
    };
    final byName = {
      for (final row in rows)
        normalizeKey(row.read<String>('name')): row.read<int>('id'),
    };

    for (final category in bundle.tagCategories) {
      final slug = category.slug;
      final local =
          (slug == null ? null : bySlug[slug]) ?? byName[normalizeKey(category.name)];
      if (local != null) {
        _categories[category.id] = local;
        continue;
      }
      // A category is cheap and carries the colour and icon a person chose,
      // so an unknown one is created rather than folded into another.
      final id = await db.into(db.tagCategories).insert(
            TagCategoriesCompanion.insert(
              name: category.name,
              slug: slug ?? normalizeKey(category.name).replaceAll(' ', '-'),
              description: Value(category.description),
              color: Value(category.color),
              icon: Value(category.icon),
              isSystem: Value(category.isSystem),
              allowMultiple: Value(category.allowMultiple),
              sortOrder: Value(category.sortOrder),
            ),
          );
      _categories[category.id] = id;
      if (slug != null) bySlug[slug] = id;
    }
  }

  Future<void> _applyTags() async {
    final rows = await db
        .customSelect(
          'SELECT id, category_id, name_key, description, color, image_id, '
          'parent_tag_id FROM tags',
          readsFrom: {db.tags},
        )
        .get();

    final byCategoryAndKey = <String, int>{};
    final byKey = <String, List<int>>{};
    final local = <int, QueryRow>{};
    for (final row in rows) {
      final id = row.read<int>('id');
      local[id] = row;
      final key = row.read<String>('name_key');
      byCategoryAndKey['${row.readNullable<int>('category_id') ?? ''}|$key'] = id;
      byKey.putIfAbsent(key, () => []).add(id);
    }

    for (final tag in bundle.tags) {
      final categoryId =
          tag.categoryId == null ? null : _categories[tag.categoryId];
      var match = byCategoryAndKey['${categoryId ?? ''}|${tag.nameKey}'];
      // A tag that exists here without a category, or under a different one,
      // is still the same tag as long as the name is unambiguous. Creating a
      // second "Hardcore" would be worse than attaching to the first.
      if (match == null) {
        final candidates = byKey[tag.nameKey] ?? const [];
        if (candidates.length == 1) match = candidates.first;
      }

      if (match != null) {
        _tags[tag.id] = match;
        final row = local[match]!;
        final update = TagsCompanion(
          categoryId: _fill(row.readNullable<int>('category_id'), categoryId),
          description:
              _fill(row.readNullable<String>('description'), tag.description),
          color: _fill(row.readNullable<int>('color'), tag.color),
          imageId: _fill(
            row.readNullable<int>('image_id'),
            options.importArtwork ? _images[tag.imageId] : null,
          ),
        );
        if (_hasWrites(update)) {
          await (db.update(db.tags)..where((t) => t.id.equals(match!))).write(update);
        }
      } else {
        final id = await db.into(db.tags).insert(TagsCompanion.insert(
              name: tag.name,
              nameKey: tag.nameKey,
              categoryId: Value(categoryId),
              description: Value(tag.description),
              color: Value(tag.color),
              sortOrder: Value(tag.sortOrder),
              isFavorite: Value(tag.isFavorite),
              imageId: Value(options.importArtwork ? _images[tag.imageId] : null),
            ));
        _tags[tag.id] = id;
        byCategoryAndKey['${categoryId ?? ''}|${tag.nameKey}'] = id;
        byKey.putIfAbsent(tag.nameKey, () => []).add(id);
        report.tagsCreated += 1;
      }

      for (final alias in tag.aliases) {
        report.aliasesAdded += await _insertOrIgnore(
          'INSERT OR IGNORE INTO tag_aliases (tag_id, alias, alias_key) '
          'VALUES (?1, ?2, ?3)',
          [
            Variable(_tags[tag.id]),
            Variable(alias.alias),
            Variable(normalizeKey(alias.alias)),
          ],
          {db.tagAliases},
        );
      }
    }

    // Nesting, once every tag has an id on both sides.
    for (final tag in bundle.tags) {
      final parent = tag.parentTagId == null ? null : _tags[tag.parentTagId];
      final id = _tags[tag.id];
      if (parent == null || id == null) continue;
      final row = local[id];
      if (row != null && row.readNullable<int>('parent_tag_id') != null) continue;
      await (db.update(db.tags)..where((t) => t.id.equals(id)))
          .write(TagsCompanion(parentTagId: Value(parent)));
    }
  }

  // ------------------------------------------------------------------ artists

  Future<void> _applyArtists() async {
    final rows = await db
        .customSelect(
          'SELECT id, name_key, disambiguation, sort_name, kind, description, '
          'never_split, is_verified, is_favorite, image_id FROM artists',
          readsFrom: {db.artists},
        )
        .get();

    final exact = <String, int>{};
    final byKey = <String, List<int>>{};
    final local = <int, QueryRow>{};
    for (final row in rows) {
      final id = row.read<int>('id');
      local[id] = row;
      final key = row.read<String>('name_key');
      exact['$key|${row.readNullable<String>('disambiguation') ?? ''}'] = id;
      byKey.putIfAbsent(key, () => []).add(id);
    }

    for (final artist in bundle.artists) {
      var match = exact['${artist.nameKey}|${artist.disambiguation ?? ''}'];
      if (match == null && artist.disambiguation == null) {
        final candidates = byKey[artist.nameKey] ?? const [];
        // Only when there is no doubt. Two artists sharing a name are
        // exactly the case disambiguation exists for, and guessing between
        // them would attach someone's credits to the wrong person.
        if (candidates.length == 1) match = candidates.first;
      }

      if (match != null) {
        _artists[artist.id] = match;
        await _mergeArtist(match, local[match]!, artist);
      } else {
        final id = await db.into(db.artists).insert(ArtistsCompanion.insert(
              name: artist.name,
              nameKey: artist.nameKey,
              disambiguation: Value(artist.disambiguation),
              sortName: Value(artist.sortName),
              kind: Value(_enumOf(ArtistKind.values, artist.kind, ArtistKind.unknown)),
              description: Value(artist.description),
              neverSplit: Value(artist.neverSplit),
              isVerified: Value(artist.isVerified),
              isFavorite: Value(artist.isFavorite),
              imageId: Value(
                options.importArtwork ? _images[artist.imageId] : null,
              ),
            ));
        _artists[artist.id] = id;
        exact['${artist.nameKey}|${artist.disambiguation ?? ''}'] = id;
        byKey.putIfAbsent(artist.nameKey, () => []).add(id);
        report.artistsCreated += 1;
      }

      final localId = _artists[artist.id]!;
      for (final alias in artist.aliases) {
        report.aliasesAdded += await _insertOrIgnore(
          'INSERT OR IGNORE INTO artist_aliases '
          '(artist_id, alias, alias_key, kind, locale, source, created_at) '
          'VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)',
          [
            Variable(localId),
            Variable(alias.alias),
            Variable(normalizeKey(alias.alias)),
            Variable(alias.kind),
            Variable(alias.locale),
            Variable(alias.source),
            Variable(_seconds(DateTime.now())),
          ],
          {db.artistAliases},
        );
      }

      // Links have no unique key of their own, so the URL is the identity:
      // the same link added on both machines must not become two rows.
      final existingLinks = {
        for (final row in await db
            .customSelect(
              'SELECT url FROM artist_links WHERE artist_id = ?1',
              variables: [Variable(localId)],
              readsFrom: {db.artistLinks},
            )
            .get())
          row.read<String>('url').trim().toLowerCase(),
      };
      for (final link in artist.links) {
        if (!existingLinks.add(link.url.trim().toLowerCase())) continue;
        await db.into(db.artistLinks).insert(ArtistLinksCompanion.insert(
              artistId: localId,
              url: link.url,
              label: Value(link.label),
              kind: Value(_enumOf(LinkKind.values, link.kind, LinkKind.other)),
              sortOrder: Value(link.sortOrder),
            ));
        report.linksAdded += 1;
      }
    }

    // Memberships once every artist on both sides has an id.
    for (final artist in bundle.artists) {
      final groupId = _artists[artist.id];
      if (groupId == null) continue;
      for (final member in artist.members) {
        final memberId = _artists[member.memberId];
        if (memberId == null) continue;
        report.membershipsAdded += await _insertOrIgnore(
          'INSERT OR IGNORE INTO artist_memberships '
          '(group_id, member_id, role, from_year, to_year, sort_order) '
          'VALUES (?1, ?2, ?3, ?4, ?5, ?6)',
          [
            Variable(groupId),
            Variable(memberId),
            Variable(member.role),
            Variable(member.fromYear),
            Variable(member.toYear),
            Variable(member.sortOrder),
          ],
          {db.artistMemberships},
        );
      }
      for (final tagId in artist.tagIds) {
        final localTag = _tags[tagId];
        if (localTag == null) continue;
        report.tagLinksAdded += await _tagLink('artist_tags', 'artist_id', groupId, localTag);
      }
    }
  }

  Future<void> _mergeArtist(int id, QueryRow row, TransferArtist artist) async {
    final update = ArtistsCompanion(
      sortName: _fill(row.readNullable<String>('sort_name'), artist.sortName),
      description:
          _fill(row.readNullable<String>('description'), artist.description),
      disambiguation: _fill(
        row.readNullable<String>('disambiguation'),
        artist.disambiguation,
      ),
      kind: () {
        final mine = _enumOf(ArtistKind.values, row.read<String>('kind'), ArtistKind.unknown);
        final theirs = _enumOf(ArtistKind.values, artist.kind, ArtistKind.unknown);
        // "unknown" is the scan's way of saying it could not tell, so
        // anything definite beats it regardless of policy.
        if (theirs == ArtistKind.unknown || theirs == mine) {
          return const Value<ArtistKind>.absent();
        }
        if (mine == ArtistKind.unknown) return Value(theirs);
        return _preferTheirs ? Value(theirs) : const Value<ArtistKind>.absent();
      }(),
      neverSplit: _flag(row.read<int>('never_split') == 1, artist.neverSplit),
      isVerified: _flag(row.read<int>('is_verified') == 1, artist.isVerified),
      isFavorite: _flag(row.read<int>('is_favorite') == 1, artist.isFavorite),
      imageId: _fill(
        row.readNullable<int>('image_id'),
        options.importArtwork ? _images[artist.imageId] : null,
      ),
    );
    if (!_hasWrites(update)) return;

    await (db.update(db.artists)..where((t) => t.id.equals(id))).write(
      update.copyWith(updatedAt: Value(DateTime.now().toUtc())),
    );
    report.artistsUpdated += 1;
  }

  // ------------------------------------------------------------------- albums

  Future<void> _applyAlbums() async {
    final rows = await db
        .customSelect(
          'SELECT id, name_key, album_artist_id, release_year, sort_title, '
          'kind, description, label, catalog_number, total_tracks, '
          'total_discs, is_various_artists, is_verified, is_favorite, image_id '
          'FROM albums',
          readsFrom: {db.albums},
        )
        .get();

    final exact = <String, int>{};
    final byKeyAndArtist = <String, int>{};
    final byKey = <String, List<int>>{};
    final local = <int, QueryRow>{};
    for (final row in rows) {
      final id = row.read<int>('id');
      local[id] = row;
      final key = row.read<String>('name_key');
      final artist = row.readNullable<int>('album_artist_id') ?? '';
      final year = row.readNullable<int>('release_year') ?? '';
      exact['$key|$artist|$year'] = id;
      byKeyAndArtist['$key|$artist'] = id;
      byKey.putIfAbsent(key, () => []).add(id);
    }

    for (final album in bundle.albums) {
      final artistId =
          album.albumArtistId == null ? null : _artists[album.albumArtistId];
      var match = exact[
          '${album.nameKey}|${artistId ?? ''}|${album.releaseYear ?? ''}'];
      match ??= byKeyAndArtist['${album.nameKey}|${artistId ?? ''}'];
      if (match == null) {
        final candidates = byKey[album.nameKey] ?? const [];
        if (candidates.length == 1) match = candidates.first;
      }

      if (match != null) {
        _albums[album.id] = match;
        await _mergeAlbum(match, local[match]!, album, artistId);
      } else {
        final id = await db.into(db.albums).insert(AlbumsCompanion.insert(
              title: album.title,
              nameKey: album.nameKey,
              sortTitle: Value(album.sortTitle),
              kind: Value(_enumOf(AlbumKind.values, album.kind, AlbumKind.unknown)),
              releaseYear: Value(album.releaseYear),
              releaseMonth: Value(album.releaseMonth),
              releaseDay: Value(album.releaseDay),
              albumArtistId: Value(artistId),
              isVariousArtists: Value(album.isVariousArtists),
              totalTracks: Value(album.totalTracks),
              totalDiscs: Value(album.totalDiscs),
              description: Value(album.description),
              label: Value(album.label),
              catalogNumber: Value(album.catalogNumber),
              isVerified: Value(album.isVerified),
              isFavorite: Value(album.isFavorite),
              imageId: Value(
                options.importArtwork ? _images[album.imageId] : null,
              ),
            ));
        _albums[album.id] = id;
        exact['${album.nameKey}|${artistId ?? ''}|${album.releaseYear ?? ''}'] = id;
        byKey.putIfAbsent(album.nameKey, () => []).add(id);
        report.albumsCreated += 1;
      }

      final localId = _albums[album.id]!;
      for (final alias in album.aliases) {
        report.aliasesAdded += await _insertOrIgnore(
          'INSERT OR IGNORE INTO album_aliases '
          '(album_id, alias, alias_key, kind, locale, source) '
          'VALUES (?1, ?2, ?3, ?4, ?5, ?6)',
          [
            Variable(localId),
            Variable(alias.alias),
            Variable(normalizeKey(alias.alias)),
            Variable(alias.kind),
            Variable(alias.locale),
            Variable(alias.source),
          ],
          {db.albumAliases},
        );
      }
      for (final credit in album.credits) {
        final artist = _artists[credit.artistId];
        if (artist == null) continue;
        report.creditsAdded += await _insertOrIgnore(
          'INSERT OR IGNORE INTO album_credits '
          '(album_id, artist_id, role, sort_order, credited_as, source) '
          'VALUES (?1, ?2, ?3, ?4, ?5, ?6)',
          [
            Variable(localId),
            Variable(artist),
            Variable(credit.role),
            Variable(credit.sortOrder),
            Variable(credit.creditedAs),
            Variable(credit.source),
          ],
          {db.albumCredits},
        );
      }
      for (final tagId in album.tagIds) {
        final localTag = _tags[tagId];
        if (localTag == null) continue;
        report.tagLinksAdded +=
            await _tagLink('album_tags', 'album_id', localId, localTag);
      }
    }
  }

  Future<void> _mergeAlbum(
    int id,
    QueryRow row,
    TransferAlbum album,
    int? artistId,
  ) async {
    final update = AlbumsCompanion(
      sortTitle: _fill(row.readNullable<String>('sort_title'), album.sortTitle),
      description:
          _fill(row.readNullable<String>('description'), album.description),
      label: _fill(row.readNullable<String>('label'), album.label),
      catalogNumber:
          _fill(row.readNullable<String>('catalog_number'), album.catalogNumber),
      releaseYear:
          _fill(row.readNullable<int>('release_year'), album.releaseYear),
      totalTracks:
          _fill(row.readNullable<int>('total_tracks'), album.totalTracks),
      totalDiscs: _fill(row.readNullable<int>('total_discs'), album.totalDiscs),
      albumArtistId: _fill(row.readNullable<int>('album_artist_id'), artistId),
      kind: () {
        final mine =
            _enumOf(AlbumKind.values, row.read<String>('kind'), AlbumKind.unknown);
        final theirs = _enumOf(AlbumKind.values, album.kind, AlbumKind.unknown);
        if (theirs == AlbumKind.unknown || theirs == mine) {
          return const Value<AlbumKind>.absent();
        }
        if (mine == AlbumKind.unknown) return Value(theirs);
        return _preferTheirs ? Value(theirs) : const Value<AlbumKind>.absent();
      }(),
      isVariousArtists: _flag(
        row.read<int>('is_various_artists') == 1,
        album.isVariousArtists,
      ),
      isVerified: _flag(row.read<int>('is_verified') == 1, album.isVerified),
      isFavorite: _flag(row.read<int>('is_favorite') == 1, album.isFavorite),
      imageId: _fill(
        row.readNullable<int>('image_id'),
        options.importArtwork ? _images[album.imageId] : null,
      ),
    );
    if (!_hasWrites(update)) return;

    await (db.update(db.albums)..where((t) => t.id.equals(id))).write(
      update.copyWith(updatedAt: Value(DateTime.now().toUtc())),
    );
    report.albumsUpdated += 1;
  }

  // ------------------------------------------------------------------- tracks

  Future<void> _applyTracks() async {
    final index = await _TrackIndex.build(db, options.matching);

    var done = 0;
    for (final track in bundle.tracks) {
      done += 1;
      if (done % 64 == 0 || done == bundle.tracks.length) {
        onProgress?.call(TransferProgress(
          phase: TransferPhase.matchingTracks,
          completed: done,
          total: bundle.tracks.length,
          detail: track.title,
        ));
      }

      final albumId = track.albumId == null ? null : _albums[track.albumId];
      final match = index.find(track, albumId);
      if (match == null) {
        report.missingTracks.add(TransferMissingTrack(
          title: track.title,
          artist: _creditName(track),
          album: track.albumId == null
              ? null
              : bundle.albums
                  .where((a) => a.id == track.albumId)
                  .map((a) => a.title)
                  .firstOrNull,
        ));
        continue;
      }

      _tracks[track.id] = match;
      report.tracksMatched += 1;
      await _mergeTrack(match, index.rowFor(match), track, albumId);
    }
  }

  Future<void> _mergeTrack(
    int id,
    QueryRow row,
    TransferTrack track,
    int? albumId,
  ) async {
    var changed = false;

    final update = TracksCompanion(
      title: _preferTheirs && track.title.isNotEmpty &&
              track.title != row.read<String>('title')
          ? Value(track.title)
          : const Value.absent(),
      nameKey: _preferTheirs && track.title.isNotEmpty &&
              track.title != row.read<String>('title')
          ? Value(normalizeKey(track.title))
          : const Value.absent(),
      sortTitle: _fill(row.readNullable<String>('sort_title'), track.sortTitle),
      albumId: _fill(row.readNullable<int>('album_id'), albumId),
      trackNo: _fill(row.readNullable<int>('track_no'), track.trackNo),
      discNo: _fill(row.readNullable<int>('disc_no'), track.discNo),
      releaseYear:
          _fill(row.readNullable<int>('release_year'), track.releaseYear),
      bpm: _fill(row.readNullable<double>('bpm'), track.bpm),
      initialKey:
          _fill(row.readNullable<String>('initial_key'), track.initialKey),
      comment: _fill(row.readNullable<String>('comment'), track.comment),
      notes: _fill(row.readNullable<String>('notes'), track.notes),
      rating: _fill(row.readNullable<int>('rating'), track.rating),
      isFavorite: _flag(row.read<int>('is_favorite') == 1, track.isFavorite),
      isVerified: _flag(row.read<int>('is_verified') == 1, track.isVerified),
      // Counters, so the larger side wins whatever the policy says: neither
      // machine's listening history is wrong, and adding them would count
      // the plays that happened before the two libraries diverged twice.
      playCount: options.importPlayCounts &&
              track.playCount > row.read<int>('play_count')
          ? Value(track.playCount)
          : const Value.absent(),
      skipCount: options.importPlayCounts &&
              track.skipCount > row.read<int>('skip_count')
          ? Value(track.skipCount)
          : const Value.absent(),
      lastPlayedAt: () {
        if (!options.importPlayCounts || track.lastPlayedAt == null) {
          return const Value<DateTime>.absent();
        }
        final mine = row.readNullable<DateTime>('last_played_at');
        if (mine != null && !mine.isBefore(track.lastPlayedAt!)) {
          return const Value<DateTime>.absent();
        }
        return Value(track.lastPlayedAt!);
      }(),
      imageId: _fill(
        row.readNullable<int>('image_id'),
        options.importArtwork ? _images[track.imageId] : null,
      ),
    );

    if (_hasWrites(update)) {
      await (db.update(db.tracks)..where((t) => t.id.equals(id))).write(
        update.copyWith(updatedAt: Value(DateTime.now().toUtc())),
      );
      changed = true;
    }

    // Credits. The union is by (artist, role) because that is the table's own
    // unique key -- but a local credit missing the spelling this release used
    // is still worth filling in, since `credited_as` is the whole point of
    // the credit model.
    final existingCredits = {
      for (final credit in await db
          .customSelect(
            'SELECT artist_id, role, credited_as FROM track_credits '
            'WHERE track_id = ?1',
            variables: [Variable(id)],
            readsFrom: {db.trackCredits},
          )
          .get())
        '${credit.read<int>('artist_id')}|${credit.read<String>('role')}':
            credit.readNullable<String>('credited_as'),
    };

    for (final credit in track.credits) {
      final artist = _artists[credit.artistId];
      if (artist == null) continue;
      final key = '$artist|${credit.role}';
      if (!existingCredits.containsKey(key)) {
        await db.into(db.trackCredits).insert(TrackCreditsCompanion.insert(
              trackId: id,
              artistId: artist,
              role: Value(
                _enumOf(CreditRole.values, credit.role, CreditRole.mainArtist),
              ),
              sortOrder: Value(credit.sortOrder),
              creditedAs: Value(credit.creditedAs),
              source: Value(
                _enumOf(DataSource.values, credit.source, DataSource.fileMetadata),
              ),
              confidence: Value(credit.confidence),
            ));
        existingCredits[key] = credit.creditedAs;
        report.creditsAdded += 1;
        changed = true;
      } else if (existingCredits[key] == null && credit.creditedAs != null) {
        await db.customUpdate(
          'UPDATE track_credits SET credited_as = ?1 '
          'WHERE track_id = ?2 AND artist_id = ?3 AND role = ?4',
          variables: [
            Variable(credit.creditedAs),
            Variable(id),
            Variable(artist),
            Variable(credit.role),
          ],
          updates: {db.trackCredits},
        );
        existingCredits[key] = credit.creditedAs;
        report.creditsAdded += 1;
        changed = true;
      }
    }

    for (final alias in track.aliases) {
      final added = await _insertOrIgnore(
        'INSERT OR IGNORE INTO track_aliases '
        '(track_id, alias, alias_key, kind, locale, source) '
        'VALUES (?1, ?2, ?3, ?4, ?5, ?6)',
        [
          Variable(id),
          Variable(alias.alias),
          Variable(normalizeKey(alias.alias)),
          Variable(alias.kind),
          Variable(alias.locale),
          Variable(alias.source),
        ],
        {db.trackAliases},
      );
      report.aliasesAdded += added;
      if (added > 0) changed = true;
    }

    for (final tagId in track.tagIds) {
      final localTag = _tags[tagId];
      if (localTag == null) continue;
      final added = await _tagLink('track_tags', 'track_id', id, localTag);
      report.tagLinksAdded += added;
      if (added > 0) changed = true;
    }

    // Lyrics, keyed the way the table is: one document per language.
    if (track.lyrics.isNotEmpty) {
      final existing = {
        for (final row in await db
            .customSelect(
              'SELECT language, content FROM lyrics WHERE track_id = ?1',
              variables: [Variable(id)],
              readsFrom: {db.lyrics},
            )
            .get())
          row.readNullable<String>('language') ?? '':
              row.readNullable<String>('content'),
      };
      for (final lyrics in track.lyrics) {
        final key = lyrics.language ?? '';
        final mine = existing[key];
        if (mine != null && mine.trim().isNotEmpty && !_preferTheirs) {
          if (mine.trim() != lyrics.content.trim()) report.conflictsKept += 1;
          continue;
        }
        await db.into(db.lyrics).insertOnConflictUpdate(LyricsCompanion.insert(
              trackId: id,
              language: Value(lyrics.language),
              format: Value(
                _enumOf(LyricsFormat.values, lyrics.format, LyricsFormat.markdown),
              ),
              content: Value(lyrics.content),
              isSynced: Value(lyrics.isSynced),
              offsetMs: Value(lyrics.offsetMs),
              source: Value(
                _enumOf(DataSource.values, lyrics.source, DataSource.user),
              ),
              updatedAt: Value(DateTime.now().toUtc()),
            ));
        existing[key] = lyrics.content;
        report.lyricsAdded += 1;
        changed = true;
      }
    }

    if (changed) report.tracksUpdated += 1;
  }

  String? _creditName(TransferTrack track) {
    for (final credit in track.credits) {
      if (credit.role != 'mainArtist') continue;
      final artist =
          bundle.artists.where((a) => a.id == credit.artistId).firstOrNull;
      if (artist != null) return credit.creditedAs ?? artist.name;
    }
    return null;
  }

  // ---------------------------------------------------------------- playlists

  Future<void> _applyPlaylists() async {
    // Parents first, so a child can find or create the playlist it sits in.
    final ordered = [...bundle.playlists]..sort(
        (a, b) => _depthOf(a).compareTo(_depthOf(b)),
      );

    final rows = await db
        .customSelect(
          'SELECT id, name_key, parent_id, kind, query, query_limit, '
          'query_sort, description, image_id, display_sort, group_by, '
          'sort_descending, is_pinned FROM playlists',
          readsFrom: {db.playlists},
        )
        .get();
    final byParentAndKey = <String, int>{};
    final local = <int, QueryRow>{};
    for (final row in rows) {
      final id = row.read<int>('id');
      local[id] = row;
      byParentAndKey[
              '${row.readNullable<int>('parent_id') ?? ''}|${row.read<String>('name_key')}'] =
          id;
    }

    for (final playlist in ordered) {
      final parentId =
          playlist.parentId == null ? null : _playlists[playlist.parentId];
      final key = '${parentId ?? ''}|${playlist.nameKey}';
      var match = byParentAndKey[key];

      if (match == null) {
        match = await db.into(db.playlists).insert(PlaylistsCompanion.insert(
              name: playlist.name,
              nameKey: playlist.nameKey,
              parentId: Value(parentId),
              description: Value(playlist.description),
              kind: Value(
                _enumOf(PlaylistKind.values, playlist.kind, PlaylistKind.manual),
              ),
              query: Value(playlist.query),
              queryLimit: Value(playlist.queryLimit),
              querySort: Value(playlist.querySort),
              autoUpdate: Value(playlist.autoUpdate),
              displaySort: Value(
                _enumOf(PlaylistSort.values, playlist.displaySort, PlaylistSort.added),
              ),
              sortDescending: Value(playlist.sortDescending),
              groupBy: Value(
                _enumOf(PlaylistGrouping.values, playlist.groupBy, PlaylistGrouping.none),
              ),
              isPinned: Value(playlist.isPinned),
              sortOrder: Value(playlist.sortOrder),
              imageId: Value(
                options.importArtwork ? _images[playlist.imageId] : null,
              ),
            ));
        byParentAndKey[key] = match;
        report.playlistsCreated += 1;
      } else {
        final row = local[match]!;
        // A query only lands on a playlist that has none. Overwriting one
        // would silently change what a playlist means, and a playlist is
        // something a person built.
        final adoptQuery =
            row.readNullable<String>('query') == null && playlist.query != null;
        final update = PlaylistsCompanion(
          description:
              _fill(row.readNullable<String>('description'), playlist.description),
          query: adoptQuery || (_preferTheirs && playlist.query != null)
              ? Value(playlist.query)
              : const Value.absent(),
          queryLimit: adoptQuery ? Value(playlist.queryLimit) : const Value.absent(),
          querySort: adoptQuery ? Value(playlist.querySort) : const Value.absent(),
          kind: adoptQuery
              ? Value(
                  _enumOf(PlaylistKind.values, playlist.kind, PlaylistKind.manual),
                )
              : const Value.absent(),
          imageId: _fill(
            row.readNullable<int>('image_id'),
            options.importArtwork ? _images[playlist.imageId] : null,
          ),
        );
        if (row.readNullable<String>('query') != null &&
            playlist.query != null &&
            row.readNullable<String>('query') != playlist.query &&
            !_preferTheirs) {
          report.conflictsKept += 1;
        }
        if (_hasWrites(update)) {
          await (db.update(db.playlists)..where((t) => t.id.equals(match!)))
              .write(update.copyWith(updatedAt: Value(DateTime.now().toUtc())));
          report.playlistsUpdated += 1;
        }
      }

      _playlists[playlist.id] = match;
    }

    // Entries, once every playlist and track has an id here.
    for (final playlist in ordered) {
      final id = _playlists[playlist.id];
      if (id == null) continue;
      await _applyPlaylistItems(id, playlist);

      for (final tagId in playlist.tagIds) {
        final localTag = _tags[tagId];
        if (localTag == null) continue;
        report.tagLinksAdded +=
            await _tagLink('playlist_tags', 'playlist_id', id, localTag);
      }
    }
  }

  Future<void> _applyPlaylistItems(int id, TransferPlaylist playlist) async {
    final rows = await db
        .customSelect(
          'SELECT track_id, child_playlist_id, is_exclusion, '
          'COALESCE(MAX(position) OVER (), -1) AS top, position FROM '
          'playlist_items WHERE playlist_id = ?1',
          variables: [Variable(id)],
          readsFrom: {db.playlistItems},
        )
        .get();

    final present = <String>{};
    var top = -1;
    for (final row in rows) {
      final track = row.readNullable<int>('track_id');
      final child = row.readNullable<int>('child_playlist_id');
      final exclusion = row.read<int>('is_exclusion') == 1;
      present.add('${track ?? 'p$child'}|$exclusion');
      final position = row.read<int>('position');
      if (position > top) top = position;
    }

    for (final item in playlist.items) {
      final trackId = item.trackId == null ? null : _tracks[item.trackId];
      final childId =
          item.childPlaylistId == null ? null : _playlists[item.childPlaylistId];
      // A row must point at exactly one of the two, and an unresolved
      // reference points at neither.
      if (trackId == null && childId == null) continue;
      final key = '${trackId ?? 'p$childId'}|${item.isExclusion}';
      if (!present.add(key)) continue;

      top += 1;
      await db.into(db.playlistItems).insert(PlaylistItemsCompanion.insert(
            playlistId: id,
            trackId: Value(trackId),
            childPlaylistId: Value(trackId == null ? childId : null),
            position: top,
            isExclusion: Value(item.isExclusion),
            note: Value(item.note),
          ));
      report.playlistItemsAdded += 1;
    }

    // A hand-dragged order is all or nothing: merging two arrangements would
    // produce one neither machine asked for, so it is only taken when this
    // playlist has none.
    if (playlist.trackOrder.isEmpty) return;
    final hasOrder = await db
        .customSelect(
          'SELECT 1 FROM playlist_track_order WHERE playlist_id = ?1 LIMIT 1',
          variables: [Variable(id)],
          readsFrom: {db.playlistTrackOrder},
        )
        .getSingleOrNull();
    if (hasOrder != null) return;

    for (final entry in playlist.trackOrder) {
      final trackId = _tracks[entry.trackId];
      if (trackId == null) continue;
      await db.into(db.playlistTrackOrder).insert(
            PlaylistTrackOrderCompanion.insert(
              playlistId: id,
              trackId: trackId,
              position: entry.position,
            ),
          );
    }
  }

  int _depthOf(TransferPlaylist playlist) {
    var depth = 0;
    var current = playlist;
    final seen = <int>{current.id};
    while (current.parentId != null) {
      final parent =
          bundle.playlists.where((p) => p.id == current.parentId).firstOrNull;
      if (parent == null || !seen.add(parent.id)) break;
      current = parent;
      depth += 1;
    }
    return depth;
  }

  // ----------------------------------------------------------- learned rules

  Future<void> _applySplitRules() async {
    if (bundle.splitRules.isEmpty) return;

    final existing = {
      for (final row in await db
          .customSelect(
            'SELECT raw_credit_key FROM credit_split_rules',
            readsFrom: {db.creditSplitRules},
          )
          .get())
        row.read<String>('raw_credit_key'),
    };

    for (final rule in bundle.splitRules) {
      if (existing.contains(rule.rawCreditKey)) continue;

      // Every part has to resolve, or the rule would split a credit into
      // the wrong people -- worse than not having learned it.
      final parts = <Map<String, Object?>>[];
      var complete = true;
      for (final part in rule.parts) {
        final artist = _artists[part.artistId];
        if (artist == null) {
          complete = false;
          break;
        }
        parts.add({
          'artistId': artist,
          'role': part.role,
          if (part.creditedAs != null) 'creditedAs': part.creditedAs,
        });
      }
      if (!complete || parts.isEmpty) continue;

      await db.into(db.creditSplitRules).insert(
            CreditSplitRulesCompanion.insert(
              rawCredit: rule.rawCredit,
              rawCreditKey: rule.rawCreditKey,
              resolution: jsonEncode(parts),
              isUserConfirmed: Value(rule.isUserConfirmed),
              appliedCount: Value(rule.appliedCount),
            ),
          );
      existing.add(rule.rawCreditKey);
      report.splitRulesAdded += 1;
    }
  }

  Future<void> _applySeparators() async {
    if (bundle.separators.isEmpty) return;

    final existing = {
      for (final row in await db
          .customSelect(
            'SELECT token, enabled FROM separator_tokens',
            readsFrom: {db.separatorTokens},
          )
          .get())
        row.read<String>('token'): row.read<int>('enabled') == 1,
    };

    for (final separator in bundle.separators) {
      final mine = existing[separator.token];
      if (mine == null) {
        await db.into(db.separatorTokens).insert(
              SeparatorTokensCompanion.insert(
                token: separator.token,
                kind: Value(
                  _enumOf(SeparatorKind.values, separator.kind, SeparatorKind.split),
                ),
                requiresSpaces: Value(separator.requiresSpaces),
                isAmbiguous: Value(separator.isAmbiguous),
                enabled: Value(separator.enabled),
                sortOrder: Value(separator.sortOrder),
                isBuiltIn: Value(separator.isBuiltIn),
              ),
            );
        report.separatorsAdded += 1;
        continue;
      }
      if (mine == separator.enabled) continue;
      // Turning a separator off is a decision about this library's names, so
      // it only crosses over on an explicit "prefer theirs".
      if (!_preferTheirs) {
        report.conflictsKept += 1;
        continue;
      }
      await db.customUpdate(
        'UPDATE separator_tokens SET enabled = ?1 WHERE token = ?2',
        variables: [Variable(separator.enabled), Variable(separator.token)],
        updates: {db.separatorTokens},
      );
    }
  }

  // ------------------------------------------------------------------ helpers

  /// A scalar that is written only where this machine has nothing -- or
  /// always, under [TransferConflictPolicy.preferTheirs]. Disagreements are
  /// counted so the report can say what it left alone.
  Value<T> _fill<T extends Object>(T? mine, T? theirs) {
    if (theirs == null) return const Value.absent();
    if (mine == null) return Value(theirs);
    if (mine == theirs) return const Value.absent();
    if (_preferTheirs) return Value(theirs);
    report.conflictsKept += 1;
    return const Value.absent();
  }

  /// A flag someone set. A yes from either machine is kept, because `false`
  /// is what a row looks like when nobody was ever asked.
  Value<bool> _flag(bool mine, bool theirs) {
    if (mine == theirs) return const Value.absent();
    if (_preferTheirs) return Value(theirs);
    return theirs ? const Value(true) : const Value.absent();
  }

  static bool _hasWrites(UpdateCompanion<dynamic> companion) =>
      companion.toColumns(false).isNotEmpty;

  Future<int> _insertOrIgnore(
    String sql,
    List<Variable<Object>> variables,
    Set<TableInfo<Table, dynamic>> updates,
  ) =>
      db.customUpdate(sql, variables: variables, updates: updates);

  Future<int> _tagLink(
    String table,
    String ownerColumn,
    int ownerId,
    int tagId,
  ) =>
      db.customUpdate(
        'INSERT OR IGNORE INTO $table ($ownerColumn, tag_id, source, added_at) '
        'VALUES (?1, ?2, ?3, ?4)',
        variables: [
          Variable(ownerId),
          Variable(tagId),
          Variable(DataSource.user.name),
          Variable(_seconds(DateTime.now())),
        ],
      );

  /// Drift stores `DateTime` as Unix seconds, and hand-written SQL has to
  /// match or the value reads back as a date in 1970 -- or in the year
  /// 56,000.
  static int _seconds(DateTime time) =>
      time.toUtc().millisecondsSinceEpoch ~/ 1000;

  static T _enumOf<T extends Enum>(List<T> values, String? name, T fallback) =>
      values.where((value) => value.name == name).firstOrNull ?? fallback;
}

/// Every local track, indexed by every way a bundle might recognise it.
///
/// Built once per import: matching five thousand incoming tracks against five
/// thousand local ones by query would be twenty-five million round trips.
class _TrackIndex {
  _TrackIndex._(this._rows, this._byKey, this._byTags);

  final Map<int, QueryRow> _rows;

  /// Match key to local track id. Keys are prefixed by how they were built,
  /// so a quick key can never accidentally match a file name.
  final Map<String, int> _byKey;

  /// Title, album and track number, for the looser mode.
  final Map<String, int> _byTags;

  static Future<_TrackIndex> build(
    MarmeladeDatabase db,
    TransferMatchMode mode,
  ) async {
    final rows = await db
        .customSelect(
          'SELECT t.id AS id, t.title AS title, t.name_key AS name_key, '
          't.sort_title AS sort_title, t.album_id AS album_id, '
          't.track_no AS track_no, t.disc_no AS disc_no, '
          't.release_year AS release_year, t.bpm AS bpm, '
          't.initial_key AS initial_key, t.comment AS comment, '
          't.notes AS notes, t.rating AS rating, '
          't.is_favorite AS is_favorite, t.play_count AS play_count, '
          't.skip_count AS skip_count, t.last_played_at AS last_played_at, '
          't.is_verified AS is_verified, t.image_id AS image_id '
          'FROM tracks t',
          readsFrom: {db.tracks},
        )
        .get();

    final byId = {for (final row in rows) row.read<int>('id'): row};

    final byKey = <String, int>{};
    void offer(String key, int trackId) => byKey.putIfAbsent(key, () => trackId);

    final files = await db
        .customSelect(
          'SELECT track_id, quick_key, content_key, size_bytes, file_name, '
          'relative_path, duration_ms FROM media_files '
          'WHERE track_id IS NOT NULL',
          readsFrom: {db.mediaFiles},
        )
        .get();

    for (final file in files) {
      final trackId = file.read<int>('track_id');
      final size = file.read<int>('size_bytes');
      final name = file.read<String>('file_name').toLowerCase();
      final quick = file.readNullable<String>('quick_key');
      final content = file.readNullable<String>('content_key');
      final relative = file
          .readNullable<String>('relative_path')
          ?.replaceAll('\\', '/')
          .toLowerCase();
      final duration = file.readNullable<int>('duration_ms');

      if (content != null) offer('content:$content', trackId);
      if (quick != null) {
        offer('quick+size:$quick|$size', trackId);
        offer('quick:$quick', trackId);
      }
      if (relative != null) offer('path+size:$relative|$size', trackId);
      if (duration != null) {
        offer('name+size+len:$name|$size|${duration ~/ 1000}', trackId);
      }
      offer('name+size:$name|$size', trackId);
    }

    final byTags = <String, int>{};
    if (mode == TransferMatchMode.alsoByTags) {
      for (final row in rows) {
        final id = row.read<int>('id');
        final key = row.read<String>('name_key');
        final album = row.readNullable<int>('album_id') ?? '';
        final trackNo = row.readNullable<int>('track_no') ?? '';
        byTags.putIfAbsent('$key|$album|$trackNo', () => id);
        byTags.putIfAbsent('$key|$album', () => id);
      }
    }

    return _TrackIndex._(byId, byKey, byTags);
  }

  QueryRow rowFor(int trackId) => _rows[trackId]!;

  /// Finds the local track a bundle entry describes, cheapest and most
  /// conclusive signal first.
  ///
  /// The ladder matters: the payload fingerprint means "the same audio", a
  /// name and size mean "almost certainly the same file", and a title and
  /// album mean "the same song, possibly a different encode" -- which is why
  /// the last one is only used when asked for.
  int? find(TransferTrack track, int? localAlbumId) {
    for (final file in track.files) {
      final size = file.sizeBytes;
      final name = file.fileName.toLowerCase();
      final relative = file.relativePath?.toLowerCase();

      final candidates = <String>[
        if (file.contentKey != null) 'content:${file.contentKey}',
        if (file.quickKey != null) 'quick+size:${file.quickKey}|$size',
        if (file.quickKey != null) 'quick:${file.quickKey}',
        if (relative != null) 'path+size:$relative|$size',
        if (file.durationMs != null)
          'name+size+len:$name|$size|${file.durationMs! ~/ 1000}',
        'name+size:$name|$size',
      ];
      for (final candidate in candidates) {
        final match = _byKey[candidate];
        if (match != null) return match;
      }
    }

    if (_byTags.isEmpty) return null;
    final key = track.nameKey.isEmpty ? normalizeKey(track.title) : track.nameKey;
    return _byTags['$key|${localAlbumId ?? ''}|${track.trackNo ?? ''}'] ??
        _byTags['$key|${localAlbumId ?? ''}'];
  }
}
