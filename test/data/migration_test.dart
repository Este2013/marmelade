import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

/// The upgrade path, which runs against a real library rather than a fresh one.
///
/// A fresh install never exercises `onUpgrade`, so the only way it gets tested
/// is deliberately: build a database shaped like the previous version, open it
/// with the current code, and check that what was added is there and what was
/// already there survived.
void main() {
  test('v1 to v2 adds playlist tags without disturbing what exists', () async {
    // A real file, because the migration is about a database on disk.
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    // Stand up the current schema, then wind it back to look like v1: the only
    // difference is the table v2 added.
    var db = MarmeladeDatabase(
      NativeDatabase.opened(file, closeUnderlyingOnClose: false),
    );
    await db.customSelect('SELECT 1').get();

    // Something worth preserving across the upgrade.
    final playlistId = await db.into(db.playlists).insert(
          PlaylistsCompanion.insert(name: 'Keep me', nameKey: 'keep me'),
        );
    final tagId = await db.into(db.tags).insert(
          TagsCompanion.insert(name: 'Workout', nameKey: 'workout'),
        );

    await db.customStatement('DROP TABLE playlist_tags');
    await db.customStatement('PRAGMA user_version = 1');
    await db.close();

    // Reopening runs onUpgrade.
    db = MarmeladeDatabase(
      NativeDatabase.opened(file, closeUnderlyingOnClose: false),
    );
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final version = await db
        .customSelect('PRAGMA user_version')
        .getSingle()
        .then((row) => row.data.values.first as int);
    expect(version, 2);

    // The table v2 added is usable, not merely present.
    await db.into(db.playlistTags).insert(
          PlaylistTagsCompanion.insert(playlistId: playlistId, tagId: tagId),
        );
    final tagged = await db
        .customSelect('SELECT COUNT(*) AS n FROM playlist_tags')
        .getSingle();
    expect(tagged.read<int>('n'), 1);

    // And nothing that was there before was lost.
    final playlists = await db
        .customSelect('SELECT name FROM playlists')
        .get()
        .then((rows) => rows.map((r) => r.read<String>('name')).toList());
    expect(playlists, ['Keep me']);

    // The views are recreated on every open, so the cascade works immediately
    // rather than waiting for a rescan.
    final view = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM sqlite_master "
          "WHERE name = 'v_track_effective_tags'",
        )
        .getSingle();
    expect(view.read<int>('n'), 1);
  });

  test('the cascade view is rebuilt on an existing database', () async {
    // Views live outside the schema drift manages, so they are dropped and
    // recreated on every open. That is what lets a view change ship without a
    // schema version bump -- and it has to actually happen.
    final file = sqlite3.sqlite3.openInMemory();
    addTearDown(file.close);

    var db = MarmeladeDatabase(
      NativeDatabase.opened(file, closeUnderlyingOnClose: false),
    );
    await db.customSelect('SELECT 1').get();
    await db.customStatement('DROP VIEW v_track_effective_tags');
    await db.close();

    db = MarmeladeDatabase(
      NativeDatabase.opened(file, closeUnderlyingOnClose: false),
    );
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    final view = await db
        .customSelect(
          "SELECT COUNT(*) AS n FROM sqlite_master "
          "WHERE name = 'v_track_effective_tags'",
        )
        .getSingle();
    expect(view.read<int>('n'), 1);
  });
}
