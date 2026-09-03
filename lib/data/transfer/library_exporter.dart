import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../core/logging/app_log.dart';
import '../../services/art/art_store.dart';
import '../db/database.dart';
import 'transfer_bundle.dart';
import 'transfer_report.dart';

/// Writes everything hand-entered about a library into a portable bundle.
///
/// Reads only; it never touches a row. The whole thing is one pass of plain
/// SELECTs and a JSON encode, which for a five-thousand-track library is a
/// couple of megabytes -- so there is no incremental or delta mode and no
/// state to keep about what was exported when. A bundle is always the whole
/// truth as of now, which is exactly what makes it safe to import twice.
///
/// What is deliberately left out:
///
///   * `media_files` rows, library folders, and anything else describing
///     *this* computer's disk. Only the file fingerprints survive, as the
///     means of finding the same track elsewhere.
///   * Row ids, except as bundle-local references. Those are simply this
///     machine's ids: meaningless elsewhere, and remapped on import, which is
///     why export needs no translation pass of its own.
///   * The play queue, scan history, and the pending-credit review queue --
///     all transient, and the review queue rebuilds itself on the next scan.
///   * Deletions. A bundle says what exists, never what was removed; see
///     `LibraryImporter` for why.
class LibraryExporter {
  LibraryExporter({required this.db, this.artStore});

  final MarmeladeDatabase db;

  /// Needed only to copy artwork files. A metadata-only export works without
  /// one, which is what lets a command-line tool build a bundle.
  final ArtStore? artStore;

  /// Builds the bundle in memory.
  ///
  /// Separate from [exportTo] so the shape of a bundle can be tested without
  /// writing anything to disk.
  Future<TransferBundle> buildBundle({
    required TransferOrigin origin,
    void Function(TransferProgress)? onProgress,
  }) async {
    void report(int completed, int total, String detail) => onProgress?.call(
          TransferProgress(
            phase: TransferPhase.readingLibrary,
            completed: completed,
            total: total,
            detail: detail,
          ),
        );

    report(0, 7, 'artists');
    final artists = await _artists();

    report(1, 7, 'albums');
    final albums = await _albums();

    report(2, 7, 'tags');
    final categories = await _tagCategories();
    final tags = await _tags();

    report(3, 7, 'tracks');
    final tracks = await _tracks();

    report(4, 7, 'playlists');
    final playlists = await _playlists();

    report(5, 7, 'artwork');
    final images = await _images(
      referenced: {
        for (final a in artists) ?a.imageId,
        for (final a in albums) ?a.imageId,
        for (final t in tracks) ?t.imageId,
        for (final t in tags) ?t.imageId,
        for (final pl in playlists) ?pl.imageId,
      },
    );

    report(6, 7, 'credit rules');
    final rules = await _splitRules({for (final a in artists) a.id});
    final separators = await _separators();

    report(7, 7, 'done');

    return TransferBundle(
      origin: origin,
      exportedAt: DateTime.now().toUtc(),
      artists: artists,
      albums: albums,
      tracks: tracks,
      tagCategories: categories,
      tags: tags,
      playlists: playlists,
      images: images,
      splitRules: rules,
      separators: separators,
    );
  }

