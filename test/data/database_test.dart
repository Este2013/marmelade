// drift exports isNull/isNotNull expression helpers that collide with the
// matcher names of the same purpose; the matchers are what tests want here.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    // Opening is lazy; force the migration to run.
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() async => db.close());

  group('schema', () {
    test('creates every declared table', () async {
      final rows = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%'",
          )
          .get();
      final names = rows.map((r) => r.read<String>('name')).toSet();

      for (final expected in const [
        'library_folders',
        'media_files',
        'images',
        'artists',
        'artist_aliases',
        'artist_links',
        'artist_memberships',
        'albums',
        'album_aliases',
        'tracks',
        'track_aliases',
        'track_credits',
        'album_credits',
        'tag_categories',
        'tags',
        'tag_aliases',
        'track_tags',
        'album_tags',
        'artist_tags',
        'playlists',
        'playlist_items',
        'queue_items',
        'play_history',
        'lyrics',
        'settings',
        'scan_runs',
        'scan_issues',
        'separator_tokens',
        'credit_split_rules',
        'pending_credits',
      ]) {
        expect(names, contains(expected), reason: 'missing table $expected');
      }
    });

    test('enables foreign key enforcement', () async {
      final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(row.read<int>('foreign_keys'), 1);
    });

    test('cascades a folder delete down to its files', () async {
      final folderId = await db.into(db.libraryFolders).insert(
            LibraryFoldersCompanion.insert(path: r'C:\music'),
          );
      await db.into(db.mediaFiles).insert(
            MediaFilesCompanion.insert(
              folderId: folderId,
              relativePath: 'a/b.mp3',
              fileName: 'b.mp3',
              extension: 'mp3',
              sizeBytes: 100,
              modifiedAt: DateTime.utc(2026),
            ),
          );
      expect(await db.select(db.mediaFiles).get(), hasLength(1));

      await (db.delete(db.libraryFolders)
            ..where((t) => t.id.equals(folderId)))
          .go();
      expect(await db.select(db.mediaFiles).get(), isEmpty);
    });

    test('rejects a playlist item that is neither a track nor a playlist',
        () async {
      final playlistId = await db.into(db.playlists).insert(
            PlaylistsCompanion.insert(name: 'Mix', nameKey: 'mix'),
          );
      // Both null violates the CHECK constraint.
      await expectLater(
        db.into(db.playlistItems).insert(
              PlaylistItemsCompanion.insert(
                playlistId: playlistId,
                position: 0,
              ),
            ),
        throwsA(isA<SqliteException>()),
      );
      // So does setting both.
      await expectLater(
        db.into(db.playlistItems).insert(
              PlaylistItemsCompanion.insert(
                playlistId: playlistId,
                position: 0,
                trackId: const Value(1),
                childPlaylistId: Value(playlistId),
              ),
            ),
        throwsA(isA<SqliteException>()),
      );
    });
  });

  group('search indexes', () {
    test('creates the tokenised FTS5 index with diacritic folding', () async {
      await db.customStatement(
        "INSERT INTO $ftsTokenTable (entity_type, entity_id, title, aliases, "
        "secondary) VALUES ('art', '1', 'Björk', 'Bjork Gudmundsdottir', '')",
      );
      // Diacritics are folded, so the unaccented spelling matches.
      final hits = await db.customSelect(
        "SELECT entity_id FROM $ftsTokenTable WHERE $ftsTokenTable MATCH ?",
        variables: [Variable('bjork')],
      ).get();
      expect(hits, hasLength(1));
    });

    test('supports prefix queries', () async {
      await db.customStatement(
        "INSERT INTO $ftsTokenTable (entity_type, entity_id, title, aliases, "
        "secondary) VALUES ('art', '2', 'PinocchioP', '', '')",
      );
      final hits = await db.customSelect(
        "SELECT entity_id FROM $ftsTokenTable WHERE $ftsTokenTable MATCH ?",
        variables: [Variable('Pinocchio*')],
      ).get();
      expect(hits, hasLength(1));
    });

    test('trigram index finds substrings inside CJK text', () async {
      // The whole reason the trigram index exists: unicode61 treats a run of
      // Japanese characters as one token, so a substring of it never matches.
      expect(
        db.trigramSearchAvailable,
        isTrue,
        reason: 'the linked SQLite build lacks the trigram tokenizer',
      );

      await db.customStatement(
        "INSERT INTO $ftsTrigramTable (entity_type, entity_id, haystack) "
        "VALUES ('art', '3', 'ピノキオピー')",
      );
      final hits = await db.customSelect(
        "SELECT entity_id FROM $ftsTrigramTable WHERE $ftsTrigramTable MATCH ?",
        variables: [Variable('ノキオ')],
      ).get();
      expect(hits, hasLength(1),
          reason: 'substring of a CJK name should match');
    });

    test('trigram index finds substrings mid-word in Latin text', () async {
      await db.customStatement(
        "INSERT INTO $ftsTrigramTable (entity_type, entity_id, haystack) "
        "VALUES ('art', '4', 't+pazolite')",
      );
      final hits = await db.customSelect(
        "SELECT entity_id FROM $ftsTrigramTable WHERE $ftsTrigramTable MATCH ?",
        variables: [Variable('pazol')],
      ).get();
      expect(hits, hasLength(1));
    });
  });

  group('artwork fallback views', () {
    /// Inserts an image row and returns its id.
    Future<int> image(String sha) => db.into(db.images).insert(
          ImagesCompanion.insert(
            sha256: sha,
            kind: ImageKind.embedded,
            mimeType: 'image/jpeg',
            byteSize: 1,
            storedPath: '$sha.jpg',
          ),
        );

    test('a track prefers its own art over the album and artist', () async {
      final trackArt = await image('a' * 64);
      final albumArt = await image('b' * 64);
      final artistArt = await image('c' * 64);

      final artistId = await db.into(db.artists).insert(
            ArtistsCompanion.insert(
              name: 'Camellia',
              nameKey: 'camellia',
              imageId: Value(artistArt),
            ),
          );
      final albumId = await db.into(db.albums).insert(
            AlbumsCompanion.insert(
              title: 'Album',
              nameKey: 'album',
              albumArtistId: Value(artistId),
              imageId: Value(albumArt),
            ),
          );
      final trackId = await db.into(db.tracks).insert(
            TracksCompanion.insert(
              title: 'Song',
              nameKey: 'song',
              albumId: Value(albumId),
              imageId: Value(trackArt),
            ),
          );

      final resolved = await db.customSelect(
        'SELECT image_id FROM v_track_artwork WHERE track_id = ?',
        variables: [Variable(trackId)],
      ).getSingle();
      expect(resolved.read<int?>('image_id'), trackArt);
    });

    test('falls back album -> album artist -> null down the chain', () async {
      final albumArt = await image('d' * 64);
      final artistArt = await image('e' * 64);

      final artistId = await db.into(db.artists).insert(
            ArtistsCompanion.insert(
              name: 'Nanahira',
              nameKey: 'nanahira',
              imageId: Value(artistArt),
            ),
          );

      // 1. Track with no art, album has art -> album art.
      var albumId = await db.into(db.albums).insert(
            AlbumsCompanion.insert(
              title: 'WithArt',
              nameKey: 'withart',
              albumArtistId: Value(artistId),
              imageId: Value(albumArt),
            ),
          );
      var trackId = await db.into(db.tracks).insert(
            TracksCompanion.insert(
              title: 'T1',
              nameKey: 't1',
              albumId: Value(albumId),
            ),
          );
      var row = await db.customSelect(
        'SELECT image_id FROM v_track_artwork WHERE track_id = ?',
        variables: [Variable(trackId)],
      ).getSingle();
      expect(row.read<int?>('image_id'), albumArt);

      // 2. Neither track nor album has art -> the album artist's.
      albumId = await db.into(db.albums).insert(
            AlbumsCompanion.insert(
              title: 'NoArt',
              nameKey: 'noart',
              albumArtistId: Value(artistId),
            ),
          );
      trackId = await db.into(db.tracks).insert(
            TracksCompanion.insert(
              title: 'T2',
              nameKey: 't2',
              albumId: Value(albumId),
            ),
          );
      row = await db.customSelect(
        'SELECT image_id FROM v_track_artwork WHERE track_id = ?',
        variables: [Variable(trackId)],
      ).getSingle();
      expect(row.read<int?>('image_id'), artistArt);

      // 3. A standalone single with nothing at all -> null, not an error.
      trackId = await db.into(db.tracks).insert(
            TracksCompanion.insert(title: 'Loose', nameKey: 'loose'),
          );
      row = await db.customSelect(
        'SELECT image_id FROM v_track_artwork WHERE track_id = ?',
        variables: [Variable(trackId)],
      ).getSingle();
      expect(row.read<int?>('image_id'), isNull);
    });

    test('an album with no art borrows from its main-credited artist',
        () async {
      final artistArt = await image('f' * 64);
      final artistId = await db.into(db.artists).insert(
            ArtistsCompanion.insert(
              name: 'Kobaryo',
              nameKey: 'kobaryo',
              imageId: Value(artistArt),
            ),
          );
      final albumId = await db.into(db.albums).insert(
            AlbumsCompanion.insert(
              title: 'Bare',
              nameKey: 'bare',
              albumArtistId: Value(artistId),
            ),
          );
      final row = await db.customSelect(
        'SELECT image_id FROM v_album_artwork WHERE album_id = ?',
        variables: [Variable(albumId)],
      ).getSingle();
      expect(row.read<int?>('image_id'), artistArt);
    });

    test('a track with no album borrows from its main credit', () async {
      final artistArt = await image('9' * 64);
      final artistId = await db.into(db.artists).insert(
            ArtistsCompanion.insert(
              name: 'Solo',
              nameKey: 'solo',
              imageId: Value(artistArt),
            ),
          );
      final trackId = await db.into(db.tracks).insert(
            TracksCompanion.insert(title: 'Single', nameKey: 'single'),
          );
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(
              trackId: trackId,
              artistId: artistId,
              role: const Value(CreditRole.mainArtist),
            ),
          );
      final row = await db.customSelect(
        'SELECT image_id FROM v_track_artwork WHERE track_id = ?',
        variables: [Variable(trackId)],
      ).getSingle();
      expect(row.read<int?>('image_id'), artistArt);
    });
  });

  group('seed data', () {
    test('creates the system tag categories the indexer writes into', () async {
      final cats = await db.select(db.tagCategories).get();
      final slugs = cats.map((c) => c.slug).toSet();
      expect(slugs, containsAll([
        systemTagCategoryGenre,
        systemTagCategoryLanguage,
      ]));
      final genre = cats.firstWhere((c) => c.slug == systemTagCategoryGenre);
      expect(genre.isSystem, isTrue);
    });

    test('creates the built-in separators with correct space requirements',
        () async {
      final seps = await db.select(db.separatorTokens).get();
      expect(seps, isNotEmpty);
      expect(seps.every((s) => s.isBuiltIn), isTrue);

      final byToken = {for (final s in seps) s.token: s};

      // Ambiguous tokens must require surrounding whitespace, or they would
      // shred "Maxence", "AC/DC" and "t+pazolite".
      for (final token in ['x', '&', '+', '/', 'and']) {
        expect(byToken[token], isNotNull, reason: 'missing separator $token');
        expect(byToken[token]!.requiresSpaces, isTrue,
            reason: '$token must require spaces');
      }

      // Unambiguous collaboration marks do not.
      for (final token in ['×', '、', '|']) {
        expect(byToken[token], isNotNull, reason: 'missing separator $token');
        expect(byToken[token]!.requiresSpaces, isFalse);
      }

      expect(byToken['feat.']?.kind, SeparatorKind.featured);
      expect(byToken['ft.']?.kind, SeparatorKind.featured);
      expect(byToken[',']?.kind, SeparatorKind.split);
    });
  });
}
