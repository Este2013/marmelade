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
      await db.customStatement('PRAGMA user_version = 1');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 3);
    expect(await hasTable(db, 'playlist_tags'), isTrue);
    expect(await hasTable(db, 'playlist_track_order'), isTrue);
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
      await db.customStatement('PRAGMA user_version = 2');
    });
    addTearDown(db.close);

    expect(await versionOf(db), 3);
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