  /// Writes a bundle folder at [target], creating it if needed.
  ///
  /// A folder rather than a single file because artwork and -- when asked for
  /// -- audio travel beside the JSON. With neither, the folder holds one
  /// file, and that uniformity is worth more than saving a directory: the
  /// same code path serves "email me your tags" and "sync my whole library
  /// through a cloud folder".
  Future<TransferExportReport> exportTo(
    Directory target, {
    required TransferOrigin origin,
    TransferExportOptions options = const TransferExportOptions(),
    void Function(TransferProgress)? onProgress,
  }) async {
    final started = DateTime.now();
    final bundle = await buildBundle(origin: origin, onProgress: onProgress);

    await target.create(recursive: true);

    var artworkFiles = 0;
    var artworkBytes = 0;
    var exportedImages = bundle.images;

    if (options.includeArtwork && artStore != null) {
      onProgress?.call(TransferProgress(
        phase: TransferPhase.copyingArtwork,
        total: bundle.images.length,
      ));
      final copied = await _copyArtwork(
        target: target,
        images: bundle.images,
        onProgress: onProgress,
      );
      exportedImages = copied.images;
      artworkFiles = copied.files;
      artworkBytes = copied.bytes;
    }

    var audioFiles = 0;
    var audioBytes = 0;
    if (options.includeAudio) {
      final copied = await _copyAudio(target: target, onProgress: onProgress);
      audioFiles = copied.files;
      audioBytes = copied.bytes;
    }

    onProgress?.call(
      const TransferProgress(phase: TransferPhase.writingBundle),
    );

    // Re-encoded with whatever the artwork pass learned about which images
    // actually travelled, so a reader is never promised a file that is not
    // in the folder.
    final json = TransferBundle(
      origin: bundle.origin,
      exportedAt: bundle.exportedAt,
      artists: bundle.artists,
      albums: bundle.albums,
      tracks: bundle.tracks,
      tagCategories: bundle.tagCategories,
      tags: bundle.tags,
      playlists: bundle.playlists,
      images: exportedImages,
      splitRules: bundle.splitRules,
      separators: bundle.separators,
    ).encode();

    final file = File(p.join(target.path, transferBundleFileName));
    await file.writeAsString(json);

    onProgress?.call(const TransferProgress(phase: TransferPhase.done));

    final elapsed = DateTime.now().difference(started);
    AppLog.instance.info('library exported', tag: 'transfer', fields: {
      'path': target.path,
      'tracks': bundle.tracks.length,
      'artists': bundle.artists.length,
      'playlists': bundle.playlists.length,
      'artwork': artworkFiles,
      'audio': audioFiles,
      'bytes': AppLog.formatBytes(json.length + artworkBytes + audioBytes),
      'ms': elapsed.inMilliseconds,
    });

    return TransferExportReport(
      path: target.path,
      tracks: bundle.tracks.length,
      artists: bundle.artists.length,
      playlists: bundle.playlists.length,
      artworkFiles: artworkFiles,
      audioFiles: audioFiles,
      bytes: json.length + artworkBytes + audioBytes,
    );
  }

  // ---------------------------------------------------------------- entities

  Future<List<TransferArtist>> _artists() async {
    final aliases = await _aliasesBy('artist_aliases', 'artist_id');
    final links = _groupBy(
      await db
          .customSelect(
            'SELECT artist_id, url, label, kind, sort_order FROM artist_links '
            'ORDER BY artist_id, sort_order, id',
            readsFrom: {db.artistLinks},
          )
          .get(),
      (row) => row.read<int>('artist_id'),
      (row) => TransferLink(
        url: row.read<String>('url'),
        label: row.readNullable<String>('label'),
        kind: row.read<String>('kind'),
        sortOrder: row.read<int>('sort_order'),
      ),
    );
    final members = _groupBy(
      await db
          .customSelect(
            'SELECT group_id, member_id, role, from_year, to_year, sort_order '
            'FROM artist_memberships ORDER BY group_id, sort_order, id',
            readsFrom: {db.artistMemberships},
          )
          .get(),
      (row) => row.read<int>('group_id'),
      (row) => TransferMembership(
        memberId: row.read<int>('member_id'),
        role: row.readNullable<String>('role'),
        fromYear: row.readNullable<int>('from_year'),
        toYear: row.readNullable<int>('to_year'),
        sortOrder: row.read<int>('sort_order'),
      ),
    );
    final tagLinks = await _tagLinks('artist_tags', 'artist_id');

    final rows = await db
        .customSelect(
          'SELECT id, name, name_key, sort_name, kind, disambiguation, '
          'description, image_id, never_split, is_verified, is_favorite, '
          'updated_at FROM artists ORDER BY id',
          readsFrom: {db.artists},
        )
        .get();

    return [
      for (final row in rows)
        TransferArtist(
          id: row.read<int>('id'),
          name: row.read<String>('name'),
          nameKey: row.read<String>('name_key'),
          disambiguation: row.readNullable<String>('disambiguation'),
          sortName: row.readNullable<String>('sort_name'),
          kind: row.read<String>('kind'),
          description: row.readNullable<String>('description'),
          neverSplit: row.read<int>('never_split') == 1,
          isVerified: row.read<int>('is_verified') == 1,
          isFavorite: row.read<int>('is_favorite') == 1,
          imageId: row.readNullable<int>('image_id'),
          updatedAt: row.readNullable<DateTime>('updated_at'),
          aliases: aliases[row.read<int>('id')] ?? const [],
          links: links[row.read<int>('id')] ?? const [],
          members: members[row.read<int>('id')] ?? const [],
          tagIds: tagLinks[row.read<int>('id')] ?? const [],
        ),
    ];
  }

