import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/home_repository.dart';
import 'package:marmelade/domain/models/home_views.dart';

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

  group('what a search is looking for', () {
    test('albums come back for the records a matching song sits on', () async {
      // The rule always describes a song -- "albums where" is the question of
      // which records contain one.
      final sectionId = await section();
      final albumId = await album('Antenna');
      final other = await album('Comic and Cosmic');
      final onIt = await track('A hardcore one', albumId: albumId);
      await track('Nothing to do with it', albumId: other);

      final items = await home.albumItemsFor([onIt], sectionId);

      expect([for (final one in items) one.title], ['Antenna']);
      expect(items.single.kind, HomeItemKind.album);
      expect(items.single.refId, albumId);
    });

    test('an album is named once however many of its songs matched', () async {
      final sectionId = await section();
      final albumId = await album('Antenna');
      final first = await track('One', albumId: albumId);
      final second = await track('Two', albumId: albumId);

      final items = await home.albumItemsFor([first, second], sectionId);

      expect(items, hasLength(1));
    });

    test('albums keep the order the songs matched in', () async {
      // A rule carries its own sort, which is the reason it was written that
      // way round -- re-alphabetising the answer throws that away.
      final sectionId = await section();
      final first = await album('Zebra');
      final second = await album('Antenna');
      final onFirst = await track('One', albumId: first);
      final onSecond = await track('Two', albumId: second);

      final items = await home.albumItemsFor([onFirst, onSecond], sectionId);

      expect([for (final one in items) one.title], ['Zebra', 'Antenna']);
    });

    test('a song on no album contributes no album', () async {
      final sectionId = await section();
      final loose = await track('A single');

      expect(await home.albumItemsFor([loose], sectionId), isEmpty);
    });

    test('artists come back for anyone credited, guests included', () async {
      final sectionId = await section();
      final main = await artist('Camellia');
      final guest = await artist('Nanahira');
      final trackId = await track('Together');
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(trackId: trackId, artistId: main),
          );
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(
              trackId: trackId,
              artistId: guest,
              role: const Value(CreditRole.featured),
              sortOrder: const Value(1),
            ),
          );

      final items = await home.artistItemsFor([trackId], sectionId);

      expect([for (final one in items) one.title], ['Camellia', 'Nanahira']);
      expect(items.first.kind, HomeItemKind.artist);
    });

    test('playlists come back for the ones listing a matching song', () async {
      final sectionId = await section();
      final trackId = await track('Listed');
      final playlistId = await db.into(db.playlists).insert(
            PlaylistsCompanion.insert(name: 'Mine', nameKey: 'mine'),
          );
      await db.into(db.playlistItems).insert(
            PlaylistItemsCompanion.insert(
              playlistId: playlistId,
              trackId: Value(trackId),
              position: 1000,
            ),
          );

      final items = await home.playlistItemsFor([trackId], sectionId);

      expect(items.single.title, 'Mine');
      expect(items.single.kind, HomeItemKind.playlist);
    });

    test('nothing matched means nothing comes back, of any type', () async {
      final sectionId = await section();

      expect(await home.albumItemsFor(const [], sectionId), isEmpty);
      expect(await home.artistItemsFor(const [], sectionId), isEmpty);
      expect(await home.playlistItemsFor(const [], sectionId), isEmpty);
      expect(await home.trackItems(const [], sectionId), isEmpty);
    });

    test('generated items are never the user’s to rearrange', () async {
      // Same rule as a computed section: they are not rows in `home_items`.
      final sectionId = await section();
      final albumId = await album('Antenna');
      final onIt = await track('One', albumId: albumId);

      final items = await home.albumItemsFor([onIt], sectionId);

      expect(items.single.isComputed, isTrue);
    });

    test('a stored search remembers what it was looking for', () async {
      final sectionId = await section();
      await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.query,
        label: 'Recent',
        query: 'tag:hardcore',
        queryType: HomeQueryType.artist,
      );

      final page = await home.watchHome().first;

      expect(page.single.items.single.queryType, HomeQueryType.artist);
      expect(
        page.single.items.single.querySentence,
        'Artists where tag:hardcore',
      );
    });

    test('a search defaults to albums when no type is given', () async {
      final sectionId = await section();
      await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.query,
        label: 'Recent',
        query: 'tag:hardcore',
      );

      final page = await home.watchHome().first;

      expect(page.single.items.single.queryType, HomeQueryType.album);
    });

    test('changing the type is stored, and the sentence follows', () async {
      final sectionId = await section();
      final id = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.query,
        label: 'Recent',
        query: 'tag:hardcore',
      );

      await home.setItemQuery(id, 'tag:remix', type: HomeQueryType.track);

      final page = await home.watchHome().first;
      expect(
        page.single.items.single.querySentence,
        'Songs where tag:remix',
      );
    });
  });

  group('how a search orders what it found', () {
    test('as found means the order the rule produced', () async {
      final sectionId = await section();
      final zebra = await album('Zebra');
      final antenna = await album('Antenna');
      final onZebra = await track('One', albumId: zebra);
      final onAntenna = await track('Two', albumId: antenna);

      final items = await home.albumItemsFor([onZebra, onAntenna], sectionId);

      expect([for (final one in items) one.title], ['Zebra', 'Antenna']);
    });

    test('by name overrides it', () async {
      final sectionId = await section();
      final zebra = await album('Zebra');
      final antenna = await album('Antenna');
      final onZebra = await track('One', albumId: zebra);
      final onAntenna = await track('Two', albumId: antenna);

      final items = await home.albumItemsFor(
        [onZebra, onAntenna],
        sectionId,
        sort: HomeQuerySort.name,
      );

      expect([for (final one in items) one.title], ['Antenna', 'Zebra']);
    });

    test('by name backwards is the other way round', () async {
      final sectionId = await section();
      final antenna = await album('Antenna');
      final zebra = await album('Zebra');
      final onAntenna = await track('One', albumId: antenna);
      final onZebra = await track('Two', albumId: zebra);

      final items = await home.albumItemsFor(
        [onAntenna, onZebra],
        sectionId,
        sort: HomeQuerySort.name,
        inverted: true,
      );

      expect([for (final one in items) one.title], ['Zebra', 'Antenna']);
    });

    test('by release year puts the newest first', () async {
      final sectionId = await section();
      final older = await db.into(db.albums).insert(
            AlbumsCompanion.insert(
              title: 'Older',
              nameKey: 'older',
              releaseYear: const Value(2001),
            ),
          );
      final newer = await db.into(db.albums).insert(
            AlbumsCompanion.insert(
              title: 'Newer',
              nameKey: 'newer',
              releaseYear: const Value(2023),
            ),
          );
      final onOlder = await track('One', albumId: older);
      final onNewer = await track('Two', albumId: newer);

      final items = await home.albumItemsFor(
        [onOlder, onNewer],
        sectionId,
        sort: HomeQuerySort.releaseYear,
      );

      expect([for (final one in items) one.title], ['Newer', 'Older']);
    });

    test('by number of songs counts the whole album, not the matches',
        () async {
      // "Albums where X" answers with records; how big a record is is a fact
      // about the record, not about how much of it tripped the rule.
      final sectionId = await section();
      final small = await album('Small');
      final big = await album('Big');
      final onSmall = await track('Only one', albumId: small);
      final onBig = await track('First', albumId: big);
      await track('Second', albumId: big);
      await track('Third', albumId: big);

      final items = await home.albumItemsFor(
        [onSmall, onBig],
        sectionId,
        sort: HomeQuerySort.trackCount,
      );

      expect([for (final one in items) one.title], ['Big', 'Small']);
    });

    test('songs can be ordered by how often they were played', () async {
      final sectionId = await section();
      final rare = await db.into(db.tracks).insert(
            TracksCompanion.insert(
              title: 'Rare',
              nameKey: 'rare',
              playCount: const Value(2),
            ),
          );
      final often = await db.into(db.tracks).insert(
            TracksCompanion.insert(
              title: 'Often',
              nameKey: 'often',
              playCount: const Value(90),
            ),
          );

      final items = await home.trackItems(
        [rare, often],
        sectionId,
        sort: HomeQuerySort.mostPlayed,
      );

      expect([for (final one in items) one.title], ['Often', 'Rare']);
    });

    test('artists can be ordered by name', () async {
      final sectionId = await section();
      final zed = await artist('Zed');
      final amy = await artist('Amy');
      final first = await track('One');
      final second = await track('Two');
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(trackId: first, artistId: zed),
          );
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(trackId: second, artistId: amy),
          );

      final items = await home.artistItemsFor(
        [first, second],
        sectionId,
        sort: HomeQuerySort.name,
      );

      expect([for (final one in items) one.title], ['Amy', 'Zed']);
    });

    test('a sort the kind cannot obey falls through to as found', () async {
      // The backstop behind HomeQuerySort.forType, which is what stops the UI
      // offering it. An artist has no release year to order by.
      final sectionId = await section();
      final zed = await artist('Zed');
      final amy = await artist('Amy');
      final first = await track('One');
      final second = await track('Two');
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(trackId: first, artistId: zed),
          );
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(trackId: second, artistId: amy),
          );

      final items = await home.artistItemsFor(
        [first, second],
        sectionId,
        sort: HomeQuerySort.releaseYear,
      );

      expect([for (final one in items) one.title], ['Zed', 'Amy']);
    });

    test('reversing the release year puts the oldest first', () async {
      // The reason the flag exists rather than a second enum value per
      // order: every order has an opposite, and this is how you ask for it.
      final sectionId = await section();
      final older = await db.into(db.albums).insert(
            AlbumsCompanion.insert(
              title: 'Older',
              nameKey: 'older',
              releaseYear: const Value(2001),
            ),
          );
      final newer = await db.into(db.albums).insert(
            AlbumsCompanion.insert(
              title: 'Newer',
              nameKey: 'newer',
              releaseYear: const Value(2023),
            ),
          );
      final onOlder = await track('One', albumId: older);
      final onNewer = await track('Two', albumId: newer);

      final items = await home.albumItemsFor(
        [onOlder, onNewer],
        sectionId,
        sort: HomeQuerySort.releaseYear,
        inverted: true,
      );

      expect([for (final one in items) one.title], ['Older', 'Newer']);
    });

    test('reversing songs by play count puts the least played first',
        () async {
      final sectionId = await section();
      final rare = await db.into(db.tracks).insert(
            TracksCompanion.insert(
              title: 'Rare',
              nameKey: 'rare',
              playCount: const Value(2),
            ),
          );
      final often = await db.into(db.tracks).insert(
            TracksCompanion.insert(
              title: 'Often',
              nameKey: 'often',
              playCount: const Value(90),
            ),
          );

      final items = await home.trackItems(
        [rare, often],
        sectionId,
        sort: HomeQuerySort.mostPlayed,
        inverted: true,
      );

      expect([for (final one in items) one.title], ['Rare', 'Often']);
    });

    test('reversing "as found" reads the ranking backwards',
        () async {
      // There is no column to turn around here, so this is the one case the
      // reversal happens in Dart -- and the one it would be easiest to leave
      // doing nothing at all.
      final sectionId = await section();
      final first = await track('One');
      final second = await track('Two');
      final third = await track('Three');

      final items = await home.trackItems(
        [first, second, third],
        sectionId,
        inverted: true,
      );

      expect([for (final one in items) one.title], ['Three', 'Two', 'One']);
    });

    test('reversing "as found" reaches the kinds a song stands in for',
        () async {
      // Albums, artists and playlists come back through a different path
      // from songs, and that path does its own ordering.
      final sectionId = await section();
      final antenna = await album('Antenna');
      final zebra = await album('Zebra');
      final onAntenna = await track('One', albumId: antenna);
      final onZebra = await track('Two', albumId: zebra);

      final items = await home.albumItemsFor(
        [onAntenna, onZebra],
        sectionId,
        inverted: true,
      );

      expect([for (final one in items) one.title], ['Zebra', 'Antenna']);
    });

    test('a shuffle has no reverse to ask for', () async {
      // Offered nowhere in the UI, and harmless if it arrives anyway: the
      // alternative is an ORDER BY of RANDOM() DESC, which is neither more
      // nor less random but does look like somebody meant something by it.
      expect(HomeQuerySort.random.canInvert, isFalse);
      expect(HomeQuerySort.releaseYear.canInvert, isTrue);
    });

    test('the options offered depend on what is being looked for', () async {
      // A release year means nothing for an artist and a track count means
      // nothing for one song.
      expect(
        HomeQuerySort.forType(HomeQueryType.artist),
        isNot(contains(HomeQuerySort.releaseYear)),
      );
      expect(
        HomeQuerySort.forType(HomeQueryType.track),
        isNot(contains(HomeQuerySort.trackCount)),
      );
      expect(
        HomeQuerySort.forType(HomeQueryType.album),
        contains(HomeQuerySort.releaseYear),
      );
      // A mixed answer can only be ordered by what every kind in it shares.
      expect(
        HomeQuerySort.forType(HomeQueryType.any),
        [
          HomeQuerySort.matched,
          HomeQuerySort.name,
          HomeQuerySort.random,
        ],
      );
      // "As found" is always available, because it is always meaningful.
      for (final type in HomeQueryType.values) {
        expect(
          HomeQuerySort.forType(type),
          contains(HomeQuerySort.matched),
          reason: type.name,
        );
      }
    });

    test('the sentence mentions the order only when there is one', () async {
      final sectionId = await section();
      final plain = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.query,
        query: 'tag:hardcore',
      );
      await home.setItemQuery(
        plain,
        'tag:hardcore',
        type: HomeQueryType.album,
        sort: HomeQuerySort.matched,
      );

      var page = await home.watchHome().first;
      expect(
        page.single.items.single.querySentence,
        'Albums where tag:hardcore',
      );

      await home.setItemQuery(
        plain,
        'tag:hardcore',
        type: HomeQueryType.album,
        sort: HomeQuerySort.releaseYear,
      );

      page = await home.watchHome().first;
      expect(
        page.single.items.single.querySentence,
        'Albums where tag:hardcore, by release year',
      );

      await home.setItemQuery(
        plain,
        'tag:hardcore',
        type: HomeQueryType.album,
        sort: HomeQuerySort.releaseYear,
        inverted: true,
      );

      page = await home.watchHome().first;
      expect(
        page.single.items.single.querySentence,
        'Albums where tag:hardcore, by release year, reversed',
      );
    });

    test('a reversed "as found" says so, where a plain one says nothing',
        () async {
      // The sort is normally left out when it is the default, because it
      // tells the reader nothing. Reversed it is the only sign the list is
      // deliberately back to front rather than simply strange.
      final sectionId = await section();
      final item = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.query,
        query: 'tag:hardcore',
        queryType: HomeQueryType.album,
        queryInverted: true,
      );
      expect(item, isPositive);

      final page = await home.watchHome().first;
      expect(
        page.single.items.single.querySentence,
        'Albums where tag:hardcore, last match first',
      );
    });
  });

  group('what a collection tile shows', () {
    /// An item with a picture, of whichever kind.
    HomeItemView pictured(
      String title, {
      required int id,
      required String path,
      HomeItemKind kind = HomeItemKind.album,
    }) =>
        HomeItemView(
          id: id,
          kind: kind,
          title: title,
          refId: id,
          imagePath: path,
        );

    test('the first four of its contents, in order', () async {
      final collection = HomeItemView(
        id: 1,
        kind: HomeItemKind.collection,
        title: 'Mixed',
        children: [
          for (var i = 0; i < 6; i++)
            pictured('Album $i', id: i + 10, path: 'cover-$i.jpg'),
        ],
      );

      expect(
        [for (final cover in collection.covers()) cover.path],
        ['cover-0.jpg', 'cover-1.jpg', 'cover-2.jpg', 'cover-3.jpg'],
      );
    });

    test('an artist among them is marked round', () async {
      // Round means a person everywhere else in the app, and a quartered
      // tile would be the one place it did not.
      final collection = HomeItemView(
        id: 1,
        kind: HomeItemKind.collection,
        title: 'Mixed',
        children: [
          pictured('An album', id: 10, path: 'a.jpg'),
          pictured(
            'A person',
            id: 11,
            path: 'b.jpg',
            kind: HomeItemKind.artist,
          ),
        ],
      );

      final covers = collection.covers();
      expect(covers.map((c) => c.round).toList(), [false, true]);
    });

    test('the same picture twice counts once', () async {
      // Six albums by one artist should not offer that face six times.
      final collection = HomeItemView(
        id: 1,
        kind: HomeItemKind.collection,
        title: 'Mixed',
        children: [
          pictured('One', id: 10, path: 'same.jpg'),
          pictured('Two', id: 11, path: 'same.jpg'),
          pictured('Three', id: 12, path: 'other.jpg'),
        ],
      );

      expect(
        [for (final cover in collection.covers()) cover.path],
        ['same.jpg', 'other.jpg'],
      );
    });

    test('a picture of its own wins over composing one', () async {
      final collection = HomeItemView(
        id: 1,
        kind: HomeItemKind.collection,
        title: 'Mixed',
        imagePath: 'chosen.jpg',
        children: [pictured('One', id: 10, path: 'ignored.jpg')],
      );

      expect(collection.covers().first.path, 'chosen.jpg');
    });

    test('it reaches into a nested collection for them', () async {
      // A collection of collections whose own tiles are mosaics would
      // otherwise compose a mosaic of nothing.
      final collection = HomeItemView(
        id: 1,
        kind: HomeItemKind.collection,
        title: 'Outer',
        children: [
          HomeItemView(
            id: 2,
            kind: HomeItemKind.collection,
            title: 'Inner',
            children: [pictured('Deep', id: 10, path: 'deep.jpg')],
          ),
        ],
      );

      expect([for (final c in collection.covers()) c.path], ['deep.jpg']);
    });
  });

  group('choosing a collection picture', () {
    test('one of its own items can be made the picture', () async {
      final sectionId = await section();
      final imageId = await db.into(db.images).insert(
            ImagesCompanion.insert(
              sha256: 'abc',
              storedPath: 'ab/abc.jpg',
              mimeType: 'image/jpeg',
              byteSize: 10,
              kind: ImageKind.userProvided,
            ),
          );
      final collectionId = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Mixed',
      );

      final ok = await home.setItemImageFromPath(collectionId, 'ab/abc.jpg');

      expect(ok, isTrue);
      final page = await home.watchHome().first;
      expect(page.single.items.single.imagePath, 'ab/abc.jpg');
      expect(imageId, isNotNull);
    });

    test('a path nothing is stored under is refused, not guessed at',
        () async {
      final sectionId = await section();
      final collectionId = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Mixed',
      );

      expect(
        await home.setItemImageFromPath(collectionId, 'nope/missing.jpg'),
        isFalse,
      );
    });

    test('clearing it goes back to composing one', () async {
      final sectionId = await section();
      await db.into(db.images).insert(
            ImagesCompanion.insert(
              sha256: 'abc',
              storedPath: 'ab/abc.jpg',
              mimeType: 'image/jpeg',
              byteSize: 10,
              kind: ImageKind.userProvided,
            ),
          );
      final collectionId = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Mixed',
      );
      await home.setItemImageFromPath(collectionId, 'ab/abc.jpg');

      await home.setItemImage(collectionId, null);

      final page = await home.watchHome().first;
      expect(page.single.items.single.imagePath, isNull);
    });

    test('a custom file needs a store, and says so rather than half-working',
        () async {
      // This repository is built without one in tests that only read and
      // rearrange; the real provider always passes it.
      final sectionId = await section();
      final collectionId = await home.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Mixed',
      );

      expect(
        await home.setItemPicture(collectionId, File('nothing.png')),
        isFalse,
      );
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
