import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/playlist_repository.dart';

/// Playlists, and the nesting that makes them interesting.
///
/// A playlist holds tracks *and* other playlists. Every operation that walks
/// that structure has to survive a cycle, because a playlist containing itself
/// is a mistake someone will make and an infinite recursion is a much worse
/// answer than a refusal.
void main() {
  late MarmeladeDatabase db;
  late PlaylistRepository repository;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    repository = PlaylistRepository(db: db, searchIndexer: SearchIndexer(db));
  });

  tearDown(() async => db.close());

  Future<int> track(String title, {int durationMs = 180000}) =>
      db.into(db.tracks).insert(TracksCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            durationMs: Value(durationMs),
          ));

  Future<List<String>> titlesOf(int playlistId) async {
    final ids = await repository.resolveTrackIds(playlistId);
    final titles = <String>[];
    for (final id in ids) {
      final row = await db
          .customSelect(
            'SELECT title FROM tracks WHERE id = ?1',
            variables: [Variable(id)],
          )
          .getSingle();
      titles.add(row.read<String>('title'));
    }
    return titles;
  }

  group('creating', () {
    test('a playlist is created with a normalised key', () async {
      final id = await repository.create('  Late Night  ');
      expect(id, isNotNull);

      final row = await db
          .customSelect(
            'SELECT name, name_key, kind FROM playlists WHERE id = ?1',
            variables: [Variable(id!)],
          )
          .getSingle();
      expect(row.read<String>('name'), 'Late Night');
      expect(row.read<String>('name_key'), 'late night');
      expect(row.read<String>('kind'), 'manual');
    });

    test('an empty name is refused', () async {
      expect(await repository.create('   '), isNull);
      final rows = await db.customSelect('SELECT id FROM playlists').get();
      expect(rows, isEmpty);
    });

    test('the tree comes back parent-then-child, with a depth', () async {
      final parent = (await repository.create('Electronic'))!;
      final child = (await repository.create('Hardcore', parentId: parent))!;
      await repository.create('Ambient', parentId: parent);
      final grandchild =
          (await repository.create('Speedcore', parentId: child))!;

      final tree = await repository.watchPlaylists().first;
      expect(
        tree.map((p) => (p.name, p.depth)),
        [
          ('Electronic', 0),
          ('Ambient', 1),
          ('Hardcore', 1),
          ('Speedcore', 2),
        ],
      );
      expect(tree.firstWhere((p) => p.id == grandchild).parentId, child);
    });

    test('nesting stops at the depth limit', () async {
      var parent = (await repository.create('0'))!;
      for (var i = 1; i < PlaylistRepository.maxDepth; i++) {
        final next = await repository.create('$i', parentId: parent);
        expect(next, isNotNull, reason: 'depth $i should be allowed');
        parent = next!;
      }
      // One past the limit is refused rather than silently flattened.
      expect(await repository.create('too deep', parentId: parent), isNull);
    });
  });

  group('tracks', () {
    test('tracks are appended in order and counted', () async {
      final id = (await repository.create('Mix'))!;
      final one = await track('One');
      final two = await track('Two');
      await repository.addTracks(id, [one, two]);
      await repository.addTracks(id, [await track('Three')]);

      expect(await titlesOf(id), ['One', 'Two', 'Three']);
      final card = (await repository.watchPlaylist(id).first)!;
      expect(card.trackCount, 3);
      expect(card.totalDuration, const Duration(minutes: 9));
    });

    test('a track added twice stays twice', () async {
      // It was put there twice; collapsing it would make the count disagree
      // with the list.
      final id = (await repository.create('Mix'))!;
      final one = await track('One');
      await repository.addTracks(id, [one, one]);
      expect(await titlesOf(id), ['One', 'One']);
    });

    test('an entry can be removed by its own row, not by its track',
        () async {
      final id = (await repository.create('Mix'))!;
      final one = await track('One');
      await repository.addTracks(id, [one, one]);

      final entries = await repository.watchEntries(id).first;
      await repository.removeEntry(entries.first.itemId);
      expect(await titlesOf(id), ['One']);
    });

    test('reordering renumbers densely', () async {
      final id = (await repository.create('Mix'))!;
      for (final title in ['A', 'B', 'C', 'D']) {
        await repository.addTracks(id, [await track(title)]);
      }

      var entries = await repository.watchEntries(id).first;
      // Move the last to the front.
      await repository.moveEntry(id, entries.last.itemId, 0);
      expect(await titlesOf(id), ['D', 'A', 'B', 'C']);

      entries = await repository.watchEntries(id).first;
      expect(entries.map((e) => e.position), [0, 1, 2, 3]);
    });

    test('clearing empties it without deleting it', () async {
      final id = (await repository.create('Mix'))!;
      await repository.addTracks(id, [await track('One')]);
      await repository.clear(id);

      expect(await titlesOf(id), isEmpty);
      expect(await repository.watchPlaylist(id).first, isNotNull);
    });
  });

  group('nesting', () {
    test('an included playlist contributes its tracks in place', () async {
      final outer = (await repository.create('Everything'))!;
      final inner = (await repository.create('Hardcore'))!;
      await repository.addTracks(inner, [
        await track('Fast'),
        await track('Faster'),
      ]);
      await repository.addTracks(outer, [await track('First')]);
      expect(await repository.addChildPlaylist(outer, inner), isTrue);
      await repository.addTracks(outer, [await track('Last')]);

      expect(
        await titlesOf(outer),
        ['First', 'Fast', 'Faster', 'Last'],
      );
    });

    test('a change to the child shows up in the parent', () async {
      // The whole point of including rather than copying.
      final outer = (await repository.create('Everything'))!;
      final inner = (await repository.create('Hardcore'))!;
      await repository.addChildPlaylist(outer, inner);
      expect(await titlesOf(outer), isEmpty);

      await repository.addTracks(inner, [await track('New')]);
      expect(await titlesOf(outer), ['New']);
    });

    test('a playlist cannot include itself', () async {
      final id = (await repository.create('Mix'))!;
      expect(await repository.addChildPlaylist(id, id), isFalse);
      expect(await repository.watchEntries(id).first, isEmpty);
    });

    test('a cycle is refused before it is created', () async {
      final a = (await repository.create('A'))!;
      final b = (await repository.create('B'))!;
      final c = (await repository.create('C'))!;
      expect(await repository.addChildPlaylist(a, b), isTrue);
      expect(await repository.addChildPlaylist(b, c), isTrue);

      // C including A would close the loop A -> B -> C -> A.
      expect(await repository.addChildPlaylist(c, a), isFalse);
      expect(await repository.watchEntries(c).first, isEmpty);
    });

    test('resolving survives a cycle that exists anyway', () async {
      // The check refuses new cycles, but a database written by an older build
      // or edited by hand could hold one. Resolving must stop, not hang.
      final a = (await repository.create('A'))!;
      final b = (await repository.create('B'))!;
      await repository.addTracks(a, [await track('In A')]);
      await repository.addTracks(b, [await track('In B')]);
      await repository.addChildPlaylist(a, b);
      // Forced past the guard, the way a corrupted row would be.
      await db.into(db.playlistItems).insert(
            PlaylistItemsCompanion.insert(
              playlistId: b,
              childPlaylistId: Value(a),
              position: 99,
            ),
          );

      expect(await titlesOf(a), ['In A', 'In B']);
    });

    test('a diamond contributes the shared playlist through both branches',
        () async {
      // Outer includes A and B; both include C. C's tracks belong in both
      // places, and a guard that remembered every playlist it had ever seen
      // would drop the second copy.
      final outer = (await repository.create('Outer'))!;
      final a = (await repository.create('A'))!;
      final b = (await repository.create('B'))!;
      final c = (await repository.create('C'))!;
      await repository.addTracks(c, [await track('Shared')]);
      await repository.addChildPlaylist(a, c);
      await repository.addChildPlaylist(b, c);
      await repository.addChildPlaylist(outer, a);
      await repository.addChildPlaylist(outer, b);

      expect(await titlesOf(outer), ['Shared', 'Shared']);
    });

    test('the same playlist included twice contributes twice', () async {
      final outer = (await repository.create('Outer'))!;
      final inner = (await repository.create('Inner'))!;
      await repository.addTracks(inner, [await track('Song')]);
      await repository.addChildPlaylist(outer, inner);
      await repository.addChildPlaylist(outer, inner);

      expect(await titlesOf(outer), ['Song', 'Song']);
    });
  });

  group('reparenting', () {
    test('a playlist can be moved and returned to the top level', () async {
      final parent = (await repository.create('Parent'))!;
      final child = (await repository.create('Child'))!;

      expect(await repository.reparent(child, parent), isTrue);
      expect(
        (await repository.watchPlaylist(child).first)!.parentId,
        parent,
      );

      expect(await repository.reparent(child, null), isTrue);
      expect((await repository.watchPlaylist(child).first)!.parentId, isNull);
    });

    test('a playlist cannot be moved inside its own descendant', () async {
      final parent = (await repository.create('Parent'))!;
      final child = (await repository.create('Child', parentId: parent))!;
      expect(await repository.reparent(parent, child), isFalse);
      expect(await repository.reparent(parent, parent), isFalse);
    });
  });

  group('deleting', () {
    test('deleting takes the nested playlists with it', () async {
      final parent = (await repository.create('Parent'))!;
      final child = (await repository.create('Child', parentId: parent))!;
      await repository.create('Grandchild', parentId: child);
      await repository.create('Unrelated');

      await repository.delete(parent);

      final left = await repository.watchPlaylists().first;
      expect(left.map((p) => p.name), ['Unrelated']);
    });

    test('deleting a child does not disturb a playlist that included it',
        () async {
      final outer = (await repository.create('Outer'))!;
      final inner = (await repository.create('Inner'))!;
      await repository.addTracks(outer, [await track('Kept')]);
      await repository.addChildPlaylist(outer, inner);

      await repository.delete(inner);

      // The inclusion row goes with the child, by the schema's cascade.
      expect(await titlesOf(outer), ['Kept']);
      expect(await repository.watchEntries(outer).first, hasLength(1));
    });
  });
}
