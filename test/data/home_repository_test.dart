import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/home_repository.dart';

/// The home page's storage: a tree of items somebody arranged by hand.
///
/// Everything here is about the two things that make it different from the
/// rest of the library -- it is a tree, and its items point at four different
/// tables -- because those are where it can go wrong in ways a flat list of
/// albums never could.
void main() {
  late MarmeladeDatabase db;
  late HomeRepository home;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    home = HomeRepository(db);
    // The fresh-database seed puts one section there already. Starting from a
    // known-empty page keeps each test's own arrangement legible.
    await db.delete(db.homeSections).go();
  });
  tearDown(() => db.close());

  Future<int> artist(String name) =>
      db.into(db.artists).insert(ArtistsCompanion.insert(
            name: name,
            nameKey: name.toLowerCase(),
          ));

  Future<int> album(String title, {int? artistId}) =>
      db.into(db.albums).insert(AlbumsCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            albumArtistId: Value(artistId),
          ));

  Future<int> track(String title, {int? albumId}) =>
      db.into(db.tracks).insert(TracksCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            albumId: Value(albumId),
          ));

  Future<int> section({
    String title = 'Mine',
    HomeLayout layout = HomeLayout.grid,
    HomeSectionSource source = HomeSectionSource.curated,
  }) =>
      home.addSection(title: title, layout: layout, source: source);

  group('reading a page', () {
    test('resolves an item to what it points at', () async {
      final artistId = await artist('PinocchioP');
      final albumId = await album('Antenna', artistId: artistId);
      final sectionId = await section();
      await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.album,
        refId: albumId,
      );

      final page = await home.watchHome().first;

      expect(page.single.items.single.title, 'Antenna');
      expect(page.single.items.single.subtitle, 'PinocchioP');
    });

    test('a user label wins over the name of the thing it points at', () async {
      // The point of being able to rename: a tile is somebody's shorthand for
      // a thing, not a second copy of the library's name for it.
      final albumId = await album('Comic and Cosmic');
      final sectionId = await section();
      await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.album,
        refId: albumId,
        label: 'Saturday music',
      );

      final page = await home.watchHome().first;

      expect(page.single.items.single.title, 'Saturday music');
    });

    test('drops an item whose target is gone rather than showing a ghost',
        () async {
      final albumId = await album('Temporary');
      final sectionId = await section();
      await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.album,
        refId: albumId,
      );
      await (db.delete(db.albums)..where((a) => a.id.equals(albumId))).go();

      final page = await home.watchHome().first;

      expect(page.single.items, isEmpty);
    });

    test('nests a collection inside a section, and one inside that', () async {
      final sectionId = await section();
      final outer = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Soundtracks',
      );
      final inner = await home.addItem(
        sectionId: sectionId,
        parentId: outer,
        kind: HomeItemKind.collection,
        label: 'Games',
      );
      final albumId = await album('Rain World');
      await home.addItem(
        sectionId: sectionId,
        parentId: inner,
        kind: HomeItemKind.album,
        refId: albumId,
      );

      final page = await home.watchHome().first;

      final top = page.single.items.single;
      expect(top.title, 'Soundtracks');
      expect(top.children.single.title, 'Games');
      expect(top.children.single.children.single.title, 'Rain World');
      expect(page.single.items, hasLength(1),
          reason: 'nested items are not also listed at the top level');
    });

    test('a collection says how many things are in it', () async {
      final sectionId = await section();
      final collection = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Mixed',
      );
      for (final title in ['One', 'Two']) {
        await home.addItem(
          sectionId: sectionId,
          parentId: collection,
          kind: HomeItemKind.album,
          refId: await album(title),
        );
      }

      final page = await home.watchHome().first;

      expect(page.single.items.single.subtitle, '2 items');
    });

    test('a collection counts a search apart from what was hand-picked',
        () async {
      // It stands for however many things it matches today, which the tile
      // cannot know without running it -- so folding it into the count would
      // produce the one number that is certainly wrong.
      final sectionId = await section();
      final collection = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Mixed',
      );
      await home.addItem(
        sectionId: sectionId,
        parentId: collection,
        kind: HomeItemKind.album,
        refId: await album('One'),
      );
      await home.addItem(
        sectionId: sectionId,
        parentId: collection,
        kind: HomeItemKind.query,
        label: 'Recent',
        query: 'tag:hardcore',
      );

      final page = await home.watchHome().first;

      expect(page.single.items.single.subtitle, '1 item and 1 search');
    });

    test('a query item keeps its query and needs no library row', () async {
      final sectionId = await section();
      await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.query,
        label: 'Recent hardcore',
        query: 'tag:hardcore added:<30d',
      );

      final page = await home.watchHome().first;

      expect(page.single.items.single.title, 'Recent hardcore');
      expect(page.single.items.single.query, 'tag:hardcore added:<30d');
    });
  });

  group('the page refreshes itself', () {
    test('an item added to a section shows up without anything else changing',
        () async {
      // The bug this covers: adding through the dialog wrote the row and the
      // page never showed it. Only the outer query is watched, and it listed
      // just `home_sections` -- so adding an *item* gave the stream no reason
      // to re-run, and the row sat there unread.
      final sectionId = await section();
      final page = home.watchHome();
      expect((await page.first).single.items, isEmpty);

      final updated = page.firstWhere((s) => s.single.items.isNotEmpty);
      await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.album,
        refId: await album('Antenna'),
      );

      expect((await updated).single.items.single.title, 'Antenna');
    });

    test('removing an item updates the page too', () async {
      final sectionId = await section();
      final itemId = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.album,
        refId: await album('Antenna'),
      );

      final page = home.watchHome();
      expect((await page.first).single.items, hasLength(1));

      final updated = page.firstWhere((s) => s.single.items.isEmpty);
      await home.removeItem(itemId);

      expect((await updated).single.items, isEmpty);
    });

    test('renaming the album behind a tile renames the tile', () async {
      // Nothing a home table owns changes here, which is exactly why the
      // library tables have to be in the watched set.
      final albumId = await album('Antena');
      final sectionId = await section();
      await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.album,
        refId: albumId,
      );

      final page = home.watchHome();
      expect((await page.first).single.items.single.title, 'Antena');

      final updated = page.firstWhere(
        (s) => s.single.items.single.title == 'Antenna',
      );
      await (db.update(db.albums)..where((a) => a.id.equals(albumId)))
          .write(const AlbumsCompanion(title: Value('Antenna')));

      expect((await updated).single.items.single.title, 'Antenna');
    });
  });

  group('recently played', () {
    test('is newest first, one row per track however often it was played',
        () async {
      final older = await track('Older');
      final newer = await track('Newer');
      await db.into(db.playHistory).insert(PlayHistoryCompanion.insert(
            trackId: older,
            startedAt: DateTime.utc(2026, 1, 1),
          ));
      // Played twice: it should appear once, at its most recent time.
      await db.into(db.playHistory).insert(PlayHistoryCompanion.insert(
            trackId: newer,
            startedAt: DateTime.utc(2026, 1, 2),
          ));
      await db.into(db.playHistory).insert(PlayHistoryCompanion.insert(
            trackId: newer,
            startedAt: DateTime.utc(2026, 1, 3),
          ));

      final found = await home.recentlyPlayed(10);

      expect([for (final one in found) one.title], ['Newer', 'Older']);
    });

    test('its items are marked as not the user\'s to rearrange', () async {
      await db.into(db.playHistory).insert(PlayHistoryCompanion.insert(
            trackId: await track('Something'),
            startedAt: DateTime.utc(2026, 1, 1),
          ));

      final found = await home.recentlyPlayed(10);

      expect(found.single.isComputed, isTrue);
    });

    test('fills a computed section without anything being added to it',
        () async {
      await section(source: HomeSectionSource.recentlyPlayed);
      await db.into(db.playHistory).insert(PlayHistoryCompanion.insert(
            trackId: await track('Heard it'),
            startedAt: DateTime.utc(2026, 1, 1),
          ));

      final page = await home.watchHome().first;

      expect(page.single.items.single.title, 'Heard it');
    });

    test('honours the section\'s own limit', () async {
      await section(source: HomeSectionSource.recentlyPlayed);
      await home.setSectionLimit(
        (await home.watchHome().first).single.id,
        2,
      );
      for (var i = 0; i < 5; i++) {
        await db.into(db.playHistory).insert(PlayHistoryCompanion.insert(
              trackId: await track('Track $i'),
              startedAt: DateTime.utc(2026, 1, i + 1),
            ));
      }

      final page = await home.watchHome().first;

      expect(page.single.items, hasLength(2));
    });
  });

  group('arranging', () {
    test('sections come back in the order they were put in', () async {
      await section(title: 'First');
      await section(title: 'Second');
      await section(title: 'Third');

      final page = await home.watchHome().first;

      expect([for (final s in page) s.title], ['First', 'Second', 'Third']);
    });

    test('a section can be moved before another', () async {
      await section(title: 'First');
      final second = await section(title: 'Second');
      final third = await section(title: 'Third');

      await home.moveSection(third, beforeId: second);

      final page = await home.watchHome().first;
      expect([for (final s in page) s.title], ['First', 'Third', 'Second']);
    });

    test('an item can be moved into a group', () async {
      final sectionId = await section();
      final collection = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Box',
      );
      final item = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.album,
        refId: await album('Loose'),
      );

      await home.moveItem(item, sectionId: sectionId, newParentId: collection);

      final page = await home.watchHome().first;
      expect(page.single.items, hasLength(1));
      expect(page.single.items.single.children.single.title, 'Loose');
    });

    test('a collection cannot be moved inside itself', () async {
      final sectionId = await section();
      final collection = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Box',
      );

      await home.moveItem(collection, sectionId: sectionId, newParentId: collection);

      final page = await home.watchHome().first;
      expect(page.single.items.single.title, 'Box',
          reason: 'still where it was, rather than lost');
    });

    test('a collection cannot be moved inside its own descendant', () async {
      // The arrangement that would otherwise detach a whole branch from the
      // page and leave it unreachable.
      final sectionId = await section();
      final outer = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Outer',
      );
      final inner = await home.addItem(
        sectionId: sectionId,
        parentId: outer,
        kind: HomeItemKind.collection,
        label: 'Inner',
      );

      await home.moveItem(outer, sectionId: sectionId, newParentId: inner);

      final page = await home.watchHome().first;
      expect(page.single.items.single.title, 'Outer');
      expect(page.single.items.single.children.single.title, 'Inner');
    });

    test('removing a collection takes what was inside it', () async {
      final sectionId = await section();
      final collection = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Box',
      );
      await home.addItem(
        sectionId: sectionId,
        parentId: collection,
        kind: HomeItemKind.album,
        refId: await album('Inside'),
      );

      await home.removeItem(collection);

      final page = await home.watchHome().first;
      expect(page.single.items, isEmpty);
    });
  });

  group('making a collection out of two items', () {
    test('the collection stands where the target did, and swallows it',
        () async {
      final sectionId = await section();
      final first = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.album,
        refId: await album('First'),
      );
      final target = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.album,
        refId: await album('Target'),
      );

      final made = await home.wrapInCollection(
        sectionId: sectionId,
        targetId: target,
      );

      final page = await home.watchHome().first;
      expect(made, isNotNull);
      // Still two things at the top level, in the same order -- the
      // collection is standing exactly where the target was.
      expect([for (final i in page.single.items) i.title],
          ['First', 'New collection']);
      expect(page.single.items.last.children.single.title, 'Target');
      expect(first, isNotNull);
    });

    test('made inside a collection, it nests one level deeper', () async {
      final sectionId = await section();
      final outer = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Outer',
      );
      final target = await home.addItem(
        sectionId: sectionId,
        parentId: outer,
        kind: HomeItemKind.album,
        refId: await album('Target'),
      );

      await home.wrapInCollection(sectionId: sectionId, targetId: target);

      final page = await home.watchHome().first;
      final made = page.single.items.single.children.single;
      expect(made.title, 'New collection');
      expect(made.children.single.title, 'Target');
    });

    test('a target that has gone leaves nothing behind', () async {
      final sectionId = await section();

      expect(
        await home.wrapInCollection(sectionId: sectionId, targetId: 999),
        isNull,
      );
      final page = await home.watchHome().first;
      expect(page.single.items, isEmpty, reason: 'no stray collection');
    });
  });

  group('a search inside a collection', () {
    test('resolves to items in the order it was given', () async {
      final sectionId = await section();
      final one = await track('One');
      final two = await track('Two');

      final items = await home.trackItems([two, one], sectionId);

      expect([for (final i in items) i.title], ['Two', 'One'],
          reason: "a search's own ranking is why it was asked");
    });

    test('its results are not for the user to rearrange', () async {
      final sectionId = await section();
      final items = await home.trackItems([await track('One')], sectionId);

      expect(items.single.isComputed, isTrue);
    });

    test('a track that has gone is skipped, not rendered empty', () async {
      final sectionId = await section();
      final real = await track('Real');

      final items = await home.trackItems([real, 999], sectionId);

      expect(items, hasLength(1));
      expect(items.single.title, 'Real');
    });
  });

  group('playing an item', () {
    test('an album plays in running order, not alphabetical', () async {
      final albumId = await album('Antenna');
      final second = await db.into(db.tracks).insert(TracksCompanion.insert(
            title: 'A second song',
            nameKey: 'a second song',
            albumId: Value(albumId),
            discNo: const Value(1),
            trackNo: const Value(2),
          ));
      final first = await db.into(db.tracks).insert(TracksCompanion.insert(
            title: 'Zebra',
            nameKey: 'zebra',
            albumId: Value(albumId),
            discNo: const Value(1),
            trackNo: const Value(1),
          ));

      expect(await home.tracksOfAlbum(albumId), [first, second]);
    });

    test('an artist plays everything they are credited on, guest spots too',
        () async {
      final who = await artist('Nanahira');
      final main = await track('Theirs');
      final guest = await track('Someone else\'s');
      await db.into(db.trackCredits).insert(TrackCreditsCompanion.insert(
            trackId: main,
            artistId: who,
          ));
      await db.into(db.trackCredits).insert(TrackCreditsCompanion.insert(
            trackId: guest,
            artistId: who,
            role: const Value(CreditRole.featured),
          ));

      expect(
        (await home.tracksOfArtist(who)).toSet(),
        {main, guest},
      );
    });
  });
}
