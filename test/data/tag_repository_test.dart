import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/playlist_repository.dart';
import 'package:marmelade/data/repositories/tag_repository.dart';

/// Tags, and the cascade that makes them worth having.
///
/// A tag on an album or a playlist reaches the tracks inside it. That is a
/// query, not duplicated rows, so the interesting cases are the ones where the
/// answer has to change without anything writing to the track: untagging the
/// album, adding a track to a tagged playlist, nesting.
void main() {
  late MarmeladeDatabase db;
  late TagRepository tags;
  late PlaylistRepository playlists;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    final indexer = SearchIndexer(db);
    tags = TagRepository(db: db, searchIndexer: indexer);
    playlists = PlaylistRepository(db: db, searchIndexer: indexer);
  });

  tearDown(() async => db.close());

  Future<int> album(String title) => db.into(db.albums).insert(
        AlbumsCompanion.insert(title: title, nameKey: title.toLowerCase()),
      );

  Future<int> track(String title, {int? albumId}) =>
      db.into(db.tracks).insert(TracksCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            albumId: Value(albumId),
          ));

  Future<int> artist(String name) => db.into(db.artists).insert(
        ArtistsCompanion.insert(name: name, nameKey: name.toLowerCase()),
      );

  Future<Set<String>> tagNamesOf(TagTarget target, int id) async {
    final attached = await tags.watchTagsOf(target, id).first;
    return attached.map((t) => t.name).toSet();
  }

  group('creating tags', () {
    test('a tag is matched on its normalised name, not its spelling',
        () async {
      // A library where "Hardcore" and "hardcore" are two tags is a library
      // where neither finds everything.
      final first = await tags.upsertTag('Hardcore');
      final second = await tags.upsertTag('  hardcore ');
      expect(second, first);

      final rows = await db.customSelect('SELECT id FROM tags').get();
      expect(rows, hasLength(1));
    });

    test('renaming keeps the matching key in step', () async {
      final id = await tags.upsertTag('Hardcor');
      await tags.renameTag(id, 'Hardcore');

      final row = await db
          .customSelect(
            'SELECT name, name_key FROM tags WHERE id = ?1',
            variables: [Variable(id)],
          )
          .getSingle();
      expect(row.read<String>('name'), 'Hardcore');
      expect(row.read<String>('name_key'), 'hardcore');
    });

    test('deleting a tag takes it off everything', () async {
      final tagId = await tags.upsertTag('Temporary');
      final trackId = await track('Song');
      final albumId = await album('Release');
      await tags.attach(TagTarget.track, trackId, tagId);
      await tags.attach(TagTarget.album, albumId, tagId);

      await tags.deleteTag(tagId);
      expect(await tagNamesOf(TagTarget.track, trackId), isEmpty);
      expect(await tagNamesOf(TagTarget.album, albumId), isEmpty);
    });
  });

  group('attaching', () {
    test('all four kinds of thing can be tagged', () async {
      final tagId = await tags.upsertTag('Favourite');
      final trackId = await track('Song');
      final albumId = await album('Release');
      final artistId = await artist('Someone');
      final playlistId = (await playlists.create('Mix'))!;

      await tags.attach(TagTarget.track, trackId, tagId);
      await tags.attach(TagTarget.album, albumId, tagId);
      await tags.attach(TagTarget.artist, artistId, tagId);
      await tags.attach(TagTarget.playlist, playlistId, tagId);

      expect(await tagNamesOf(TagTarget.album, albumId), {'Favourite'});
      expect(await tagNamesOf(TagTarget.artist, artistId), {'Favourite'});
      expect(await tagNamesOf(TagTarget.playlist, playlistId), {'Favourite'});
    });

    test('attaching twice is not an error', () async {
      final tagId = await tags.upsertTag('Favourite');
      final trackId = await track('Song');
      await tags.attach(TagTarget.track, trackId, tagId);
      await tags.attach(TagTarget.track, trackId, tagId);
      expect(await tagNamesOf(TagTarget.track, trackId), {'Favourite'});
    });

    test('attaching by name creates the tag', () async {
      final trackId = await track('Song');
      final tagId = await tags.attachByName(TagTarget.track, trackId, 'New');
      expect(tagId, greaterThan(0));
      expect(await tagNamesOf(TagTarget.track, trackId), {'New'});
    });

    test('an empty name creates nothing', () async {
      final trackId = await track('Song');
      expect(await tags.attachByName(TagTarget.track, trackId, '  '), -1);
      expect(await db.customSelect('SELECT id FROM tags').get(), isEmpty);
    });
  });

  group('the cascade', () {
    test('an album tag reaches its tracks, marked as inherited', () async {
      final albumId = await album('Soundtrack');
      final trackId = await track('Theme', albumId: albumId);
      final tagId = await tags.upsertTag('Soundtrack');
      await tags.attach(TagTarget.album, albumId, tagId);

      final attached = await tags.watchTagsOf(TagTarget.track, trackId).first;
      expect(attached.single.name, 'Soundtrack');
      // The distinction matters: this cannot be removed from the track, only
      // from the album that granted it.
      expect(attached.single.origin, TagOrigin.album);
      expect(attached.single.isInherited, isTrue);
    });

    test('untagging the album untags its tracks, with nothing to clean up',
        () async {
      final albumId = await album('Soundtrack');
      final trackId = await track('Theme', albumId: albumId);
      final tagId = await tags.upsertTag('Soundtrack');
      await tags.attach(TagTarget.album, albumId, tagId);
      expect(await tagNamesOf(TagTarget.track, trackId), {'Soundtrack'});

      await tags.detach(TagTarget.album, albumId, tagId);
      expect(await tagNamesOf(TagTarget.track, trackId), isEmpty);
    });

    test('a playlist tag reaches the tracks in it', () async {
      final playlistId = (await playlists.create('Workout'))!;
      final trackId = await track('Fast');
      await playlists.addTracks(playlistId, [trackId]);
      final tagId = await tags.upsertTag('Workout');
      await tags.attach(TagTarget.playlist, playlistId, tagId);

      final attached = await tags.watchTagsOf(TagTarget.track, trackId).first;
      expect(attached.single.name, 'Workout');
      expect(attached.single.origin, TagOrigin.playlist);
    });

    test('a track added to a tagged playlist inherits the tag at once',
        () async {
      // Nothing writes to the track, so this only works because the cascade is
      // a query.
      final playlistId = (await playlists.create('Workout'))!;
      final tagId = await tags.upsertTag('Workout');
      await tags.attach(TagTarget.playlist, playlistId, tagId);

      final trackId = await track('Added later');
      expect(await tagNamesOf(TagTarget.track, trackId), isEmpty);

      await playlists.addTracks(playlistId, [trackId]);
      expect(await tagNamesOf(TagTarget.track, trackId), {'Workout'});
    });

    test('a playlist tag reaches through a nested playlist', () async {
      final outer = (await playlists.create('Everything'))!;
      final inner = (await playlists.create('Hardcore'))!;
      final trackId = await track('Fast');
      await playlists.addTracks(inner, [trackId]);
      await playlists.addChildPlaylist(outer, inner);

      final tagId = await tags.upsertTag('Loud');
      await tags.attach(TagTarget.playlist, outer, tagId);

      expect(await tagNamesOf(TagTarget.track, trackId), {'Loud'});
    });

    test('the cascade survives a cycle in the playlists', () async {
      // The recursive view uses UNION rather than UNION ALL, which
      // deduplicates and is also what stops a loop from running forever.
      final a = (await playlists.create('A'))!;
      final b = (await playlists.create('B'))!;
      final trackId = await track('Song');
      await playlists.addTracks(a, [trackId]);
      await playlists.addChildPlaylist(a, b);
      // Forced past the guard, the way a hand-edited database would be.
      await db.into(db.playlistItems).insert(
            PlaylistItemsCompanion.insert(
              playlistId: b,
              childPlaylistId: Value(a),
              position: 99,
            ),
          );

      final tagId = await tags.upsertTag('Loud');
      await tags.attach(TagTarget.playlist, a, tagId);
      expect(await tagNamesOf(TagTarget.track, trackId), {'Loud'});
    });

    test('own, album and playlist tags all show up together', () async {
      final albumId = await album('Release');
      final trackId = await track('Song', albumId: albumId);
      final playlistId = (await playlists.create('Mix'))!;
      await playlists.addTracks(playlistId, [trackId]);

      await tags.attach(
        TagTarget.track,
        trackId,
        await tags.upsertTag('Own'),
      );
      await tags.attach(
        TagTarget.album,
        albumId,
        await tags.upsertTag('FromAlbum'),
      );
      await tags.attach(
        TagTarget.playlist,
        playlistId,
        await tags.upsertTag('FromPlaylist'),
      );

      final attached = await tags.watchTagsOf(TagTarget.track, trackId).first;
      expect(
        attached.map((t) => t.name).toSet(),
        {'Own', 'FromAlbum', 'FromPlaylist'},
      );
      // Own tags first, since those are the ones that can be removed here.
      expect(attached.first.origin, TagOrigin.own);
    });

    test('an artist tag does not cascade to their tracks', () async {
      // An artist tag says something about the artist. Pushing it onto every
      // track they ever guested on would make track tags meaningless.
      final artistId = await artist('Someone');
      final trackId = await track('Song');
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(trackId: trackId, artistId: artistId),
          );
      await tags.attach(
        TagTarget.artist,
        artistId,
        await tags.upsertTag('Japanese'),
      );

      expect(await tagNamesOf(TagTarget.track, trackId), isEmpty);
    });

    test('a track counts once however many ways it carries a tag', () async {
      final albumId = await album('Release');
      final trackId = await track('Song', albumId: albumId);
      final playlistId = (await playlists.create('Mix'))!;
      await playlists.addTracks(playlistId, [trackId]);
      final tagId = await tags.upsertTag('Everywhere');

      // The same tag by all three routes at once.
      await tags.attach(TagTarget.track, trackId, tagId);
      await tags.attach(TagTarget.album, albumId, tagId);
      await tags.attach(TagTarget.playlist, playlistId, tagId);

      final card = (await tags.watchTags().first).single;
      expect(card.trackCount, 1);
      expect(await tags.trackIdsWithTag(tagId), [trackId]);
    });
  });

  group('categories', () {
    test('the system categories are seeded and cannot be deleted', () async {
      final categories = await tags.watchCategories().first;
      expect(
        categories.map((c) => c.name),
        containsAll(['Genre', 'Language']),
      );

      final genre = categories.firstWhere((c) => c.name == 'Genre');
      expect(genre.isSystem, isTrue);
      // The indexer writes it on every scan; deleting it would only mean it
      // reappeared empty.
      expect(await tags.deleteCategory(genre.id), isFalse);
    });

    test('a category can be made, renamed and deleted', () async {
      final id = await tags.createCategory('Mood');
      expect(id, greaterThan(0));

      await tags.renameCategory(id, 'Feeling');
      var categories = await tags.watchCategories().first;
      expect(categories.map((c) => c.name), contains('Feeling'));

      expect(await tags.deleteCategory(id), isTrue);
      categories = await tags.watchCategories().first;
      expect(categories.map((c) => c.name), isNot(contains('Feeling')));
    });

    test('deleting a category leaves its tags uncategorised', () async {
      final categoryId = await tags.createCategory('Mood');
      final tagId = await tags.upsertTag('Calm', categoryId: categoryId);
      await tags.deleteCategory(categoryId);

      final card = (await tags.watchTags().first).single;
      expect(card.id, tagId);
      expect(card.categoryId, isNull);
    });

    test('tags can be filtered by category', () async {
      final mood = await tags.createCategory('Mood');
      await tags.upsertTag('Calm', categoryId: mood);
      await tags.upsertTag('Uncategorised');

      final inMood = await tags.watchTags(categoryId: mood).first;
      expect(inMood.map((t) => t.name), ['Calm']);
    });
  });

  group('findTags', () {
    test('matches names and aliases', () async {
      final id = await tags.upsertTag('Hardcore');
      await db.into(db.tagAliases).insert(
            TagAliasesCompanion.insert(
              tagId: id,
              alias: 'ハードコア',
              aliasKey: 'ハードコア',
            ),
          );

      expect((await tags.findTags('hard')).map((t) => t.id), contains(id));
      expect((await tags.findTags('ハード')).map((t) => t.id), contains(id));
      expect(await tags.findTags('  '), isEmpty);
    });
  });
}
