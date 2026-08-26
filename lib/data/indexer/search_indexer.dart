import '../db/database.dart';

/// Keeps the two full-text indexes in step with the catalog.
///
/// The indexes are maintained from Dart rather than by SQL triggers. Triggers
/// across eight source tables would be hard to reason about and harder to
/// debug, and the app needs a repair path anyway - a search index that can only
/// be rebuilt by reimporting the library is not a repair path.
///
/// Two indexes, because one cannot do the job:
///   * `search_tokens` (unicode61, diacritics folded) gives ranked word and
///     prefix matching for Latin scripts.
///   * `search_trigrams` gives substring matching, which is the only thing
///     that works for CJK - unicode61 treats a run of Japanese as one token,
///     so a substring of it could never match.
class SearchIndexer {
  SearchIndexer(this.db);

  final MarmeladeDatabase db;

  /// Rebuilds the whole index from the catalog.
  ///
  /// Written as bulk `INSERT ... SELECT` statements, so a full rebuild of a
  /// large library is a handful of queries rather than one per row. Cheap
  /// enough to run after a scan instead of tracking fine-grained deltas.
  Future<void> rebuildAll() async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM $ftsTokenTable');
      if (db.trigramSearchAvailable) {
        await db.customStatement('DELETE FROM $ftsTrigramTable');
      }

