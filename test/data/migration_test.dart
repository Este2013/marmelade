import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// The upgrade path, which runs against a real library rather than a fresh one.
///
/// A fresh install never exercises `onUpgrade`, so the only way it gets tested
/// is deliberately: build a database shaped like an older version, open it with
/// the current code, and check that what was added is there and what was
/// already there survived.
///
/// "Shaped like an older version" is made by standing up the current schema and
/// winding it back, which is the only way to get one without keeping a copy of
/// every schema ever shipped. Each step below therefore has to undo exactly
/// what its migration does.
void main() {
  /// Opens [file] with the current schema, runs [wind] to make it look older,
  /// then reopens it so `onUpgrade` runs.
  Future<MarmeladeDatabase> reopenAfter(
    sqlite3.Database file,
    Future<void> Function(MarmeladeDatabase db) wind,
  ) async {
    var db = MarmeladeDatabase(
      NativeDatabase.opened(file, closeUnderlyingOnClose: false),
    );
    await db.customSelect('SELECT 1').get();
    await wind(db);
    await db.close();

    db = MarmeladeDatabase(
      NativeDatabase.opened(file, closeUnderlyingOnClose: false),
    );
    await db.customSelect('SELECT 1').get();
    return db;
  }

  Future<int> versionOf(MarmeladeDatabase db) => db
      .customSelect('PRAGMA user_version')
      .getSingle()
      .then((row) => row.data.values.first as int);

  Future<Set<String>> columnsOf(MarmeladeDatabase db, String table) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return {for (final row in rows) row.read<String>('name')};
  }

  Future<bool> hasTable(MarmeladeDatabase db, String name) async {
    final row = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM sqlite_master WHERE name = '$name'",
        )
        .getSingle();
    return row.read<int>('n') > 0;
  }

  test('v1 upgrades all the way, keeping what was there', () async {
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    late int playlistId;
    late int tagId;

    final db = await reopenAfter(file, (db) async {
      // Something worth preserving across two migrations.
      playlistId = await db.into(db.playlists).insert(
            PlaylistsCompanion.insert(name: 'Keep me', nameKey: 'keep me'),
          );
      tagId = await db.into(db.tags).insert(
            TagsCompanion.insert(name: 'Workout', nameKey: 'workout'),
          );

      // Undo v3, then v2.
      await db.customStatement('DROP TABLE playlist_track_order');
      await db.customStatement('ALTER TABLE playlists DROP COLUMN group_by');
      await db.customStatement(
        'ALTER TABLE playlists DROP COLUMN sort_descending',
      );
      await db.customStatement('ALTER TABLE playlists DROP COLUMN display_sort');
      await db.customStatement('DROP TABLE playlist_tags');
      // Undo v4.
      await db.customStatement('DROP TABLE home_items');
      await db.customStatement('DROP TABLE home_sections');
      await db.customStatement('PRAGMA user_version = 1');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 11);
    expect(await hasTable(db, 'playlist_tags'), isTrue);
    expect(await hasTable(db, 'playlist_track_order'), isTrue);
    expect(await hasTable(db, 'home_sections'), isTrue);
    expect(await hasTable(db, 'home_items'), isTrue);
    expect(
      await columnsOf(db, 'playlists'),
      containsAll(['display_sort', 'sort_descending', 'group_by']),
    );

    // Usable, not merely present.
    await db.into(db.playlistTags).insert(
          PlaylistTagsCompanion.insert(playlistId: playlistId, tagId: tagId),
        );
    final tagged =
        await db.customSelect('SELECT COUNT(*) AS n FROM playlist_tags')
            .getSingle();
    expect(tagged.read<int>('n'), 1);

    // And nothing that was there before was lost.
    final playlists = await db
        .customSelect('SELECT name, display_sort FROM playlists')
        .get();
    expect(playlists.single.read<String>('name'), 'Keep me');
    // The added column takes its default on rows that predate it, rather than
    // arriving null and breaking every read.
    expect(playlists.single.read<String>('display_sort'), 'added');
  });

  test('v2 upgrades to v3 without disturbing a playlist', () async {
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = await reopenAfter(file, (db) async {
      final id = await db.into(db.playlists).insert(
            PlaylistsCompanion.insert(name: 'Mine', nameKey: 'mine'),
          );
      final trackId = await db.into(db.tracks).insert(
            TracksCompanion.insert(title: 'Song', nameKey: 'song'),
          );
      await db.into(db.playlistItems).insert(
            PlaylistItemsCompanion.insert(
              playlistId: id,
              trackId: Value(trackId),
              position: 0,
            ),
          );

      await db.customStatement('DROP TABLE playlist_track_order');
      await db.customStatement('ALTER TABLE playlists DROP COLUMN group_by');
      await db.customStatement(
        'ALTER TABLE playlists DROP COLUMN sort_descending',
      );
      await db.customStatement('ALTER TABLE playlists DROP COLUMN display_sort');
      await db.customStatement('DROP TABLE home_items');
      await db.customStatement('DROP TABLE home_sections');
      await db.customStatement('PRAGMA user_version = 2');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 11);
    expect(await hasTable(db, 'playlist_track_order'), isTrue);

    final rows = await db
        .customSelect(
          'SELECT p.name AS name, p.display_sort AS sort, p.group_by AS grouped,'
          ' (SELECT COUNT(*) FROM playlist_items i '
          '   WHERE i.playlist_id = p.id) AS items '
          'FROM playlists p',
        )
        .getSingle();
    expect(rows.read<String>('name'), 'Mine');
    expect(rows.read<int>('items'), 1);
    // The defaults are the old behaviour: a playlist stays in the order things
    // were added, ungrouped, until someone says otherwise.
    expect(rows.read<String>('sort'), 'added');
    expect(rows.read<String>('grouped'), 'none');
  });

  test('v3 gains a home page with its one section already on it', () async {
    // An existing library must not arrive at a home page that is simply
    // blank: an empty home page and a broken one look identical, so the
    // upgrade seeds the same starting section a fresh install gets.
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = await reopenAfter(file, (db) async {
      await db.customStatement('DROP TABLE home_items');
      await db.customStatement('DROP TABLE home_sections');
      await db.customStatement('PRAGMA user_version = 3');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 11);

    final sections = await db
        .customSelect('SELECT title, source, layout FROM home_sections')
        .get();
    expect(sections, hasLength(1));
    expect(sections.single.read<String>('source'), 'recentlyPlayed');
    expect(sections.single.read<String>('title'), 'Recently played');
  });

  test('a home item is taken with its section, not orphaned', () async {
    // The cascade is the only thing keeping a removed section from leaving
    // its items behind as rows nothing can reach or clean up.
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = MarmeladeDatabase(
      NativeDatabase.opened(file, closeUnderlyingOnClose: false),
    );
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final sectionId = await db.into(db.homeSections).insert(
          HomeSectionsCompanion.insert(title: 'Mine', position: 1000),
        );
    final groupId = await db.into(db.homeItems).insert(
          HomeItemsCompanion.insert(
            sectionId: sectionId,
            position: 1000,
            kind: HomeItemKind.collection,
            label: const Value('A group'),
          ),
        );
    await db.into(db.homeItems).insert(
          HomeItemsCompanion.insert(
            sectionId: sectionId,
            parentId: Value(groupId),
            position: 1000,
            kind: HomeItemKind.album,
            refId: const Value(1),
          ),
        );

    await (db.delete(db.homeSections)..where((s) => s.id.equals(sectionId)))
        .go();

    final left =
        await db.customSelect('SELECT COUNT(*) AS n FROM home_items').getSingle();
    expect(left.read<int>('n'), 0, reason: 'nested items go too');
  });

  test('v4 renames a group item to a collection, keeping it', () async {
    // The kind is stored by name, and a name this code does not recognise is
    // dropped when the page is read -- so without this step an existing
    // home page would quietly lose every collection on it.
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = await reopenAfter(file, (db) async {
      final sectionId = await db.into(db.homeSections).insert(
            HomeSectionsCompanion.insert(title: 'Mine', position: 1000),
          );
      await db.into(db.homeItems).insert(
            HomeItemsCompanion.insert(
              sectionId: sectionId,
              position: 1000,
              kind: HomeItemKind.collection,
              label: const Value('Soundtracks'),
            ),
          );
      // Wind it back to what v4 would have written: the old kind name, and
      // without the two columns v6 adds.
      await db.customStatement(
        "UPDATE home_items SET kind = 'group' WHERE kind = 'collection'",
      );
      await db.customStatement(
        'ALTER TABLE home_sections DROP COLUMN collapsed',
      );
      await db.customStatement('ALTER TABLE home_sections DROP COLUMN icon');
      await db.customStatement('ALTER TABLE home_items DROP COLUMN query_type');
      await db.customStatement('ALTER TABLE home_items DROP COLUMN query_sort');
      await db.customStatement('ALTER TABLE home_items DROP COLUMN artwork_mode');
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN quadrant_images',
      );
      await db.customStatement('ALTER TABLE home_items DROP COLUMN collapsed');
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN query_inverted',
      );
      await db.customStatement('PRAGMA user_version = 4');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 11);
    final items =
        await db.customSelect('SELECT kind, label FROM home_items').get();
    expect(items.single.read<String>('kind'), 'collection');
    expect(items.single.read<String>('label'), 'Soundtracks');
  });

  test('v5 gains somewhere to store a collapsed section and its icon',
      () async {
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = await reopenAfter(file, (db) async {
      await db.into(db.homeSections).insert(
            HomeSectionsCompanion.insert(title: 'Mine', position: 1000),
          );
      await db.customStatement(
        'ALTER TABLE home_sections DROP COLUMN collapsed',
      );
      await db.customStatement('ALTER TABLE home_sections DROP COLUMN icon');
      await db.customStatement('ALTER TABLE home_items DROP COLUMN query_type');
      await db.customStatement('ALTER TABLE home_items DROP COLUMN query_sort');
      await db.customStatement('ALTER TABLE home_items DROP COLUMN artwork_mode');
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN quadrant_images',
      );
      await db.customStatement('ALTER TABLE home_items DROP COLUMN collapsed');
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN query_inverted',
      );
      await db.customStatement('PRAGMA user_version = 5');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 11);
    expect(
      await columnsOf(db, 'home_sections'),
      containsAll(['collapsed', 'icon']),
    );
    // Usable, and defaulted to what an existing section should look like.
    // A fresh database seeds a section of its own, so the one this test
    // wrote has to be asked for by name.
    final row = await db
        .customSelect(
          "SELECT title, collapsed, icon FROM home_sections "
          "WHERE title = 'Mine'",
        )
        .getSingle();
    expect(row.read<String>('title'), 'Mine');
    expect(row.read<bool>('collapsed'), isFalse);
    expect(row.read<int?>('icon'), isNull);
  });

  test('v6 pins an existing search to songs, not to the new default',
      () async {
    // A search written before v7 could only mean songs. Letting the column
    // default turn it into an album search would change what somebody's home
    // page shows, under them, without them touching it.
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = await reopenAfter(file, (db) async {
      final sectionId = await db.into(db.homeSections).insert(
            HomeSectionsCompanion.insert(title: 'Mine', position: 1000),
          );
      await db.into(db.homeItems).insert(
            HomeItemsCompanion.insert(
              sectionId: sectionId,
              position: 1000,
              kind: HomeItemKind.query,
              label: const Value('Old search'),
              query: const Value('tag:hardcore'),
            ),
          );
      await db.into(db.homeItems).insert(
            HomeItemsCompanion.insert(
              sectionId: sectionId,
              position: 2000,
              kind: HomeItemKind.album,
              refId: const Value(1),
            ),
          );
      await db.customStatement('ALTER TABLE home_items DROP COLUMN query_type');
      await db.customStatement('ALTER TABLE home_items DROP COLUMN query_sort');
      await db.customStatement('ALTER TABLE home_items DROP COLUMN artwork_mode');
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN quadrant_images',
      );
      await db.customStatement('ALTER TABLE home_items DROP COLUMN collapsed');
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN query_inverted',
      );
      await db.customStatement('PRAGMA user_version = 6');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 11);
    final rows = await db
        .customSelect('SELECT kind, query_type FROM home_items ORDER BY position')
        .get();
    expect(rows.first.read<String>('query_type'), 'track');
    // Only searches are touched; the column on everything else is meaningless
    // and left at whatever the default wrote.
    expect(rows.last.read<String>('kind'), 'album');
  });

  test('v7 gains somewhere to store how a search is ordered', () async {
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = await reopenAfter(file, (db) async {
      final sectionId = await db.into(db.homeSections).insert(
            HomeSectionsCompanion.insert(title: 'Mine', position: 1000),
          );
      await db.into(db.homeItems).insert(
            HomeItemsCompanion.insert(
              sectionId: sectionId,
              position: 1000,
              kind: HomeItemKind.query,
              query: const Value('tag:hardcore'),
            ),
          );
      await db.customStatement('ALTER TABLE home_items DROP COLUMN query_sort');
      await db.customStatement('ALTER TABLE home_items DROP COLUMN artwork_mode');
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN quadrant_images',
      );
      await db.customStatement('ALTER TABLE home_items DROP COLUMN collapsed');
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN query_inverted',
      );
      await db.customStatement('PRAGMA user_version = 7');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 11);
    // "As found" is what every search did before there was a choice.
    final row = await db
        .customSelect('SELECT query_sort FROM home_items')
        .getSingle();
    expect(row.read<String>('query_sort'), 'matched');
  });

  test('v8 moves a hand-picked collection picture to the whole tile',
      () async {
    // Before the mode existed, choosing a picture put it in the first
    // quarter of a mosaic -- which is not what choosing a picture means, and
    // is the bug this column was added to fix.
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = await reopenAfter(file, (db) async {
      final imageId = await db.into(db.images).insert(
            ImagesCompanion.insert(
              sha256: 'abc',
              storedPath: 'ab/abc.jpg',
              mimeType: 'image/jpeg',
              byteSize: 10,
              kind: ImageKind.userProvided,
            ),
          );
      final sectionId = await db.into(db.homeSections).insert(
            HomeSectionsCompanion.insert(title: 'Mine', position: 1000),
          );
      await db.into(db.homeItems).insert(
            HomeItemsCompanion.insert(
              sectionId: sectionId,
              position: 1000,
              kind: HomeItemKind.collection,
              label: const Value('Chosen'),
              imageId: Value(imageId),
            ),
          );
      await db.into(db.homeItems).insert(
            HomeItemsCompanion.insert(
              sectionId: sectionId,
              position: 2000,
              kind: HomeItemKind.collection,
              label: const Value('Composed'),
            ),
          );
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN artwork_mode',
      );
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN quadrant_images',
      );
      await db.customStatement('ALTER TABLE home_items DROP COLUMN collapsed');
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN query_inverted',
      );
      await db.customStatement('PRAGMA user_version = 8');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 11);
    final rows = await db
        .customSelect(
          'SELECT label, artwork_mode FROM home_items ORDER BY position',
        )
        .get();
    expect(rows.first.read<String>('artwork_mode'), 'single');
    // One that never had a picture keeps composing one.
    expect(rows.last.read<String>('artwork_mode'), 'quadrant');
  });

  test('v9 gains somewhere to roll a search up', () async {
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = await reopenAfter(file, (db) async {
      final sectionId = await db.into(db.homeSections).insert(
            HomeSectionsCompanion.insert(title: 'Mine', position: 1000),
          );
      await db.into(db.homeItems).insert(
            HomeItemsCompanion.insert(
              sectionId: sectionId,
              position: 1000,
              kind: HomeItemKind.query,
              query: const Value('tag:hardcore'),
            ),
          );
      await db.customStatement('ALTER TABLE home_items DROP COLUMN collapsed');
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN query_inverted',
      );
      await db.customStatement('PRAGMA user_version = 9');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 11);
    // Open is what every block already was.
    final row =
        await db.customSelect('SELECT collapsed FROM home_items').getSingle();
    expect(row.read<bool>('collapsed'), isFalse);
  });

  test('v10 keeps a Z-to-A search ordered Z to A', () async {
    // v11 made the direction a flag, which left `nameDescending` saying the
    // same thing twice. The value is gone, and an unrecognised sort reads
    // back as "as found" -- so without the rewrite a search somebody put in
    // reverse would quietly come back in whatever order the rule found
    // things in, on a page they never touched.
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = await reopenAfter(file, (db) async {
      final sectionId = await db.into(db.homeSections).insert(
            HomeSectionsCompanion.insert(title: 'Mine', position: 1000),
          );
      // Written as raw SQL: the value no longer exists to be named in Dart,
      // which is the whole situation being tested.
      await db.into(db.homeItems).insert(
            HomeItemsCompanion.insert(
              sectionId: sectionId,
              position: 1000,
              kind: HomeItemKind.query,
              query: const Value('tag:hardcore'),
            ),
          );
      await db.into(db.homeItems).insert(
            HomeItemsCompanion.insert(
              sectionId: sectionId,
              position: 2000,
              kind: HomeItemKind.query,
              query: const Value('tag:ambient'),
            ),
          );
      await db.customStatement(
        "UPDATE home_items SET query_sort = 'nameDescending' "
        "WHERE position = 1000",
      );
      await db.customStatement(
        "UPDATE home_items SET query_sort = 'releaseYear' WHERE position = 2000",
      );
      await db.customStatement(
        'ALTER TABLE home_items DROP COLUMN query_inverted',
      );
      await db.customStatement('PRAGMA user_version = 10');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 11);
    final rows = await db
        .customSelect(
          'SELECT query_sort, query_inverted FROM home_items ORDER BY position',
        )
        .get();
    expect(rows.first.read<String>('query_sort'), 'name');
    expect(rows.first.read<bool>('query_inverted'), isTrue);
    // Every other order is left alone, facing the way it always faced.
    expect(rows.last.read<String>('query_sort'), 'releaseYear');
    expect(rows.last.read<bool>('query_inverted'), isFalse);
  });

  test('the cascade view is rebuilt on an existing database', () async {
    // Views live outside the schema drift manages, so they are dropped and
    // recreated on every open. That is what lets a view change ship without a
    // schema version bump -- and it has to actually happen.
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    final db = await reopenAfter(file, (db) async {
      await db.customStatement('DROP VIEW v_track_effective_tags');
    });
    addTearDown(db.close);

    expect(await hasTable(db, 'v_track_effective_tags'), isTrue);
  });
}
