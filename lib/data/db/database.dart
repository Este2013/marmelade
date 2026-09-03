import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

import '../../core/logging/app_log.dart';
import '../../domain/credits/separator.dart';
import 'enums.dart';
import 'tables/catalog.dart';
import 'tables/images.dart';
import 'tables/library.dart';
import 'tables/playback.dart';
import 'tables/playlists.dart';
import 'tables/system.dart';
import 'tables/tags.dart';

export 'enums.dart';
export 'tables/catalog.dart';
export 'tables/images.dart';
export 'tables/library.dart';
export 'tables/playback.dart';
export 'tables/playlists.dart';
export 'tables/system.dart';
export 'tables/tags.dart';

part 'database.g.dart';

/// Name of the FTS5 table used for tokenised, ranked search.
///
/// Uses the `unicode61` tokenizer with diacritic folding, so "Bjork" finds
/// "Björk". Good for Latin scripts and prefix queries.
const ftsTokenTable = 'search_tokens';

/// Name of the FTS5 table used for substring search.
///
/// Uses the `trigram` tokenizer, which is what makes mid-word and CJK search
/// work at all: `unicode61` treats a run of Japanese characters as a single
/// token, so searching for a substring of it would never match. Requires at
/// least three characters in the query.
const ftsTrigramTable = 'search_trigrams';

/// Entity kinds that appear in the search index.
///
/// An enum rather than bare strings: the index stores short keys to stay small,
/// and callers used to pass the long word, so a delete matched nothing and a
/// reindex fell through its switch. Silently. The type now carries the key, so
/// the two cannot disagree.
enum SearchEntity {
  track('trk'),
  album('alb'),
  artist('art'),
  tag('tag'),
  playlist('pls');

  const SearchEntity(this.key);

  /// What goes in the index's `entity_type` column.
  final String key;
}

@DriftDatabase(
  tables: [
    // Physical layer
    LibraryFolders,
    MediaFiles,
    // Artwork
    Images,
    // Catalog
    Artists,
    ArtistAliases,
    ArtistLinks,
    ArtistMemberships,
    Albums,
    AlbumAliases,
    Tracks,
    TrackAliases,
    TrackCredits,
    AlbumCredits,
    // Tagging
    TagCategories,
    Tags,
    TagAliases,
    TrackTags,
    AlbumTags,
    ArtistTags,
    PlaylistTags,
    PlaylistTrackOrder,
    // Playlists
    Playlists,
    PlaylistItems,
    // Playback
    QueueItems,
    PlayHistory,
    Lyrics,
    // System
    Settings,
    ScanRuns,
    ScanIssues,
    SeparatorTokens,
    CreditSplitRules,
    PendingCredits,
  ],
)
class MarmeladeDatabase extends _$MarmeladeDatabase {
  MarmeladeDatabase(super.e);

  /// Opens the database at [path], creating its directory if needed.
  ///
  /// Runs on a background isolate so a long query cannot stall a frame.
  ///
  /// The path is supplied by the caller rather than resolved here: keeping
  /// `path_provider` - and therefore Flutter - out of the data layer is what
  /// lets the indexer and its command-line tools run under plain `dart run`,
  /// and keeps tests from needing a Flutter binding. See `app/storage_paths.dart`.
  static Future<MarmeladeDatabase> open(String path) async {
    await Directory(p.dirname(path)).create(recursive: true);
    return MarmeladeDatabase(
      NativeDatabase.createInBackground(File(path)),
    );
  }

  /// An in-memory database, for tests.
  static MarmeladeDatabase memory({bool logStatements = false}) =>
      MarmeladeDatabase(NativeDatabase.memory(logStatements: logStatements));

  @override
  int get schemaVersion => 3;

