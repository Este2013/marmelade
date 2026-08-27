import 'package:drift/drift.dart';

import '../../domain/text/normalize.dart';
import '../../domain/models/library_views.dart';
import '../db/database.dart';
import '../indexer/search_indexer.dart';
import 'smart_playlist_resolver.dart';

/// One row inside a playlist: a track, or another playlist included whole.
class PlaylistEntry {
  const PlaylistEntry({
    required this.itemId,
    required this.position,
    this.trackId,
    this.childPlaylistId,
    this.childPlaylistName,
    this.childTrackCount,
    this.note,
  });

  /// Row id in `playlist_items`, so a specific entry can be removed even when
  /// the same track appears twice.
  final int itemId;

  final int position;
  final int? trackId;
  final int? childPlaylistId;
  final String? childPlaylistName;
  final int? childTrackCount;
  final String? note;

  bool get isChildPlaylist => childPlaylistId != null;
}

/// Reads and writes playlists.
///
/// A playlist holds tracks *and* other playlists, which is what makes nesting
/// work: including a playlist means its tracks appear in place, and stays in
/// step as the child changes.
///
/// Every walk of that structure is guarded, because a cycle would otherwise be
/// an infinite recursion rather than a mistake. The guard is the current
/// *path*, not everything seen so far: reaching the same playlist twice through
/// different branches is legitimate and both copies belong in the result.
class PlaylistRepository {
  PlaylistRepository({
    required this.db,
    required this.searchIndexer,
    this.smart,
  });

  final MarmeladeDatabase db;
  final SearchIndexer searchIndexer;

  /// Resolves the query behind a smart playlist.
  ///
  /// Optional so the repository can still be constructed for the parts of it
  /// that have nothing to do with queries -- and so a smart playlist degrades
  /// to its manual rows rather than throwing, if it ever is not wired up.
  final SmartPlaylistResolver? smart;

  /// How deep nesting may go.
  ///
  /// Not a technical limit -- the cycle check already makes recursion safe --
  /// but a playlist nested twenty deep is a mistake rather than an intention,
  /// and refusing it early gives a better message than a wall of indentation.
  static const maxDepth = 8;

  // ------------------------------------------------------------------ reading

  /// Watches every playlist, flattened into tree order with a depth on each.
  ///
  /// Flat rather than nested because that is what a list view renders, and the
  /// depth is all the indentation needs.
  Stream<List<PlaylistCard>> watchPlaylists() {
    return db
        .customSelect(
          '''
      SELECT
        p.id AS id, p.name AS name, p.kind AS kind, p.parent_id AS parent_id,
        p.description AS description, p.query AS query,
        p.query_sort AS query_sort,
        im.stored_path AS image_path,
        (SELECT COUNT(*) FROM playlist_items i
          WHERE i.playlist_id = p.id AND i.track_id IS NOT NULL
            AND i.is_exclusion = 0) AS track_count,
        (SELECT COUNT(*) FROM playlist_items i
          WHERE i.playlist_id = p.id AND i.child_playlist_id IS NOT NULL)
          AS child_count,
        (SELECT COALESCE(SUM(t.duration_ms), 0) FROM playlist_items i
          JOIN tracks t ON t.id = i.track_id
         WHERE i.playlist_id = p.id AND i.is_exclusion = 0) AS total_ms
      FROM playlists p
      LEFT JOIN images im ON im.id = p.image_id
      ORDER BY p.sort_order, p.name
      ''',
          readsFrom: {db.playlists, db.playlistItems, db.tracks, db.images},
        )
        .watch()
        .map(_asTree);
  }