  Future<List<TransferAlbum>> _albums() async {
    final aliases = await _aliasesBy('album_aliases', 'album_id');
    final credits = _groupBy(
      await db
          .customSelect(
            'SELECT album_id, artist_id, role, sort_order, credited_as, source '
            'FROM album_credits ORDER BY album_id, sort_order, id',
            readsFrom: {db.albumCredits},
          )
          .get(),
      (row) => row.read<int>('album_id'),
      (row) => TransferCredit(
        artistId: row.read<int>('artist_id'),
        role: row.read<String>('role'),
        creditedAs: row.readNullable<String>('credited_as'),
        sortOrder: row.read<int>('sort_order'),
        source: row.read<String>('source'),
      ),
    );
    final tagLinks = await _tagLinks('album_tags', 'album_id');

    final rows = await db
        .customSelect(
          'SELECT id, title, name_key, sort_title, kind, release_year, '
          'release_month, release_day, album_artist_id, is_various_artists, '
          'total_tracks, total_discs, description, label, catalog_number, '
          'is_verified, is_favorite, image_id, updated_at '
          'FROM albums ORDER BY id',
          readsFrom: {db.albums},
        )
        .get();

    return [
      for (final row in rows)
        TransferAlbum(
          id: row.read<int>('id'),
          title: row.read<String>('title'),
          nameKey: row.read<String>('name_key'),
          sortTitle: row.readNullable<String>('sort_title'),
          kind: row.read<String>('kind'),
          releaseYear: row.readNullable<int>('release_year'),
          releaseMonth: row.readNullable<int>('release_month'),
          releaseDay: row.readNullable<int>('release_day'),
          albumArtistId: row.readNullable<int>('album_artist_id'),
          isVariousArtists: row.read<int>('is_various_artists') == 1,
          totalTracks: row.readNullable<int>('total_tracks'),
          totalDiscs: row.readNullable<int>('total_discs'),
          description: row.readNullable<String>('description'),
          label: row.readNullable<String>('label'),
          catalogNumber: row.readNullable<String>('catalog_number'),
          isVerified: row.read<int>('is_verified') == 1,
          isFavorite: row.read<int>('is_favorite') == 1,
          imageId: row.readNullable<int>('image_id'),
          updatedAt: row.readNullable<DateTime>('updated_at'),
          aliases: aliases[row.read<int>('id')] ?? const [],
          credits: credits[row.read<int>('id')] ?? const [],
          tagIds: tagLinks[row.read<int>('id')] ?? const [],
        ),
    ];
  }