  /// Set when the `trigram` FTS5 tokenizer is unavailable in the linked
  /// SQLite build. Search then falls back to token and prefix matching only,
  /// which degrades substring and CJK search rather than breaking it.
  bool trigramSearchAvailable = true;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createSearchIndexes();
          await _createViews();
          await _seed();
        },
        onUpgrade: (m, from, to) async {
          // v2 added tags on playlists. Views and search indexes are recreated
          // on every open, so only the real table needs a step here.
          if (from < 2) {
            await m.createTable(playlistTags);
          }
          // v3 gave playlists a display order and a grouping, and somewhere to
          // record an order arranged by hand for the tracks a query found.
          if (from < 3) {
            await m.createTable(playlistTrackOrder);
            await m.addColumn(playlists, playlists.displaySort);
            await m.addColumn(playlists, playlists.sortDescending);
            await m.addColumn(playlists, playlists.groupBy);
          }
        },
        beforeOpen: (details) async {
          // Referential integrity is off by default in SQLite.
          await customStatement('PRAGMA foreign_keys = ON');
          // WAL keeps the UI readable while a scan writes.
          await customStatement('PRAGMA journal_mode = WAL');
          await customStatement('PRAGMA synchronous = NORMAL');
          // Roughly 64 MB of page cache; the library grids read widely.
          await customStatement('PRAGMA cache_size = -64000');
          await customStatement('PRAGMA temp_store = MEMORY');

          if (details.wasCreated) return;
          await _repairCorruptIndexesIfNeeded();
          // Virtual tables and views live outside the schema drift manages,
          // so make sure they exist on every open.
          await _createSearchIndexes();
          await _createViews();
        },
      );

  /// Repairs ordinary b-tree index corruption found at startup.
  ///
  /// `PRAGMA quick_check` walks every b-tree in the file -- what caught this
  /// on a database an unclean shutdown left with a torn write (see
  /// `sqlite_diagnostics.dart` for how a live query later tells that class of
  /// corruption apart from an ordinary failure). `REINDEX` rebuilds every
  /// index from its table's actual rows, repairing exactly the "wrong number
  /// of entries" and "missing from an index" damage quick_check reports,
  /// without touching the rows themselves. It knows nothing about FTS5's own
  /// shadow tables, though -- SearchIndexer.rebuildAll has that half
  /// covered, recreating them outright the next time anything writes to the
  /// search index.
  Future<void> _repairCorruptIndexesIfNeeded() async {
    Future<List<String>> check() async {
      final rows = await customSelect('PRAGMA quick_check').get();
      return rows
          .map((r) => r.data.values.first as String)
          .where((message) => message != 'ok')
          .toList();
    }

    final problems = await check();
    if (problems.isEmpty) return;

    AppLog.instance.error(
      'database integrity problems found at startup, repairing',
      tag: 'database',
      fields: {'count': problems.length, 'first': problems.first},
    );
    await customStatement('REINDEX');

    final remaining = await check();
    if (remaining.isEmpty) {
      AppLog.instance.warn('database repaired via REINDEX', tag: 'database');
    } else {
      AppLog.instance.error(
        'database still reports problems after REINDEX',
        tag: 'database',
        fields: {'count': remaining.length, 'first': remaining.first},
      );
    }
  }

  Future<void> _createSearchIndexes() async {
    await customStatement('''
      CREATE VIRTUAL TABLE IF NOT EXISTS $ftsTokenTable USING fts5(
        entity_type UNINDEXED,
        entity_id   UNINDEXED,
        title,
        aliases,
        secondary,
        tokenize = 'unicode61 remove_diacritics 2'
      )
    ''');

    try {
      await customStatement('''
        CREATE VIRTUAL TABLE IF NOT EXISTS $ftsTrigramTable USING fts5(
          entity_type UNINDEXED,
          entity_id   UNINDEXED,
          haystack,
          tokenize = 'trigram'
        )
      ''');
      trigramSearchAvailable = true;
    } catch (_) {
      // Older SQLite builds lack the trigram tokenizer. Degrade, do not fail.
      trigramSearchAvailable = false;
    }
  }

  /// Drops and recreates both FTS5 search tables, discarding their on-disk
  /// structure rather than just their rows.
  ///
  /// `_createSearchIndexes` uses `IF NOT EXISTS`, so it never repairs a
  /// table that already exists but is corrupt -- an emptied `DELETE FROM`
  /// does nothing for that either, since the rows are not the part that is
  /// broken. This is the one operation that actually resets the structure;
  /// see [SearchIndexer.rebuildAll] for where it is used, and
  /// `sqlite_diagnostics.dart` for how corruption is told apart from an
  /// ordinary query failure.
  Future<void> resetSearchIndexes() async {
    await customStatement('DROP TABLE IF EXISTS $ftsTokenTable');
    await customStatement('DROP TABLE IF EXISTS $ftsTrigramTable');
    await _createSearchIndexes();
  }

  /// Creates the artwork-resolution views.
  ///
  /// These encode the fallback chain in one place so every grid, list and
  /// player surface agrees on which image to show:
  ///
  ///   track  -> its own art, else its album's, else its main artist's
  ///   album  -> its own art, else its album artist's, else any track's
  Future<void> _createViews() async {
    await customStatement('DROP VIEW IF EXISTS v_track_artwork');
    await customStatement('''
      CREATE VIEW v_track_artwork AS
      SELECT
        t.id AS track_id,
        COALESCE(
          t.image_id,
          al.image_id,
          (SELECT ar.image_id FROM artists ar WHERE ar.id = al.album_artist_id),
          (SELECT ar2.image_id
             FROM track_credits tc
             JOIN artists ar2 ON ar2.id = tc.artist_id
            WHERE tc.track_id = t.id
              AND tc.role = 'mainArtist'
              AND ar2.image_id IS NOT NULL
            ORDER BY tc.sort_order, tc.id
            LIMIT 1)
        ) AS image_id
      FROM tracks t
      LEFT JOIN albums al ON al.id = t.album_id
    ''');

    await customStatement('DROP VIEW IF EXISTS v_album_artwork');
    await customStatement('''
      CREATE VIEW v_album_artwork AS
      SELECT
        a.id AS album_id,
        COALESCE(
          a.image_id,
          (SELECT ar.image_id FROM artists ar WHERE ar.id = a.album_artist_id),
          (SELECT t.image_id
             FROM tracks t
            WHERE t.album_id = a.id AND t.image_id IS NOT NULL
            ORDER BY t.disc_no, t.track_no, t.id
            LIMIT 1)
        ) AS image_id
      FROM albums a
    ''');

    await _createTagViews();
  }

  /// Creates the tag-cascade views.
  ///
  /// Tags are attached to tracks, albums, artists and playlists, and the ones
  /// on a container reach the tracks inside it: an album tagged "soundtrack"
  /// makes its tracks soundtrack tracks, and a playlist tagged "workout" makes
  /// everything it resolves to a workout track.
  ///
  /// That cascade lives here rather than in duplicated rows, which is the whole
  /// point: untagging the album untags its tracks with no bookkeeping, and
  /// nothing can drift out of step. The cost is that "the tags on this track"
  /// is a query rather than a lookup, which is what a view is for.
  ///
  /// Artist tags deliberately do *not* cascade. An artist tag says something
  /// about the artist -- "Japanese", "signed to Diverse System" -- and pushing
  /// it onto every track they ever guested on would make the track tags
  /// useless. Album and playlist tags describe a collection of music, which is
  /// what a track belongs to.
  Future<void> _createTagViews() async {
    await customStatement('DROP VIEW IF EXISTS v_playlist_tracks');
    // Recursive, because a playlist can include another. UNION rather than
    // UNION ALL: it deduplicates, which is also what stops a cycle from
    // looping forever.
    await customStatement('''
      CREATE VIEW v_playlist_tracks AS
      WITH RECURSIVE reach(playlist_id, track_id) AS (
        SELECT pi.playlist_id, pi.track_id
          FROM playlist_items pi
         WHERE pi.track_id IS NOT NULL AND pi.is_exclusion = 0
        UNION
        SELECT pi.playlist_id, r.track_id
          FROM playlist_items pi
          JOIN reach r ON r.playlist_id = pi.child_playlist_id
         WHERE pi.is_exclusion = 0
      )
      SELECT playlist_id, track_id FROM reach
    ''');

    await customStatement('DROP VIEW IF EXISTS v_track_effective_tags');
    await customStatement('''
      CREATE VIEW v_track_effective_tags AS
      SELECT track_id, tag_id, source FROM (
        SELECT tt.track_id AS track_id, tt.tag_id AS tag_id,
               'track' AS source
          FROM track_tags tt
        UNION
        SELECT t.id AS track_id, at.tag_id AS tag_id, 'album' AS source
          FROM tracks t
          JOIN album_tags at ON at.album_id = t.album_id
        UNION
        SELECT vpt.track_id AS track_id, pt.tag_id AS tag_id,
               'playlist' AS source
          FROM v_playlist_tracks vpt
          JOIN playlist_tags pt ON pt.playlist_id = vpt.playlist_id
      )
    ''');
  }

  /// Inserts the rows the app assumes exist: system tag categories and the
  /// default credit separators.
  Future<void> _seed() async {
    await batch((b) {
      b.insertAll(tagCategories, [
        TagCategoriesCompanion.insert(
          name: 'Genre',
          slug: systemTagCategoryGenre,
          isSystem: const Value(true),
          sortOrder: const Value(0),
        ),
        TagCategoriesCompanion.insert(
          name: 'Language',
          slug: systemTagCategoryLanguage,
          isSystem: const Value(true),
          sortOrder: const Value(1),
        ),
        TagCategoriesCompanion.insert(
          name: 'Mood',
          slug: 'mood',
          sortOrder: const Value(2),
        ),
      ]);

      b.insertAll(separatorTokens, [
        for (var i = 0; i < defaultSeparators.length; i++)
          SeparatorTokensCompanion.insert(
            token: defaultSeparators[i].token,
            kind: Value(defaultSeparators[i].kind),
            requiresSpaces: Value(defaultSeparators[i].requiresSpaces),
            isAmbiguous: Value(defaultSeparators[i].isAmbiguous),
            isBuiltIn: const Value(true),
            sortOrder: Value(i),
          ),
      ]);
    });
  }
}

/// Reserved slug of the tag category the indexer writes genres into.
const systemTagCategoryGenre = 'genre';

/// Reserved slug of the tag category the indexer writes languages into.
const systemTagCategoryLanguage = 'language';
