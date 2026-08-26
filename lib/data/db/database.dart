import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

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
/// Stored as short strings to keep the index small.
abstract final class SearchEntity {
  static const track = 'trk';
  static const album = 'alb';
  static const artist = 'art';
  static const tag = 'tag';
  static const playlist = 'pls';

  static const all = [track, album, artist, tag, playlist];
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
  int get schemaVersion => 1;

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
          // Virtual tables and views live outside the schema drift manages,
          // so make sure they exist on every open.
          await _createSearchIndexes();
          await _createViews();
        },
      );

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
