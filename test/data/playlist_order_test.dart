import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/repositories/playlist_repository.dart';
import 'package:marmelade/data/repositories/search_repository.dart';
import 'package:marmelade/data/repositories/smart_playlist_resolver.dart';
import 'package:marmelade/data/repositories/tag_repository.dart';

/// How a playlist is ordered and grouped.
///
/// The rule that shapes all of it: a playlist is a sequence somebody built, so
/// the default is the order things were added and nothing rearranges itself
/// without being asked. Everything else here is about an arrangement surviving
/// something -- a new track, a changed query, a reopened app.
void main() {
  late MarmeladeDatabase db;
  late PlaylistRepository playlists;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    final indexer = SearchIndexer(db);
    final search = SearchRepository(
      db: db,
      library: LibraryRepository(db),
      tags: TagRepository(db: db, searchIndexer: indexer),
      playlists: PlaylistRepository(db: db, searchIndexer: indexer),
    );
    playlists = PlaylistRepository(
      db: db,
      searchIndexer: indexer,
      smart: SmartPlaylistResolver(
        db: db,
        searchTracks: (query, {int limit = 20000}) =>
            search.trackIdsMatching(query, limit: limit),
      ),
    );
  });

  tearDown(() => db.close());

  Future<int> artist(String name) => db.into(db.artists).insert(
        ArtistsCompanion.insert(name: name, nameKey: name.toLowerCase()),
      );

  Future<int> album(String title, {int? year}) =>
      db.into(db.albums).insert(AlbumsCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            releaseYear: Value(year),
          ));

  Future<int> track(
    String title, {
    int? albumId,
    int? artistId,
    int? year,
    int playCount = 0,
    int? durationMs,
  }) async {
    final id = await db.into(db.tracks).insert(TracksCompanion.insert(
          title: title,
          nameKey: title.toLowerCase(),
          albumId: Value(albumId),
          releaseYear: Value(year),
          playCount: Value(playCount),
          durationMs: Value(durationMs),
        ));
    if (artistId != null) {
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(trackId: id, artistId: artistId),
          );
    }
    return id;
  }

  /// The contents in the order the playlist asks for.
  Future<List<int>> shown(int playlistId) async {
    final ids = await playlists.resolveContents(playlistId);
    return playlists.applyOrder(
      playlistId,
      ids,
      sortBy: playlists.sortTrackIds,
    );
  }

  group('as added, by default', () {
    test('a manual playlist keeps the order things were put in it', () async {
      final id = (await playlists.create('Mine'))!;
      final c = await track('Cherry');
      final a = await track('Apple');
      final b = await track('Banana');
      await playlists.addTracks(id, [c, a, b]);

      expect(await shown(id), [c, a, b]);
      final rules = await playlists.displayRules(id);
      expect(rules.sort, PlaylistSort.added);
      expect(rules.group, PlaylistGrouping.none);
    });

    test('a track added later goes to the end', () async {
      final id = (await playlists.create('Mine'))!;
      final first = await track('First');
      await playlists.addTracks(id, [first]);
      final later = await track('Later');
      await playlists.addTracks(id, [later]);

      expect(await shown(id), [first, later]);
    });
  });

  group('a sort, set once', () {
    test('applies to what is there and what arrives later', () async {
      // The point of storing it: adding a track to a title-sorted playlist
      // should put it where it belongs, not at the end.
      final id = (await playlists.create('Mine'))!;
      final c = await track('Cherry');
      final a = await track('Apple');
      await playlists.addTracks(id, [c, a]);
      await playlists.setDisplayRules(id, sort: PlaylistSort.title);

      expect(await shown(id), [a, c]);

      final b = await track('Banana');
      await playlists.addTracks(id, [b]);
      expect(await shown(id), [a, b, c]);
    });

    test('descending reverses it', () async {
      final id = (await playlists.create('Mine'))!;
      final a = await track('Apple');
      final b = await track('Banana');
      await playlists.addTracks(id, [a, b]);

      await playlists.setDisplayRules(id, sort: PlaylistSort.title);
      expect(await shown(id), [a, b]);
      await playlists.setDisplayRules(id, descending: true);
      expect(await shown(id), [b, a]);
    });

    test('by album follows disc and track order inside each release',
        () async {
      final second = await album('Beta');
      final first = await album('Alpha');
      final b1 = await track('one', albumId: first);
      final b2 = await track('two', albumId: second);
      final id = (await playlists.create('Mine'))!;
      await playlists.addTracks(id, [b2, b1]);

      await playlists.setDisplayRules(id, sort: PlaylistSort.album);
      expect(await shown(id), [b1, b2]);
    });

    test('by artist uses the main credit', () async {
      final zed = await artist('Zed');
      final abe = await artist('Abe');
      final byZed = await track('one', artistId: zed);
      final byAbe = await track('two', artistId: abe);
      final id = (await playlists.create('Mine'))!;
      await playlists.addTracks(id, [byZed, byAbe]);

      await playlists.setDisplayRules(id, sort: PlaylistSort.artist);
      expect(await shown(id), [byAbe, byZed]);
    });

    test('most played, and never played last for a year', () async {
      final quiet = await track('Quiet', playCount: 0);
      final loud = await track('Loud', playCount: 40);
      final undated = await track('Undated');
      final dated = await track('Dated', year: 1999);
      final id = (await playlists.create('Mine'))!;
      await playlists.addTracks(id, [quiet, loud, undated, dated]);

      await playlists.setDisplayRules(id, sort: PlaylistSort.playCount);
      expect((await shown(id)).first, loud);

      await playlists.setDisplayRules(id, sort: PlaylistSort.releaseYear);
      // A year nobody knows sorts last rather than as year zero.
      expect((await shown(id)).last, isNot(dated));
    });

    test('a sort never loses a track', () async {
      // A track with no album still has to appear in an album-sorted playlist.
      final id = (await playlists.create('Mine'))!;
      final loose = await track('Loose');
      final onAlbum = await track('Placed', albumId: await album('Somewhere'));
      await playlists.addTracks(id, [loose, onAlbum]);

      await playlists.setDisplayRules(id, sort: PlaylistSort.album);
      expect((await shown(id)).toSet(), {loose, onAlbum});
    });
  });

  group('arranged by hand', () {
    test('dragging in a manual playlist sticks, and sets custom', () async {
      final id = (await playlists.create('Mine'))!;
      final a = await track('A');
      final b = await track('B');
      final c = await track('C');
      await playlists.addTracks(id, [a, b, c]);

      await playlists.saveCustomOrder(id, [c, a, b]);

      expect(await shown(id), [c, a, b]);
      expect((await playlists.displayRules(id)).sort, PlaylistSort.custom);
    });

    test('a smart playlist remembers an arrangement it has no rows for',
        () async {
      final camellia = await artist('Camellia');
      final x = await track('X', artistId: camellia);
      final y = await track('Y', artistId: camellia);
      final z = await track('Z', artistId: camellia);

      final id = (await playlists.create('Smart', kind: PlaylistKind.smart))!;
      await playlists.saveQuery(id, query: 'artist:camellia');
      await playlists.saveCustomOrder(id, [z, x, y]);

      expect(await shown(id), [z, x, y]);
    });

    test('a new match joins at the end rather than scattering the order',
        () async {
      final camellia = await artist('Camellia');
      final x = await track('X', artistId: camellia);
      final y = await track('Y', artistId: camellia);

      final id = (await playlists.create('Smart', kind: PlaylistKind.smart))!;
      await playlists.saveQuery(id, query: 'artist:camellia');
      await playlists.saveCustomOrder(id, [y, x]);

      final fresh = await track('New', artistId: camellia);
      expect(await shown(id), [y, x, fresh]);
    });

    test('the arrangement survives a change to the query', () async {
      // The hard requirement: narrow the query, widen it again, and what was
      // arranged is still arranged.
      final camellia = await artist('Camellia');
      final nanahira = await artist('Nanahira');
      final x = await track('X', artistId: camellia);
      final y = await track('Y', artistId: camellia);
      final other = await track('Other', artistId: nanahira);

      final id = (await playlists.create('Smart', kind: PlaylistKind.smart))!;
      await playlists.saveQuery(id, query: 'artist:camellia');
      await playlists.saveCustomOrder(id, [y, x]);

      // A different query: one of the arranged tracks is gone, one is new.
      await playlists.saveQuery(id, query: 'artist:nanahira');
      expect(await shown(id), [other]);

      // Back again, and the arrangement is still there.
      await playlists.saveQuery(id, query: 'artist:camellia');
      expect(await shown(id), [y, x]);
    });

    test('an arrangement with nothing left in it falls back gracefully',
        () async {
      final camellia = await artist('Camellia');
      final gone = await track('Gone', artistId: camellia);
      final id = (await playlists.create('Smart', kind: PlaylistKind.smart))!;
      await playlists.saveQuery(id, query: 'artist:camellia');
      await playlists.saveCustomOrder(id, [gone]);

      await db.customStatement('DELETE FROM tracks WHERE id = $gone');
      final fresh = await track('Fresh', artistId: camellia);

      // Not empty, and not an error: the one thing that matches shows.
      expect(await shown(id), [fresh]);
    });
  });

  group('grouping', () {
    test('is remembered, and is separate from the sort', () async {
      final id = (await playlists.create('Mine'))!;
      await playlists.setDisplayRules(
        id,
        sort: PlaylistSort.album,
        group: PlaylistGrouping.album,
      );

      final rules = await playlists.displayRules(id);
      expect(rules.sort, PlaylistSort.album);
      expect(rules.group, PlaylistGrouping.album);

      // Changing one leaves the other alone.
      await playlists.setDisplayRules(id, sort: PlaylistSort.title);
      final after = await playlists.displayRules(id);
      expect(after.sort, PlaylistSort.title);
      expect(after.group, PlaylistGrouping.album);
    });

    test('the card carries both, for the view', () async {
      final id = (await playlists.create('Mine'))!;
      await playlists.setDisplayRules(
        id,
        sort: PlaylistSort.playCount,
        descending: true,
        group: PlaylistGrouping.artist,
      );

      final card = await playlists.watchPlaylist(id).first;
      expect(card!.displaySort, PlaylistSort.playCount);
      expect(card.sortDescending, isTrue);
      expect(card.grouping, PlaylistGrouping.artist);
    });
  });
}