  /// Arranges the flat rows into parent-then-children order.
  static List<PlaylistCard> _asTree(List<QueryRow> rows) {
    final byParent = <int?, List<QueryRow>>{};
    for (final row in rows) {
      byParent.putIfAbsent(row.read<int?>('parent_id'), () => []).add(row);
    }

    final ordered = <PlaylistCard>[];

    void walk(int? parentId, int depth, Set<int> seen) {
      for (final row in byParent[parentId] ?? const <QueryRow>[]) {
        final id = row.read<int>('id');
        // A parent chain that loops back on itself would recurse forever.
        // The schema cannot express it, but a corrupted row could.
        if (!seen.add(id)) continue;
        ordered.add(
          PlaylistCard(
            id: id,
            name: row.read<String>('name'),
            kind: row.read<String>('kind'),
            parentId: parentId,
            description: row.read<String?>('description'),
            query: row.read<String?>('query'),
            querySort: row.read<String?>('query_sort'),
            imagePath: row.read<String?>('image_path'),
            trackCount: row.read<int>('track_count'),
            childCount: row.read<int>('child_count'),
            totalDurationMs: row.read<int>('total_ms'),
            depth: depth,
          ),
        );
        walk(id, depth + 1, seen);
      }
    }

    walk(null, 0, <int>{});
    return ordered;
  }

  /// Watches one playlist's own rows, in order.
  Stream<List<PlaylistEntry>> watchEntries(int playlistId) {
    return db
        .customSelect(
          '''
      SELECT
        i.id AS item_id, i.position AS position, i.track_id AS track_id,
        i.child_playlist_id AS child_playlist_id, i.note AS note,
        c.name AS child_name,
        (SELECT COUNT(*) FROM playlist_items ci
          WHERE ci.playlist_id = c.id AND ci.track_id IS NOT NULL)
          AS child_track_count
      FROM playlist_items i
      LEFT JOIN playlists c ON c.id = i.child_playlist_id
      WHERE i.playlist_id = ?1 AND i.is_exclusion = 0
      ORDER BY i.position, i.id
      ''',
          variables: [Variable(playlistId)],
          readsFrom: {db.playlistItems, db.playlists},
        )
        .watch()
        .map(
          (rows) => [
            for (final row in rows)
              PlaylistEntry(
                itemId: row.read<int>('item_id'),
                position: row.read<int>('position'),
                trackId: row.read<int?>('track_id'),
                childPlaylistId: row.read<int?>('child_playlist_id'),
                childPlaylistName: row.read<String?>('child_name'),
                childTrackCount: row.read<int?>('child_track_count'),
                note: row.read<String?>('note'),
              ),
          ],
        );
  }

  Stream<PlaylistCard?> watchPlaylist(int playlistId) => watchPlaylists()
      .map((all) => all.where((p) => p.id == playlistId).firstOrNull);

  /// Every track in a playlist, in order, following nested playlists.
  ///
  /// Duplicates are kept: a track that appears twice was put there twice, and
  /// silently collapsing it would make the count disagree with the list.
  Future<List<int>> resolveTrackIds(int playlistId) async {
    final ids = <int>[];
    await _resolveInto(playlistId, ids, <int>[]);
    return ids;
  }

  /// Resolves a playlist, running its query if it has one.
  ///
  /// A smart playlist has no rows of its own, so its contents come from the
  /// query and the library as they are right now. A hybrid one is the query's
  /// results plus anything added by hand, minus anything explicitly excluded:
  /// the exclusion is the whole reason hybrid exists -- one track you never
  /// want in an otherwise perfectly good query.
  Future<List<int>> resolveContents(int playlistId) async {
    final row = await db
        .customSelect(
          'SELECT kind, query, query_limit, query_sort FROM playlists '
          'WHERE id = ?1',
          variables: [Variable(playlistId)],
          readsFrom: {db.playlists},
        )
        .getSingleOrNull();
    if (row == null) return const [];

    final kind = row.read<String>('kind');
    final query = row.read<String?>('query');
    final resolver = smart;
    final isQueried = kind == PlaylistKind.smart.name ||
        kind == PlaylistKind.hybrid.name;

    if (!isQueried || query == null || query.trim().isEmpty ||
        resolver == null) {
      return resolveTrackIds(playlistId);
    }

    final matched = await resolver.resolve(
      query,
      limit: row.read<int?>('query_limit'),
      sort: row.read<String?>('query_sort'),
    );

    if (kind == PlaylistKind.smart.name) {
      final excluded = await _exclusionsOf(playlistId);
      return [
        for (final id in matched)
          if (!excluded.contains(id)) id,
      ];
    }

    // Hybrid: the query first, then the hand-picked rows that it missed, so
    // adding a track by hand does not reshuffle everything the query found.
    final manual = await resolveTrackIds(playlistId);
    final excluded = await _exclusionsOf(playlistId);
    final seen = <int>{};
    return [
      for (final id in [...matched, ...manual])
        if (!excluded.contains(id) && seen.add(id)) id,
    ];
  }