  Future<List<TransferTrack>> _tracks() async {
    final files = _groupBy(
      await db
          .customSelect(
            'SELECT track_id, quick_key, content_key, size_bytes, file_name, '
            'relative_path, duration_ms FROM media_files '
            'WHERE track_id IS NOT NULL ORDER BY track_id, id',
            readsFrom: {db.mediaFiles},
          )
          .get(),
      (row) => row.read<int>('track_id'),
      (row) => TransferFileIdentity(
        quickKey: row.readNullable<String>('quick_key'),
        contentKey: row.readNullable<String>('content_key'),
        sizeBytes: row.read<int>('size_bytes'),
        fileName: row.read<String>('file_name'),
        // Forward slashes, always: this string is compared against a path
        // built on another operating system's separator.
        relativePath: row.readNullable<String>('relative_path')?.replaceAll('\\', '/'),
        durationMs: row.readNullable<int>('duration_ms'),
      ),
    );

    final credits = _groupBy(
      await db
          .customSelect(
            'SELECT track_id, artist_id, role, sort_order, credited_as, '
            'source, confidence FROM track_credits '
            'ORDER BY track_id, sort_order, id',
            readsFrom: {db.trackCredits},
          )
          .get(),
      (row) => row.read<int>('track_id'),
      (row) => TransferCredit(
        artistId: row.read<int>('artist_id'),
        role: row.read<String>('role'),
        creditedAs: row.readNullable<String>('credited_as'),
        sortOrder: row.read<int>('sort_order'),
        source: row.read<String>('source'),
        confidence: row.readNullable<double>('confidence'),
      ),
    );

    final aliases = await _aliasesBy('track_aliases', 'track_id');
    final tagLinks = await _tagLinks('track_tags', 'track_id');

    // Only documents with text: a row that merely points at an .lrc file
    // beside the audio is re-found by the other machine's own scan, and its
    // path would be wrong there anyway.
    final lyrics = _groupBy(
      await db
          .customSelect(
            'SELECT track_id, format, content, is_synced, language, offset_ms, '
            "source, updated_at FROM lyrics "
            "WHERE content IS NOT NULL AND content <> '' ORDER BY track_id, id",
            readsFrom: {db.lyrics},
          )
          .get(),
      (row) => row.read<int>('track_id'),
      (row) => TransferLyrics(
        content: row.read<String>('content'),
        format: row.read<String>('format'),
        isSynced: row.read<int>('is_synced') == 1,
        language: row.readNullable<String>('language'),
        offsetMs: row.read<int>('offset_ms'),
        source: row.read<String>('source'),
        updatedAt: row.readNullable<DateTime>('updated_at'),
      ),
    );

    final rows = await db
        .customSelect(
          'SELECT id, title, name_key, sort_title, album_id, disc_no, '
          'track_no, duration_ms, release_year, bpm, initial_key, comment, '
          'notes, rating, is_favorite, play_count, skip_count, last_played_at, '
          'is_verified, added_at, updated_at, image_id FROM tracks ORDER BY id',
          readsFrom: {db.tracks},
        )
        .get();

    return [
      for (final row in rows)
        TransferTrack(
          id: row.read<int>('id'),
          title: row.read<String>('title'),
          nameKey: row.read<String>('name_key'),
          sortTitle: row.readNullable<String>('sort_title'),
          albumId: row.readNullable<int>('album_id'),
          trackNo: row.readNullable<int>('track_no'),
          discNo: row.readNullable<int>('disc_no'),
          durationMs: row.readNullable<int>('duration_ms'),
          releaseYear: row.readNullable<int>('release_year'),
          bpm: row.readNullable<double>('bpm'),
          initialKey: row.readNullable<String>('initial_key'),
          comment: row.readNullable<String>('comment'),
          notes: row.readNullable<String>('notes'),
          rating: row.readNullable<int>('rating'),
          isFavorite: row.read<int>('is_favorite') == 1,
          playCount: row.read<int>('play_count'),
          skipCount: row.read<int>('skip_count'),
          lastPlayedAt: row.readNullable<DateTime>('last_played_at'),
          isVerified: row.read<int>('is_verified') == 1,
          addedAt: row.readNullable<DateTime>('added_at'),
          updatedAt: row.readNullable<DateTime>('updated_at'),
          imageId: row.readNullable<int>('image_id'),
          files: files[row.read<int>('id')] ?? const [],
          credits: credits[row.read<int>('id')] ?? const [],
          aliases: aliases[row.read<int>('id')] ?? const [],
          tagIds: tagLinks[row.read<int>('id')] ?? const [],
          lyrics: lyrics[row.read<int>('id')] ?? const [],
        ),
    ];
  }

  Future<List<TransferTagCategory>> _tagCategories() async {
    final rows = await db
        .customSelect(
          'SELECT id, name, slug, description, color, icon, is_system, '
          'allow_multiple, sort_order FROM tag_categories ORDER BY sort_order, id',
          readsFrom: {db.tagCategories},
        )
        .get();
    return [
      for (final row in rows)
        TransferTagCategory(
          id: row.read<int>('id'),
          name: row.read<String>('name'),
          slug: row.readNullable<String>('slug'),
          description: row.readNullable<String>('description'),
          color: row.readNullable<int>('color'),
          icon: row.readNullable<int>('icon'),
          isSystem: row.read<int>('is_system') == 1,
          allowMultiple: row.read<int>('allow_multiple') == 1,
          sortOrder: row.read<int>('sort_order'),
        ),
    ];
  }

  Future<List<TransferTag>> _tags() async {
    final aliases = _groupBy(
      await db
          .customSelect(
            'SELECT tag_id, alias FROM tag_aliases ORDER BY tag_id, id',
            readsFrom: {db.tagAliases},
          )
          .get(),
      (row) => row.read<int>('tag_id'),
      (row) => TransferAlias(alias: row.read<String>('alias')),
    );

    final rows = await db
        .customSelect(
          'SELECT id, category_id, name, name_key, description, color, '
          'image_id, parent_tag_id, sort_order, is_favorite FROM tags '
          'ORDER BY id',
          readsFrom: {db.tags},
        )
        .get();

    return [
      for (final row in rows)
        TransferTag(
          id: row.read<int>('id'),
          name: row.read<String>('name'),
          nameKey: row.read<String>('name_key'),
          categoryId: row.readNullable<int>('category_id'),
          description: row.readNullable<String>('description'),
          color: row.readNullable<int>('color'),
          parentTagId: row.readNullable<int>('parent_tag_id'),
          sortOrder: row.read<int>('sort_order'),
          isFavorite: row.read<int>('is_favorite') == 1,
          imageId: row.readNullable<int>('image_id'),
          aliases: aliases[row.read<int>('id')] ?? const [],
        ),
    ];
  }

