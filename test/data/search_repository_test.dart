import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/repositories/playlist_repository.dart';
import 'package:marmelade/data/repositories/search_repository.dart';
import 'package:marmelade/data/repositories/tag_repository.dart';

/// Search, which is the payoff for everything else in the catalog.
///
/// The promise the app is built on is that typing one half of "Name1 x Name2"
/// returns the song. Most of these tests are that promise, said different ways.
void main() {
  late MarmeladeDatabase db;
  late SearchIndexer indexer;
  late SearchRepository search;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    indexer = SearchIndexer(db);
    search = SearchRepository(
      db: db,
      library: LibraryRepository(db),
      tags: TagRepository(db: db, searchIndexer: indexer),
      playlists: PlaylistRepository(db: db, searchIndexer: indexer),
    );
  });

  tearDown(() => db.close());

  Future<int> artist(String name, {String? alias}) async {
    final id = await db.into(db.artists).insert(ArtistsCompanion.insert(
          name: name,
          nameKey: name.toLowerCase(),
        ));
    if (alias != null) {
      await db.into(db.artistAliases).insert(
            ArtistAliasesCompanion.insert(
              artistId: id,
              alias: alias,
              aliasKey: alias.toLowerCase(),
            ),
          );
    }
    return id;
  }

  Future<int> album(String title, {int? artistId}) =>
      db.into(db.albums).insert(AlbumsCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            albumArtistId: Value(artistId),
          ));

  Future<int> track(
    String title, {
    List<int> credits = const [],
    int? albumId,
    int playCount = 0,
  }) async {
    final id = await db.into(db.tracks).insert(TracksCompanion.insert(
          title: title,
          nameKey: title.toLowerCase(),
          albumId: Value(albumId),
          playCount: Value(playCount),
        ));
    for (final artistId in credits) {
      await db.into(db.trackCredits).insert(TrackCreditsCompanion.insert(
            trackId: id,
            artistId: artistId,
          ));
    }
    return id;
  }

  Future<int> tag(String name) => db.into(db.tags).insert(
        TagsCompanion.insert(name: name, nameKey: name.toLowerCase()),
      );

  Future<int> playlist(String name) => db.into(db.playlists).insert(
        PlaylistsCompanion.insert(name: name, nameKey: name.toLowerCase()),
      );

  group('what the words are', () {
    test('operators in the query are stripped, not obeyed', () {
      // Straight into MATCH, every one of these is a syntax error rather than
      // a search. A search box that throws on a typed character is broken.
      expect(searchTerms('AC/DC -'), ['ac', 'dc']);
      expect(searchTerms('a "b'), ['a', 'b']);
      expect(searchTerms('NEAR( x'), ['near', 'x']);
      expect(searchTerms('* OR *'), ['or']);
      expect(searchTerms('   '), isEmpty);
    });

    test('diacritics fold the way the index folds them', () {
      expect(searchTerms('Björk'), ['bjork']);
      expect(foldForSearch('Sigur Rós'), 'sigur ros');
    });
  });

  group('finding things', () {
    test('an empty query finds nothing rather than everything', () async {
      await artist('Someone');
      await indexer.rebuildAll();
      expect((await search.search('   ')).isEmpty, isTrue);
    });

    test('either half of a two-artist credit finds the track', () async {
      // The whole point of the app. "Koiflower x Bangler" was split into two
      // artists at scan time; searching the second one has to work.
      final koiflower = await artist('Koiflower');
      final bangler = await artist('Bangler');
      final id = await track('Feel Right', credits: [koiflower, bangler]);
      await indexer.rebuildAll();

      for (final name in ['koiflower', 'bangler']) {
        final results = await search.search(name);
        expect(
          results.tracks.map((t) => t.id),
          contains(id),
          reason: 'searching $name should find the track',
        );
      }
    });

    test('a track is found by its album', () async {
      final albumId = await album('AD:HOUSE Winter 4');
      final id = await track('Feel Right', albumId: albumId);
      await indexer.rebuildAll();

      final results = await search.search('ad:house');
      expect(results.albums.map((a) => a.id), contains(albumId));
      expect(results.tracks.map((t) => t.id), contains(id));
    });

    test('an artist is found by an alias in another script', () async {
      final id = await artist('PinocchioP', alias: 'ピノキオピー');
      await indexer.rebuildAll();

      expect(
        (await search.search('ピノキオピー')).artists.map((a) => a.id),
        contains(id),
      );
    });

    test('a substring of a Japanese title matches', () async {
      // The word tokenizer treats a run of Japanese as one token, so this can
      // only ever come from the trigram index.
      if (!db.trigramSearchAvailable) return;
      final id = await track('恋愛裁判');
      await indexer.rebuildAll();

      expect(
        (await search.search('愛裁')).tracks.map((t) => t.id),
        contains(id),
      );
    });

    test('a mid-word substring matches', () async {
      if (!db.trigramSearchAvailable) return;
      final id = await album('Marmelade');
      await indexer.rebuildAll();

      expect(
        (await search.search('mela')).albums.map((a) => a.id),
        contains(id),
      );
    });

    test('tags and playlists are results too', () async {
      final tagId = await tag('Late night');
      final playlistId = await playlist('Late night driving');
      await indexer.rebuildAll();

      final results = await search.search('late night');
      expect(results.tags.map((t) => t.id), contains(tagId));
      expect(results.playlists.map((p) => p.id), contains(playlistId));
    });

    test('every word has to match', () async {
      final wanted = await track('Pale snow');
      await track('Pale');
      await track('Snow halation');
      await indexer.rebuildAll();

      expect(
        (await search.search('pale snow')).tracks.map((t) => t.id),
        [wanted],
      );
    });

    test('a prefix of a word matches, so results appear while typing',
        () async {
      final id = await artist('Rigel Theatre');
      await indexer.rebuildAll();

      expect((await search.search('rig')).artists.map((a) => a.id), [id]);
    });
  });

  group('what comes first', () {
    test('the exact name beats a longer name that starts with it', () async {
      final exact = await artist('Lime');
      final longer = await artist('Limestone Quartet');
      await indexer.rebuildAll();

      final results = await search.search('lime');
      expect(results.artists.map((a) => a.id), [exact, longer]);
    });

    test('an alias that starts with the query counts as a name', () async {
      // Both match. The one with an alias you typed the start of is the one
      // meant, not the unrelated artist whose name happens to begin the same
      // way and has one track to its name.
      final pino = await artist('PinocchioP', alias: 'ピノキオピー');
      for (var i = 0; i < 12; i++) {
        await track('Song $i', credits: [pino]);
      }
      final other = await artist('ピノキオ野郎');
      await track('One song', credits: [other]);
      await indexer.rebuildAll();

      final results = await search.search('ピノキオ');
      expect(results.artists.map((a) => a.id), [pino, other]);
    });

    test('a name match beats a mention', () async {
      // The artist is called Sayuri; the track merely credits her. Someone
      // typing "sayuri" means the artist.
      final artistId = await artist('Sayuri');
      await track('About a Voyage', credits: [artistId]);
      await indexer.rebuildAll();

      final results = await search.search('sayuri');
      expect(results.best?.entity, SearchEntity.artist);
      expect(results.best?.id, artistId);
    });

    test('an artist wins a tie against a track of the same name', () async {
      final artistId = await artist('Amiga');
      await track('Amiga');
      await indexer.rebuildAll();

      final results = await search.search('amiga');
      expect(results.best?.entity, SearchEntity.artist);
      expect(results.best?.id, artistId);
    });

    test('within a tier, the better-played track comes first', () async {
      final quiet = await track('Snow', playCount: 0);
      final played = await track('Snow', playCount: 40);
      await indexer.rebuildAll();

      expect(
        (await search.search('snow')).tracks.map((t) => t.id),
        [played, quiet],
      );
    });
  });

  group('how much was found', () {
    test('the count is what matched, not what is shown', () async {
      for (var i = 0; i < 9; i++) {
        await track('Snow $i');
      }
      await indexer.rebuildAll();

      final results = await search.search('snow', perKind: 4);
      expect(results.tracks, hasLength(4));
      expect(results.totals[SearchEntity.track], 9);
      expect(results.hidden(SearchEntity.track, 4), 5);
    });

    test('a kind can be left out of the search', () async {
      await artist('Snow');
      await track('Snow');
      await indexer.rebuildAll();

      final results = await search.search(
        'snow',
        kinds: {SearchEntity.artist},
      );
      expect(results.artists, hasLength(1));
      expect(results.tracks, isEmpty);
    });

    test('a deleted track does not leave a phantom count', () async {
      // The count comes from the index; the results come from the catalog. If
      // they disagree, the visible list is the truth.
      final id = await track('Ghost');
      await indexer.rebuildAll();
      await db.customStatement('DELETE FROM tracks WHERE id = ?', [id]);

      final results = await search.search('ghost');
      expect(results.tracks, isEmpty);
      expect(results.hidden(SearchEntity.track, 0), 0);
    });
  });

  group('staying in step', () {
    test('a renamed artist is found under the new name only', () async {
      final id = await artist('Old Name');
      await indexer.rebuildAll();
      await db.customUpdate(
        'UPDATE artists SET name = ?1, name_key = ?2 WHERE id = ?3',
        variables: [
          Variable('New Name'),
          Variable('new name'),
          Variable(id),
        ],
        updates: {db.artists},
      );
      await indexer.reindexEntity(SearchEntity.artist, id);

      expect((await search.search('new name')).artists.map((a) => a.id), [id]);
      expect((await search.search('old name')).artists, isEmpty);
    });
  });
}