  /// Watches the tracks this playlist explicitly does not want.
  Stream<List<int>> watchExclusions(int playlistId) => db
      .customSelect(
        'SELECT track_id FROM playlist_items '
        'WHERE playlist_id = ?1 AND is_exclusion = 1 AND track_id IS NOT NULL '
        'ORDER BY id',
        variables: [Variable(playlistId)],
        readsFrom: {db.playlistItems},
      )
      .watch()
      .map((rows) => [for (final row in rows) row.read<int>('track_id')]);

  /// Tracks this playlist explicitly does not want.
  Future<Set<int>> _exclusionsOf(int playlistId) async {
    final rows = await db
        .customSelect(
          'SELECT track_id FROM playlist_items '
          'WHERE playlist_id = ?1 AND is_exclusion = 1 AND track_id IS NOT NULL',
          variables: [Variable(playlistId)],
          readsFrom: {db.playlistItems},
        )
        .get();
    return {for (final row in rows) row.read<int>('track_id')};
  }

  /// Stores the query behind a smart playlist.
  Future<void> saveQuery(
    int playlistId, {
    required String query,
    String? sort,
    int? limit,
  }) async {
    final trimmed = query.trim();
    await db.customUpdate(
      'UPDATE playlists SET query = ?1, query_sort = ?2, query_limit = ?3, '
      'kind = CASE WHEN kind = ?4 THEN ?4 ELSE ?5 END, updated_at = ?6 '
      'WHERE id = ?7',
      variables: [
        Variable(trimmed.isEmpty ? null : trimmed),
        Variable(sort == null || sort.isEmpty ? null : sort),
        Variable(limit),
        Variable(PlaylistKind.hybrid.name),
        Variable(PlaylistKind.smart.name),
        Variable(DateTime.now().toUtc()),
        Variable(playlistId),
      ],
      updates: {db.playlists},
    );
  }

  /// Keeps a track out of a queried playlist without touching its query.
  Future<void> exclude(int playlistId, int trackId) async {
    await db.into(db.playlistItems).insert(
          PlaylistItemsCompanion.insert(
            playlistId: playlistId,
            trackId: Value(trackId),
            position: 0,
            isExclusion: const Value(true),
          ),
        );
  }

  /// Lets an excluded track back in.
  Future<void> unexclude(int playlistId, int trackId) async {
    await db.customUpdate(
      'DELETE FROM playlist_items WHERE playlist_id = ?1 AND track_id = ?2 '
      'AND is_exclusion = 1',
      variables: [Variable(playlistId), Variable(trackId)],
      updates: {db.playlistItems},
      updateKind: UpdateKind.delete,
    );
  }

  Future<void> _resolveInto(
    int playlistId,
    List<int> into,
    List<int> path,
  ) async {
    // The guard is the current path, not everything seen so far. A cycle is a
    // playlist appearing in its own ancestry; the same playlist reached twice
    // through different branches is legitimate and must contribute twice --
    // otherwise a playlist including both A and B, where both include C, would
    // silently drop one copy of C.
    if (path.contains(playlistId)) return;
    path.add(playlistId);

    final rows = await db
        .customSelect(
          'SELECT track_id, child_playlist_id FROM playlist_items '
          'WHERE playlist_id = ?1 AND is_exclusion = 0 '
          'ORDER BY position, id',
          variables: [Variable(playlistId)],
          readsFrom: {db.playlistItems},
        )
        .get();

    for (final row in rows) {
      final trackId = row.read<int?>('track_id');
      if (trackId != null) {
        into.add(trackId);
        continue;
      }
      final childId = row.read<int?>('child_playlist_id');
      if (childId != null) await _resolveInto(childId, into, path);
    }
    path.removeLast();
  }