  Future<List<TransferPlaylist>> _playlists() async {
    final items = _groupBy(
      await db
          .customSelect(
            'SELECT playlist_id, track_id, child_playlist_id, position, '
            'is_exclusion, note FROM playlist_items '
            'ORDER BY playlist_id, position, id',
            readsFrom: {db.playlistItems},
          )
          .get(),
      (row) => row.read<int>('playlist_id'),
      (row) => TransferPlaylistItem(
        position: row.read<int>('position'),
        trackId: row.readNullable<int>('track_id'),
        childPlaylistId: row.readNullable<int>('child_playlist_id'),
        isExclusion: row.read<int>('is_exclusion') == 1,
        note: row.readNullable<String>('note'),
      ),
    );

    final order = _groupBy(
      await db
          .customSelect(
            'SELECT playlist_id, track_id, position FROM playlist_track_order '
            'ORDER BY playlist_id, position',
            readsFrom: {db.playlistTrackOrder},
          )
          .get(),
      (row) => row.read<int>('playlist_id'),
      (row) => TransferTrackOrder(
        trackId: row.read<int>('track_id'),
        position: row.read<int>('position'),
      ),
    );

    final tagLinks = await _tagLinks('playlist_tags', 'playlist_id');

    final rows = await db
        .customSelect(
          'SELECT id, name, name_key, description, image_id, kind, parent_id, '
          'query, query_limit, query_sort, auto_update, display_sort, '
          'sort_descending, group_by, is_pinned, sort_order, created_at, '
          'updated_at FROM playlists ORDER BY sort_order, id',
          readsFrom: {db.playlists},
        )
        .get();

    return [
      for (final row in rows)
        TransferPlaylist(
          id: row.read<int>('id'),
          name: row.read<String>('name'),
          nameKey: row.read<String>('name_key'),
          parentId: row.readNullable<int>('parent_id'),
          description: row.readNullable<String>('description'),
          kind: row.read<String>('kind'),
          query: row.readNullable<String>('query'),
          queryLimit: row.readNullable<int>('query_limit'),
          querySort: row.readNullable<String>('query_sort'),
          autoUpdate: row.read<int>('auto_update') == 1,
          displaySort: row.read<String>('display_sort'),
          sortDescending: row.read<int>('sort_descending') == 1,
          groupBy: row.read<String>('group_by'),
          isPinned: row.read<int>('is_pinned') == 1,
          sortOrder: row.read<int>('sort_order'),
          imageId: row.readNullable<int>('image_id'),
          createdAt: row.readNullable<DateTime>('created_at'),
          updatedAt: row.readNullable<DateTime>('updated_at'),
          items: items[row.read<int>('id')] ?? const [],
          trackOrder: order[row.read<int>('id')] ?? const [],
          tagIds: tagLinks[row.read<int>('id')] ?? const [],
        ),
    ];
  }

  /// Only the images something actually points at. Orphans in the store are
  /// this machine's housekeeping problem, not the other machine's.
  Future<List<TransferImage>> _images({required Set<int> referenced}) async {
    if (referenced.isEmpty) return const [];
    final rows = await db
        .customSelect(
          'SELECT id, sha256, kind, role, mime_type, width, height, '
          'byte_size, stored_path, source_description FROM images '
          // Integers straight out of the database, never user text.
          'WHERE id IN (${referenced.join(',')})',
          readsFrom: {db.images},
        )
        .get();

    return [
      for (final row in rows)
        TransferImage(
          id: row.read<int>('id'),
          sha256: row.read<String>('sha256'),
          mimeType: row.read<String>('mime_type'),
          byteSize: row.read<int>('byte_size'),
          kind: row.read<String>('kind'),
          role: row.read<String>('role'),
          width: row.readNullable<int>('width'),
          height: row.readNullable<int>('height'),
          sourceDescription: row.readNullable<String>('source_description'),
          // Filled in by the artwork copy pass, if there is one.
          file: null,
        ),
    ];
  }