      await _indexArtists();
      await _indexAlbums();
      await _indexTracks();
      await _indexTags();
      await _indexPlaylists();
    });
  }

  /// Re-indexes a single entity after an edit.
  Future<void> reindexEntity(String entityType, int id) async {
    await db.transaction(() async {
      await _remove(entityType, id);
      switch (entityType) {
        case SearchEntity.artist:
          await _indexArtists(onlyId: id);
        case SearchEntity.album:
          await _indexAlbums(onlyId: id);
        case SearchEntity.track:
          await _indexTracks(onlyId: id);
        case SearchEntity.tag:
          await _indexTags(onlyId: id);
        case SearchEntity.playlist:
          await _indexPlaylists(onlyId: id);
      }
    });
  }

  /// Drops an entity from both indexes.
  Future<void> removeEntity(String entityType, int id) =>
      db.transaction(() => _remove(entityType, id));

  Future<void> _remove(String entityType, int id) async {
    await db.customStatement(
      'DELETE FROM $ftsTokenTable WHERE entity_type = ? AND entity_id = ?',
      [entityType, '$id'],
    );
    if (db.trigramSearchAvailable) {
      await db.customStatement(
        'DELETE FROM $ftsTrigramTable WHERE entity_type = ? AND entity_id = ?',
        [entityType, '$id'],
      );
    }
  }

  /// How many rows each index holds, for the debug view.
  Future<({int tokens, int trigrams})> counts() async {
    final tokens = await db
        .customSelect('SELECT COUNT(*) AS c FROM $ftsTokenTable')
        .getSingle();
    var trigrams = 0;
    if (db.trigramSearchAvailable) {
      final row = await db
          .customSelect('SELECT COUNT(*) AS c FROM $ftsTrigramTable')
          .getSingle();
      trigrams = row.read<int>('c');
    }
    return (tokens: tokens.read<int>('c'), trigrams: trigrams);
  }

  // ------------------------------------------------------------------ writers

  /// Runs one projection into both indexes.
  ///
  /// [select] must name its columns `entity_type`, `entity_id`, `title`,
  /// `aliases` and `secondary`. It is used as a subquery twice - once as-is
  /// for the token index, once with the columns concatenated for the trigram
  /// index - which keeps the two indexes derived from a single definition
  /// instead of two that could drift apart.
  Future<void> _insert({
    required String select,
    List<Object?> variables = const [],
  }) async {
    await db.customStatement(
      'INSERT INTO $ftsTokenTable '
      '(entity_type, entity_id, title, aliases, secondary) '
      'SELECT entity_type, entity_id, title, aliases, secondary '
      'FROM ($select)',
      variables,
    );
    if (!db.trigramSearchAvailable) return;
    await db.customStatement(
      'INSERT INTO $ftsTrigramTable (entity_type, entity_id, haystack) '
      "SELECT entity_type, entity_id, "
      "TRIM(title || ' ' || aliases || ' ' || secondary) "
      'FROM ($select)',
      variables,
    );
  }

  Future<void> _indexArtists({int? onlyId}) async {
    final filter = onlyId == null ? '' : 'WHERE a.id = ?';
    await _insert(
      select: '''
        SELECT '${SearchEntity.artist}' AS entity_type,
          CAST(a.id AS TEXT) AS entity_id,
          a.name AS title,
          COALESCE((SELECT group_concat(al.alias, ' ')
                      FROM artist_aliases al WHERE al.artist_id = a.id), '')
            AS aliases,
          COALESCE(a.disambiguation, '') AS secondary
        FROM artists a $filter
      ''',
      variables: onlyId == null ? const [] : [onlyId],
    );
  }

  Future<void> _indexAlbums({int? onlyId}) async {
    final filter = onlyId == null ? '' : 'WHERE al.id = ?';
    await _insert(
      select: '''
        SELECT '${SearchEntity.album}' AS entity_type,
          CAST(al.id AS TEXT) AS entity_id,
          al.title AS title,
          COALESCE((SELECT group_concat(aa.alias, ' ')
                      FROM album_aliases aa WHERE aa.album_id = al.id), '')
            AS aliases,
          COALESCE((SELECT ar.name FROM artists ar
                     WHERE ar.id = al.album_artist_id), '') AS secondary
        FROM albums al $filter
      ''',
      variables: onlyId == null ? const [] : [onlyId],
    );
  }

  Future<void> _indexTracks({int? onlyId}) async {
    final filter = onlyId == null ? '' : 'WHERE t.id = ?';
    // A track is findable by its own title, its aliases, every artist credited
    // on it, and its album - which is what makes "every artist mention is one
    // click away" hold without extra work in the UI.
    await _insert(
      select: '''
        SELECT '${SearchEntity.track}' AS entity_type,
          CAST(t.id AS TEXT) AS entity_id,
          t.title AS title,
          COALESCE((SELECT group_concat(ta.alias, ' ')
                      FROM track_aliases ta WHERE ta.track_id = t.id), '')
            AS aliases,
          TRIM(
            COALESCE((SELECT group_concat(DISTINCT ar.name)
                        FROM track_credits tc
                        JOIN artists ar ON ar.id = tc.artist_id
                       WHERE tc.track_id = t.id), '')
            || ' ' || COALESCE(alb.title, '')
          ) AS secondary
        FROM tracks t
        LEFT JOIN albums alb ON alb.id = t.album_id
        $filter
      ''',
      variables: onlyId == null ? const [] : [onlyId],
    );
  }

  Future<void> _indexTags({int? onlyId}) async {
    final filter = onlyId == null ? '' : 'WHERE tg.id = ?';
    await _insert(
      select: '''
        SELECT '${SearchEntity.tag}' AS entity_type,
          CAST(tg.id AS TEXT) AS entity_id,
          tg.name AS title,
          COALESCE((SELECT group_concat(al.alias, ' ')
                      FROM tag_aliases al WHERE al.tag_id = tg.id), '')
            AS aliases,
          COALESCE((SELECT c.name FROM tag_categories c
                     WHERE c.id = tg.category_id), '') AS secondary
        FROM tags tg $filter
      ''',
      variables: onlyId == null ? const [] : [onlyId],
    );
  }

  Future<void> _indexPlaylists({int? onlyId}) async {
    final filter = onlyId == null ? '' : 'WHERE pl.id = ?';
    await _insert(
      select: '''
        SELECT '${SearchEntity.playlist}' AS entity_type,
          CAST(pl.id AS TEXT) AS entity_id,
          pl.name AS title,
          '' AS aliases,
          COALESCE(pl.description, '') AS secondary
        FROM playlists pl $filter
      ''',
      variables: onlyId == null ? const [] : [onlyId],
    );
  }
}