  // ------------------------------------------------------------------ writing

  /// Creates a playlist and returns its id.
  Future<int?> create(
    String name, {
    int? parentId,
    PlaylistKind kind = PlaylistKind.manual,
    String? description,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    if (parentId != null && await _depthOf(parentId) >= maxDepth - 1) {
      return null;
    }

    final id = await db.into(db.playlists).insert(
          PlaylistsCompanion.insert(
            name: trimmed,
            nameKey: normalizeKey(trimmed),
            parentId: Value(parentId),
            kind: Value(kind),
            description: Value(_orNull(description)),
          ),
        );
    await searchIndexer.reindexEntity(SearchEntity.playlist, id);
    return id;
  }

  Future<void> rename(int playlistId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await (db.update(db.playlists)..where((t) => t.id.equals(playlistId)))
        .write(
      PlaylistsCompanion(
        name: Value(trimmed),
        nameKey: Value(normalizeKey(trimmed)),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await searchIndexer.reindexEntity(SearchEntity.playlist, playlistId);
  }

  Future<void> setDescription(int playlistId, String? description) =>
      (db.update(db.playlists)..where((t) => t.id.equals(playlistId))).write(
        PlaylistsCompanion(
          description: Value(_orNull(description)),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );

  /// Deletes a playlist. Nested playlists go with it, by the schema's cascade.
  Future<void> delete(int playlistId) async {
    // The children are collected first: after the delete they are gone, and
    // the search index still holds rows for them.
    final descendants = await _descendantsOf(playlistId);
    await (db.delete(db.playlists)..where((t) => t.id.equals(playlistId))).go();
    for (final id in [playlistId, ...descendants]) {
      await searchIndexer.removeEntity(SearchEntity.playlist, id);
    }
  }

  /// Moves a playlist under [parentId], or to the top level when null.
  ///
  /// Refuses a move that would put a playlist inside itself.
  Future<bool> reparent(int playlistId, int? parentId) async {
    if (parentId == playlistId) return false;
    if (parentId != null) {
      final descendants = await _descendantsOf(playlistId);
      if (descendants.contains(parentId)) return false;
      if (await _depthOf(parentId) >= maxDepth - 1) return false;
    }
    await (db.update(db.playlists)..where((t) => t.id.equals(playlistId)))
        .write(PlaylistsCompanion(parentId: Value(parentId)));
    return true;
  }

  /// Appends tracks to the end of a playlist.
  Future<void> addTracks(int playlistId, List<int> trackIds) async {
    if (trackIds.isEmpty) return;
    await db.transaction(() async {
      var position = await _nextPosition(playlistId);
      for (final trackId in trackIds) {
        await db.into(db.playlistItems).insert(
              PlaylistItemsCompanion.insert(
                playlistId: playlistId,
                trackId: Value(trackId),
                position: position++,
              ),
            );
      }
      await _touch(playlistId);
    });
  }

  /// Appends every track on an album, in its running order.
  ///
  /// Order comes from the album, not from whatever order the picker happened to
  /// show: adding a release to a playlist means adding it as a release.
  Future<int> addAlbum(int playlistId, int albumId) async {
    final rows = await db
        .customSelect(
          'SELECT id FROM tracks WHERE album_id = ?1 '
          'ORDER BY COALESCE(disc_no, 1), track_no IS NULL, track_no, title',
          variables: [Variable(albumId)],
          readsFrom: {db.tracks},
        )
        .get();
    final ids = [for (final row in rows) row.read<int>('id')];
    await addTracks(playlistId, ids);
    return ids.length;
  }

  /// Albums whose title or alias matches [query], for a picker.
  ///
  /// A plain substring match on the normalised key, deliberately: the real
  /// search grammar is a separate piece of work, and a picker needs to find a
  /// release by typing part of its name, nothing more.
  Future<List<({int id, String title, String? artistName, int trackCount})>>
      findAlbums(String query) async {
    final key = normalizeKey(query);
    if (key.isEmpty) return const [];

    final rows = await db
        .customSelect(
          '''
      SELECT DISTINCT al.id AS id, al.title AS title, ar.name AS artist_name,
        (SELECT COUNT(*) FROM tracks t WHERE t.album_id = al.id) AS track_count
      FROM albums al
      LEFT JOIN artists ar ON ar.id = al.album_artist_id
      LEFT JOIN album_aliases aa ON aa.album_id = al.id
      WHERE al.name_key LIKE ?1 OR aa.alias_key LIKE ?1
      ORDER BY (al.name_key = ?2) DESC, al.sort_title, al.title
      LIMIT 40
      ''',
          variables: [Variable('%$key%'), Variable(key)],
          readsFrom: {db.albums, db.artists, db.albumAliases, db.tracks},
        )
        .get();

    return [
      for (final row in rows)
        (
          id: row.read<int>('id'),
          title: row.read<String>('title'),
          artistName: row.read<String?>('artist_name'),
          trackCount: row.read<int>('track_count'),
        ),
    ];
  }

  /// Tracks whose title or alias matches [query], for a picker.
  Future<List<({int id, String title, String? artistLine, String? albumTitle})>>
      findTracks(String query) async {
    final key = normalizeKey(query);
    if (key.isEmpty) return const [];

    final rows = await db
        .customSelect(
          '''
      SELECT DISTINCT t.id AS id, t.title AS title, alb.title AS album_title,
        (SELECT group_concat(ar.name, ', ') FROM track_credits tc
          JOIN artists ar ON ar.id = tc.artist_id
         WHERE tc.track_id = t.id AND tc.role = 'mainArtist') AS artist_line
      FROM tracks t
      LEFT JOIN albums alb ON alb.id = t.album_id
      LEFT JOIN track_aliases ta ON ta.track_id = t.id
      WHERE t.name_key LIKE ?1 OR ta.alias_key LIKE ?1
      ORDER BY (t.name_key = ?2) DESC, t.sort_title, t.title
      LIMIT 60
      ''',
          variables: [Variable('%$key%'), Variable(key)],
          readsFrom: {
            db.tracks,
            db.albums,
            db.trackAliases,
            db.trackCredits,
            db.artists,
          },
        )
        .get();

    return [
      for (final row in rows)
        (
          id: row.read<int>('id'),
          title: row.read<String>('title'),
          artistLine: row.read<String?>('artist_line'),
          albumTitle: row.read<String?>('album_title'),
        ),
    ];
  }

  /// Includes another playlist, whole, at the end.
  ///
  /// Refused when it would create a cycle: including a playlist that already
  /// contains this one, directly or at any depth.
  Future<bool> addChildPlaylist(int playlistId, int childId) async {
    if (playlistId == childId) return false;
    // Would the child, followed through its own inclusions, come back here?
    final reachable = await _reachableFrom(childId);
    if (reachable.contains(playlistId)) return false;

    await db.transaction(() async {
      await db.into(db.playlistItems).insert(
            PlaylistItemsCompanion.insert(
              playlistId: playlistId,
              childPlaylistId: Value(childId),
              position: await _nextPosition(playlistId),
            ),
          );
      await _touch(playlistId);
    });
    return true;
  }

  Future<void> removeEntry(int itemId) async {
    final playlistId = await db
        .customSelect(
          'SELECT playlist_id FROM playlist_items WHERE id = ?1',
          variables: [Variable(itemId)],
        )
        .getSingleOrNull();
    await (db.delete(db.playlistItems)..where((t) => t.id.equals(itemId))).go();
    if (playlistId != null) {
      await _touch(playlistId.read<int>('playlist_id'));
    }
  }

  Future<void> clear(int playlistId) async {
    await (db.delete(db.playlistItems)
          ..where((t) => t.playlistId.equals(playlistId)))
        .go();
    await _touch(playlistId);
  }

  /// Moves an entry to [newIndex] within its playlist.
  ///
  /// Positions are renumbered from zero afterwards, which keeps them dense and
  /// makes the next move trivial. Playlists are small enough that rewriting
  /// them all is cheaper than the arithmetic to avoid it.
  Future<void> moveEntry(int playlistId, int itemId, int newIndex) async {
    await db.transaction(() async {
      final rows = await db
          .customSelect(
            'SELECT id FROM playlist_items WHERE playlist_id = ?1 '
            'ORDER BY position, id',
            variables: [Variable(playlistId)],
            readsFrom: {db.playlistItems},
          )
          .get();

      final ids = [for (final row in rows) row.read<int>('id')];
      final from = ids.indexOf(itemId);
      if (from < 0) return;
      ids.removeAt(from);
      ids.insert(newIndex.clamp(0, ids.length), itemId);

      for (var i = 0; i < ids.length; i++) {
        await (db.update(db.playlistItems)..where((t) => t.id.equals(ids[i])))
            .write(PlaylistItemsCompanion(position: Value(i)));
      }
      await _touch(playlistId);
    });
  }

  // ------------------------------------------------------------------ helpers

  static String? _orNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  Future<int> _nextPosition(int playlistId) async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(position), -1) + 1 AS next FROM playlist_items '
          'WHERE playlist_id = ?1',
          variables: [Variable(playlistId)],
          readsFrom: {db.playlistItems},
        )
        .getSingle();
    return row.read<int>('next');
  }

  Future<void> _touch(int playlistId) =>
      (db.update(db.playlists)..where((t) => t.id.equals(playlistId))).write(
        PlaylistsCompanion(updatedAt: Value(DateTime.now().toUtc())),
      );

  /// How deep a playlist sits in the parent tree.
  Future<int> _depthOf(int playlistId) async {
    var depth = 0;
    var current = playlistId;
    final seen = <int>{};
    while (seen.add(current)) {
      final row = await db
          .customSelect(
            'SELECT parent_id FROM playlists WHERE id = ?1',
            variables: [Variable(current)],
          )
          .getSingleOrNull();
      final parent = row?.read<int?>('parent_id');
      if (parent == null) break;
      depth += 1;
      current = parent;
    }
    return depth;
  }

  /// Every playlist under [playlistId] in the parent tree.
  Future<Set<int>> _descendantsOf(int playlistId) async {
    final found = <int>{};
    final queue = <int>[playlistId];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      final rows = await db
          .customSelect(
            'SELECT id FROM playlists WHERE parent_id = ?1',
            variables: [Variable(current)],
          )
          .get();
      for (final row in rows) {
        final id = row.read<int>('id');
        if (found.add(id)) queue.add(id);
      }
    }
    return found;
  }

  /// Every playlist reachable from [playlistId] by following inclusions.
  ///
  /// Used to refuse a cycle before it is created, which is cheaper than
  /// detecting one afterwards and much cheaper than hanging on it.
  Future<Set<int>> _reachableFrom(int playlistId) async {
    final found = <int>{playlistId};
    final queue = <int>[playlistId];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      final rows = await db
          .customSelect(
            'SELECT child_playlist_id FROM playlist_items '
            'WHERE playlist_id = ?1 AND child_playlist_id IS NOT NULL',
            variables: [Variable(current)],
          )
          .get();
      for (final row in rows) {
        final id = row.read<int>('child_playlist_id');
        if (found.add(id)) queue.add(id);
      }
    }
    return found;
  }
}