  /// Split rules, with the artist ids inside their JSON resolution lifted out
  /// into ordinary references so the importer can remap them.
  Future<List<TransferSplitRule>> _splitRules(Set<int> knownArtists) async {
    final rows = await db
        .customSelect(
          'SELECT raw_credit, raw_credit_key, resolution, is_user_confirmed, '
          'applied_count FROM credit_split_rules ORDER BY id',
          readsFrom: {db.creditSplitRules},
        )
        .get();

    final rules = <TransferSplitRule>[];
    for (final row in rows) {
      final parts = <TransferCredit>[];
      var usable = true;
      try {
        final decoded = jsonDecode(row.read<String>('resolution'));
        if (decoded is List) {
          for (final part in decoded) {
            if (part is! Map) continue;
            final artistId = part['artistId'];
            // A rule pointing at an artist that no longer exists cannot be
            // rebuilt elsewhere, so it is dropped rather than half-carried.
            if (artistId is! int || !knownArtists.contains(artistId)) {
              usable = false;
              break;
            }
            parts.add(TransferCredit(
              artistId: artistId,
              role: part['role'] is String ? part['role'] as String : 'mainArtist',
              creditedAs:
                  part['creditedAs'] is String ? part['creditedAs'] as String : null,
              source: 'user',
            ));
          }
        }
      } catch (error) {
        AppLog.instance.warn(
          'skipped a split rule whose resolution could not be read',
          tag: 'transfer',
          fields: {'rule': row.read<String>('raw_credit'), 'error': '$error'},
        );
        usable = false;
      }
      if (!usable || parts.isEmpty) continue;

      rules.add(TransferSplitRule(
        rawCredit: row.read<String>('raw_credit'),
        rawCreditKey: row.read<String>('raw_credit_key'),
        isUserConfirmed: row.read<int>('is_user_confirmed') == 1,
        appliedCount: row.read<int>('applied_count'),
        parts: parts,
      ));
    }
    return rules;
  }

  /// Separator tokens, so a user-added separator -- or a built-in one they
  /// turned off -- follows the library it was tuned for.
  Future<List<TransferSeparator>> _separators() async {
    final rows = await db
        .customSelect(
          'SELECT token, kind, requires_spaces, is_ambiguous, enabled, '
          'sort_order, is_built_in FROM separator_tokens ORDER BY sort_order, id',
          readsFrom: {db.separatorTokens},
        )
        .get();
    return [
      for (final row in rows)
        TransferSeparator(
          token: row.read<String>('token'),
          kind: row.read<String>('kind'),
          requiresSpaces: row.read<int>('requires_spaces') == 1,
          isAmbiguous: row.read<int>('is_ambiguous') == 1,
          enabled: row.read<int>('enabled') == 1,
          sortOrder: row.read<int>('sort_order'),
          isBuiltIn: row.read<int>('is_built_in') == 1,
        ),
    ];
  }

  // ------------------------------------------------------------------- files

  Future<({List<TransferImage> images, int files, int bytes})> _copyArtwork({
    required Directory target,
    required List<TransferImage> images,
    void Function(TransferProgress)? onProgress,
  }) async {
    final store = artStore;
    if (store == null) return (images: images, files: 0, bytes: 0);

    final dir = Directory(p.join(target.path, transferArtworkDirName));
    await dir.create(recursive: true);

    final out = <TransferImage>[];
    var files = 0;
    var bytes = 0;
    var done = 0;

    // The store names every file after its own sha256, so the bundle can do
    // the same and an import that already has the picture recognises it
    // without reading a byte.
    final rows = await db
        .customSelect(
          'SELECT id, stored_path FROM images WHERE id IN '
          '(${images.map((i) => i.id).join(',')})',
          readsFrom: {db.images},
        )
        .get();
    final storedPaths = {
      for (final row in rows)
        row.read<int>('id'): row.read<String>('stored_path'),
    };

    for (final image in images) {
      done += 1;
      onProgress?.call(TransferProgress(
        phase: TransferPhase.copyingArtwork,
        completed: done,
        total: images.length,
      ));

      final stored = storedPaths[image.id];
      if (stored == null) {
        out.add(image);
        continue;
      }
      final source = store.fileFor(stored);
      if (!await source.exists()) {
        // The row outlived its file. Keep the metadata: the other machine may
        // well have the same picture already.
        out.add(image);
        continue;
      }

      final name = p.basename(stored);
      final destination = File(p.join(dir.path, name));
      try {
        if (!await destination.exists()) {
          await source.copy(destination.path);
          files += 1;
          bytes += await destination.length();
        }
        out.add(TransferImage(
          id: image.id,
          sha256: image.sha256,
          mimeType: image.mimeType,
          byteSize: image.byteSize,
          kind: image.kind,
          role: image.role,
          width: image.width,
          height: image.height,
          sourceDescription: image.sourceDescription,
          file: name,
        ));
      } catch (error) {
        AppLog.instance.warn(
          'could not copy artwork into the bundle',
          tag: 'transfer',
          fields: {'file': name, 'error': '$error'},
        );
        out.add(image);
      }
    }

    return (images: out, files: files, bytes: bytes);
  }

