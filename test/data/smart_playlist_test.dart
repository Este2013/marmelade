import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/repositories/playlist_repository.dart';
import 'package:marmelade/data/repositories/search_repository.dart';
import 'package:marmelade/data/repositories/smart_playlist_resolver.dart';
import 'package:marmelade/data/repositories/tag_repository.dart';

/// Smart playlists, against a real schema.
///
/// A smart playlist stores no tracks: it is a query plus the library, evaluated
/// now. So the thing worth testing is that the evaluation agrees with the rest
/// of the app -- the same credit splitting, the same cascaded tags -- and that
/// a query nobody can parse does not take a page down with it.
void main() {
  late MarmeladeDatabase db;
  late PlaylistRepository playlists;
  late SmartPlaylistResolver resolver;

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
    resolver = SmartPlaylistResolver(
      db: db,
      searchTracks: (query, {int limit = 20000}) =>
          search.trackIdsMatching(query, limit: limit),
    );
    playlists = PlaylistRepository(
      db: db,
      searchIndexer: indexer,
      smart: resolver,
    );
  });

  tearDown(() => db.close());

  Future<int> artist(String name, {String? alias}) async {
    final id = await db.into(db.artists).insert(ArtistsCompanion.insert(
          name: name,
          nameKey: name.toLowerCase(),
        ));
    if (alias != null) {
      await db.into(db.artistAliases).insert(ArtistAliasesCompanion.insert(
            artistId: id,
            alias: alias,
            aliasKey: alias.toLowerCase(),
          ));
    }
    return id;
  }

  Future<int> album(String title, {int? year}) =>
      db.into(db.albums).insert(AlbumsCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            releaseYear: Value(year),
          ));

  Future<int> track(
    String title, {
    List<int> credits = const [],
    int? albumId,
    int? year,
    int? rating,
    int playCount = 0,
    DateTime? addedAt,
    DateTime? lastPlayedAt,
  }) async {
    final id = await db.into(db.tracks).insert(TracksCompanion.insert(
          title: title,
          nameKey: title.toLowerCase(),
          albumId: Value(albumId),
          releaseYear: Value(year),
          rating: Value(rating),
          playCount: Value(playCount),
          lastPlayedAt: Value(lastPlayedAt),
          addedAt: addedAt == null ? const Value.absent() : Value(addedAt),
        ));
    for (final artistId in credits) {
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(trackId: id, artistId: artistId),
          );
    }
    return id;
  }

  Future<int> tagged(int trackId, String name, {int? albumId}) async {
    final tagId = await db.into(db.tags).insert(
          TagsCompanion.insert(name: name, nameKey: name.toLowerCase()),
        );
    if (albumId != null) {
      await db.into(db.albumTags).insert(
            AlbumTagsCompanion.insert(albumId: albumId, tagId: tagId),
          );
    } else {
      await db.into(db.trackTags).insert(
            TrackTagsCompanion.insert(trackId: trackId, tagId: tagId),
          );
    }
    return tagId;
  }

  group('resolving a query', () {
    test('an artist clause finds every credit, not just the first', () async {
      // The same promise as search: "Koiflower x Bangler" is two artists, and
      // a playlist of one of them has to contain the collaboration.
      final koiflower = await artist('Koiflower');
      final bangler = await artist('Bangler');
      final both = await track('Feel Right', credits: [koiflower, bangler]);
      final solo = await track('Alone', credits: [koiflower]);
      await track('Unrelated');

      expect(
        await resolver.resolve('artist:bangler'),
        [both],
      );
      expect(
        (await resolver.resolve('artist:koiflower')).toSet(),
        {both, solo},
      );
    });

    test('an artist clause matches an alias', () async {
      final id = await artist('PinocchioP', alias: 'ピノキオピー');
      final trackId = await track('Song', credits: [id]);

      expect(await resolver.resolve('artist:ピノキオ'), [trackId]);
    });

    test('a tag clause follows the cascade from the album', () async {
      // The tag is on the album, not the track. Anywhere else in the app that
      // counts, so it counts here.
      final albumId = await album('AD:HOUSE Winter 4');
      final onAlbum = await track('Feel Right', albumId: albumId);
      final loose = await track('Elsewhere');
      await tagged(onAlbum, 'Soundtrack', albumId: albumId);

      expect(await resolver.resolve('tag:soundtrack'), [onAlbum]);
      expect(
        await resolver.resolve('-tag:soundtrack'),
        contains(loose),
      );
    });

    test('clauses combine with and', () async {
      final camellia = await artist('Camellia');
      final wanted = await track('Ghost', credits: [camellia], year: 2021);
      await track('Old one', credits: [camellia], year: 2009);
      await tagged(wanted, 'Hardcore');

      expect(
        await resolver.resolve('artist:camellia year:>=2015 tag:hardcore'),
        [wanted],
      );
    });

    test('a year falls back to the album when the track has none', () async {
      final albumId = await album('Antenna', year: 2023);
      final id = await track('Tokyo Mannequin', albumId: albumId);

      expect(await resolver.resolve('year:2023'), [id]);
    });

    test('an age clause reads less-than as within', () async {
      final now = DateTime.utc(2026, 8, 27);
      final fresh = await track(
        'New',
        addedAt: now.subtract(const Duration(days: 3)),
      );
      final old = await track(
        'Old',
        addedAt: now.subtract(const Duration(days: 200)),
      );

      expect(await resolver.resolve('added:<30d', now: now), [fresh]);
      expect(await resolver.resolve('added:>30d', now: now), [old]);
    });

    test('never played matches no age clause', () async {
      // Not "played infinitely long ago": the column is null, and a playlist
      // of things played over a year ago should not fill up with things never
      // played at all.
      final now = DateTime.utc(2026, 8, 27);
      await track('Untouched');

      expect(await resolver.resolve('played:>1y', now: now), isEmpty);
    });

    test('words go through the index, so a mention counts', () async {
      final camellia = await artist('Camellia');
      final id = await track('Ghost', credits: [camellia]);
      await SearchIndexer(db).rebuildAll();

      expect(await resolver.resolve('camellia'), [id]);
    });

    test('an empty or unparseable query yields nothing, not everything',
        () async {
      await track('Something');

      expect(await resolver.resolve(''), isEmpty);
      expect(await resolver.resolve('   '), isEmpty);
    });

    test('a limit and a sort are honoured', () async {
      final camellia = await artist('Camellia');
      await track('B side', credits: [camellia], playCount: 1);
      final hit = await track('Hit', credits: [camellia], playCount: 99);

      expect(
        await resolver.resolve(
          'artist:camellia',
          limit: 1,
          sort: 'plays:desc',
        ),
        [hit],
      );
    });
  });

  group('as a playlist', () {
    Future<int> smart(String query, {String? sort, int? limit}) async {
      final id = await playlists.create('Smart', kind: PlaylistKind.smart);
      await playlists.saveQuery(id!, query: query, sort: sort, limit: limit);
      return id;
    }

    test('its contents come from the query', () async {
      final camellia = await artist('Camellia');
      final wanted = await track('Ghost', credits: [camellia]);
      await track('Unrelated');

      final id = await smart('artist:camellia');
      expect(await playlists.resolveContents(id), [wanted]);
    });

    test('editing the query changes the contents', () async {
      final a = await artist('Camellia');
      final b = await artist('Nanahira');
      final byA = await track('Ghost', credits: [a]);
      final byB = await track('Song', credits: [b]);

      final id = await smart('artist:camellia');
      expect(await playlists.resolveContents(id), [byA]);

      await playlists.saveQuery(id, query: 'artist:nanahira');
      expect(await playlists.resolveContents(id), [byB]);
    });

    test('one track can be excluded without touching the query', () async {
      // The reason exclusions exist: an otherwise perfect query with one song
      // you never want to hear.
      final camellia = await artist('Camellia');
      final keep = await track('Ghost', credits: [camellia]);
      final drop = await track('Skit', credits: [camellia]);

      final id = await smart('artist:camellia');
      await playlists.exclude(id, drop);
      expect(await playlists.resolveContents(id), [keep]);

      await playlists.unexclude(id, drop);
      expect((await playlists.resolveContents(id)).toSet(), {keep, drop});
    });

    test('a hybrid playlist is the query plus what was added by hand',
        () async {
      final camellia = await artist('Camellia');
      final matched = await track('Ghost', credits: [camellia]);
      final byHand = await track('Something else');

      final id = await playlists.create('Both', kind: PlaylistKind.hybrid);
      await playlists.saveQuery(id!, query: 'artist:camellia');
      await playlists.addTracks(id, [byHand]);

      // Query results first, so adding a track by hand does not reshuffle
      // everything the query found.
      expect(await playlists.resolveContents(id), [matched, byHand]);
    });

    test('a manual playlist is unaffected by any of this', () async {
      final id = await playlists.create('Manual');
      final trackId = await track('Song');
      await playlists.addTracks(id!, [trackId]);

      expect(await playlists.resolveContents(id), [trackId]);
    });

    test('saving a query over a manual playlist makes it smart', () async {
      final id = await playlists.create('Was manual');
      await playlists.saveQuery(id!, query: 'artist:camellia');

      final row = await db
          .customSelect(
            'SELECT kind FROM playlists WHERE id = ?1',
            variables: [Variable(id)],
          )
          .getSingle();
      expect(row.read<String>('kind'), 'smart');
    });
  });
}