  /// Copies one file per track into the bundle, keeping its path inside the
  /// library folder so the other machine can drop the lot into a folder of
  /// its own and have the same tree.
  ///
  /// One file, not all of them: a track held as both FLAC and MP3 would
  /// otherwise be carried twice, and the point of including audio at all is
  /// to make new music playable on the other machine, not to mirror formats.
  Future<({int files, int bytes})> _copyAudio({
    required Directory target,
    void Function(TransferProgress)? onProgress,
  }) async {
    final dir = Directory(p.join(target.path, transferAudioDirName));
    await dir.create(recursive: true);

    final rows = await db
        .customSelect(
          'SELECT mf.track_id AS track_id, mf.relative_path AS relative_path, '
          'lf.path AS folder_path FROM media_files mf '
          'JOIN library_folders lf ON lf.id = mf.folder_id '
          "WHERE mf.track_id IS NOT NULL AND mf.status = 'present' "
          'ORDER BY mf.track_id, mf.id',
          readsFrom: {db.mediaFiles, db.libraryFolders},
        )
        .get();

    final seen = <int>{};
    var files = 0;
    var bytes = 0;
    var done = 0;

    for (final row in rows) {
      done += 1;
      final trackId = row.read<int>('track_id');
      if (!seen.add(trackId)) continue;

      final relative = row.read<String>('relative_path');
      final source = File(p.join(row.read<String>('folder_path'), relative));

      onProgress?.call(TransferProgress(
        phase: TransferPhase.copyingAudio,
        completed: done,
        total: rows.length,
        detail: p.basename(relative),
      ));

      try {
        if (!await source.exists()) continue;
        final destination = File(p.join(dir.path, p.normalize(relative)));
        if (await destination.exists() &&
            await destination.length() == await source.length()) {
          continue;
        }
        await destination.parent.create(recursive: true);
        await source.copy(destination.path);
        files += 1;
        bytes += await destination.length();
      } catch (error) {
        AppLog.instance.warn(
          'could not copy an audio file into the bundle',
          tag: 'transfer',
          fields: {'file': relative, 'error': '$error'},
        );
      }
    }

    return (files: files, bytes: bytes);
  }

  // ----------------------------------------------------------------- helpers

  Future<Map<int, List<TransferAlias>>> _aliasesBy(
    String table,
    String parentColumn,
  ) async {
    final rows = await db
        .customSelect(
          'SELECT $parentColumn, alias, kind, locale, source FROM $table '
          'ORDER BY $parentColumn, id',
        )
        .get();
    return _groupBy(
      rows,
      (row) => row.read<int>(parentColumn),
      (row) => TransferAlias(
        alias: row.read<String>('alias'),
        kind: row.read<String>('kind'),
        locale: row.readNullable<String>('locale'),
        source: row.read<String>('source'),
      ),
    );
  }

  Future<Map<int, List<int>>> _tagLinks(String table, String ownerColumn) async {
    final rows = await db
        .customSelect('SELECT $ownerColumn, tag_id FROM $table')
        .get();
    return _groupBy(
      rows,
      (row) => row.read<int>(ownerColumn),
      (row) => row.read<int>('tag_id'),
    );
  }

  static Map<int, List<T>> _groupBy<T>(
    List<QueryRow> rows,
    int Function(QueryRow) key,
    T Function(QueryRow) value,
  ) {
    final out = <int, List<T>>{};
    for (final row in rows) {
      out.putIfAbsent(key(row), () => []).add(value(row));
    }
    return out;
  }
}
