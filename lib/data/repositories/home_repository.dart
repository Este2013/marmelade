import 'package:drift/drift.dart';

import '../db/database.dart';
import '../../domain/models/home_views.dart';

/// Reads and edits the home page.
///
/// The page is a tree -- sections hold items, items of kind
/// [HomeItemKind.collection] hold more items -- but it is read in two flat queries
/// and assembled in Dart rather than walked recursively in SQL. A home page is
/// tens of rows, not thousands, and a recursive CTE that has to resolve four
/// different reference targets per level would be considerably harder to read
/// than the thing it saves.
class HomeRepository {
  HomeRepository(this.db);

  final MarmeladeDatabase db;

  /// Gap left between adjacent positions, so inserting between two neighbours
  /// is one row write. Same trick as the play queue's.
  static const _positionGap = 1000;

  // ------------------------------------------------------------------- read

  /// The whole home page, rebuilt whenever anything it shows changes.
  ///
  /// [_pageReads] belongs on *this* query and not on the per-section ones
  /// below it. Only this one is watched; the rest run inside its `asyncMap`
  /// as one-shot reads, where a `readsFrom` is decorative. Listing only
  /// `home_sections` here is what made an item added through the dialog land
  /// in the database and never appear -- nothing a section itself owns had
  /// changed, so the stream had no reason to re-run and the new row was
  /// simply never fetched.
  Stream<List<HomeSectionView>> watchHome() {
    return db
        .customSelect(
          'SELECT id, title, layout, source, item_limit, collapsed, icon '
          'FROM home_sections ORDER BY position, id',
          readsFrom: _pageReads,
        )
        .watch()
        .asyncMap((rows) async {
      final sections = <HomeSectionView>[];
      for (final row in rows) {
        final source = HomeSectionSource.values
                .where((s) => s.name == row.read<String>('source'))
                .firstOrNull ??
            HomeSectionSource.curated;
        final id = row.read<int>('id');
        final limit = row.read<int>('item_limit');
        sections.add(
          HomeSectionView(
            id: id,
            title: row.read<String>('title'),
            layout: HomeLayout.values
                    .where((l) => l.name == row.read<String>('layout'))
                    .firstOrNull ??
                HomeLayout.grid,
            source: source,
            itemLimit: limit,
            collapsed: row.read<bool>('collapsed'),
            icon: row.read<int?>('icon'),
            items: switch (source) {
              HomeSectionSource.curated => await itemsOf(id),
              HomeSectionSource.recentlyPlayed => await recentlyPlayed(limit),
            },
          ),
        );
      }
      return sections;
    });
  }

  /// Everything the home page reads, from any of its queries.
  ///
  /// Wide on purpose: a tile shows an album's title and cover, so renaming
  /// that album has to redraw the page even though no home table was touched
  /// -- the same omission that left the albums grid filtering on a stale
  /// alias.
  Set<ResultSetImplementation<dynamic, dynamic>> get _pageReads => {
        db.homeSections,
        db.homeItems,
        db.images,
        db.albums,
        db.artists,
        db.playlists,
        db.tracks,
        db.trackCredits,
        db.playlistItems,
        db.playHistory,
      };

  /// Every item in one section, assembled into its tree.
  Future<List<HomeItemView>> itemsOf(int sectionId) async {
    final rows = await db.customSelect(
      _itemsSql,
      variables: [Variable(sectionId)],
    ).get();

    // Grouped by parent first so a child can be attached to a parent that
    // appears after it in the ordering -- which it will the moment somebody
    // drags a collection below its own contents' original position.
    final byParent = <int?, List<QueryRow>>{};
    for (final row in rows) {
      byParent.putIfAbsent(row.read<int?>('parent_id'), () => []).add(row);
    }

    List<HomeItemView> build(int? parent, int depth) {
      // A parent chain that somehow looped would otherwise recurse forever.
      // Nothing in the editing surface can create one -- see [moveItem] --
      // which is precisely why the guard belongs here rather than being
      // relied upon not to be needed.
      if (depth > 8) return const [];
      final out = <HomeItemView>[];
      for (final row in byParent[parent] ?? const <QueryRow>[]) {
        final item =
            _viewOf(row, sectionId, build(row.read<int>('id'), depth + 1));
        if (item != null) out.add(item);
      }
      return out;
    }

    return build(null, 0);
  }

  /// Turns one row into a view, or null when it points at something that is
  /// no longer in the library.
  ///
  /// A deleted album leaves a home item pointing at nothing. Dropping it
  /// silently is the right call: the alternative is a tile reading "Unknown"
  /// that does nothing when clicked, which is worse than the tile being gone.
  HomeItemView? _viewOf(QueryRow row, int sectionId, List<HomeItemView> children) {
    final kind = HomeItemKind.values
        .where((k) => k.name == row.read<String>('kind'))
        .firstOrNull;
    if (kind == null) return null;

    final refTitle = row.read<String?>('ref_title');
    final pointsAtARow =
        kind != HomeItemKind.collection && kind != HomeItemKind.query;
    if (pointsAtARow && refTitle == null) return null;

    return HomeItemView(
      id: row.read<int>('id'),
      sectionId: sectionId,
      kind: kind,
      title: row.read<String?>('label') ?? refTitle ?? 'Untitled',
      subtitle: switch (kind) {
        HomeItemKind.collection => _countLabel(children),
        HomeItemKind.query => row.read<String?>('query'),
        _ => row.read<String?>('ref_subtitle'),
      },
      refId: row.read<int?>('ref_id'),
      query: row.read<String?>('query'),
      imagePath:
          row.read<String?>('own_image') ?? row.read<String?>('ref_image'),
      children: children,
      artworkCount: row.read<int>('artwork_count'),
      trackCount: row.read<int>('ref_tracks'),
    );
  }

  /// What a collection's tile says it holds.
  ///
  /// A search is counted apart from the rest rather than as one item,
  /// because it is not one: it stands for however many things it matches
  /// today, which the tile cannot know without running it. Saying "3 items"
  /// for two albums and a search would be the one number that is certainly
  /// wrong.
  static String? _countLabel(List<HomeItemView> children) {
    if (children.isEmpty) return 'Empty';
    final searches =
        children.where((c) => c.kind == HomeItemKind.query).length;
    final picked = children.length - searches;
    final parts = [
      if (picked > 0) '$picked item${picked == 1 ? '' : 's'}',
      if (searches > 0) '$searches search${searches == 1 ? '' : 'es'}',
    ];
    return parts.join(' and ');
  }

  /// The most recently played tracks, newest first, one row per track.
  ///
  /// Grouped by track rather than listed raw: playing an album twice over
  /// should not fill the section with the same ten songs twice.
  Future<List<HomeItemView>> recentlyPlayed(int limit) async {
    final rows = await db.customSelect(
      '''
      SELECT t.id AS id, t.title AS title,
        MAX(h.started_at) AS last_played,
        im.stored_path AS image_path,
        (SELECT ar.name FROM track_credits tc
          JOIN artists ar ON ar.id = tc.artist_id
         WHERE tc.track_id = t.id AND tc.role = 'mainArtist'
         ORDER BY tc.sort_order LIMIT 1) AS artist_name
      FROM play_history h
      JOIN tracks t ON t.id = h.track_id
      LEFT JOIN v_track_artwork vt ON vt.track_id = t.id
      LEFT JOIN images im ON im.id = vt.image_id
      GROUP BY t.id
      ORDER BY last_played DESC
      LIMIT ?1
      ''',
      variables: [Variable(limit)],
      readsFrom: {
        db.playHistory,
        db.tracks,
        db.images,
        db.trackCredits,
        db.artists,
      },
    ).get();

    return [
      for (var i = 0; i < rows.length; i++)
        HomeItemView(
          // Negative, and derived from the position rather than the track:
          // these rows are not in `home_items` and must never be mistaken for
          // something that can be reordered or deleted. See
          // [HomeItemView.isComputed].
          id: -(i + 1),
          kind: HomeItemKind.track,
          title: rows[i].read<String>('title'),
          subtitle: rows[i].read<String?>('artist_name'),
          refId: rows[i].read<int>('id'),
          imagePath: rows[i].read<String?>('image_path'),
          trackCount: 1,
        ),
    ];
  }

  // ---------------------------------------------------------------- sections

  Future<int> addSection({
    required String title,
    HomeLayout layout = HomeLayout.grid,
    HomeSectionSource source = HomeSectionSource.curated,
  }) async {
    final last = await db
        .customSelect(
          'SELECT COALESCE(MAX(position), 0) AS p FROM home_sections',
          readsFrom: {db.homeSections},
        )
        .getSingle();
    return db.into(db.homeSections).insert(
          HomeSectionsCompanion.insert(
            title: title,
            position: last.read<int>('p') + _positionGap,
            layout: Value(layout),
            source: Value(source),
          ),
        );
  }

  Future<void> renameSection(int sectionId, String title) =>
      (db.update(db.homeSections)..where((s) => s.id.equals(sectionId)))
          .write(HomeSectionsCompanion(title: Value(title)));

  Future<void> setSectionLayout(int sectionId, HomeLayout layout) =>
      (db.update(db.homeSections)..where((s) => s.id.equals(sectionId)))
          .write(HomeSectionsCompanion(layout: Value(layout)));

  Future<void> setSectionSource(int sectionId, HomeSectionSource source) =>
      (db.update(db.homeSections)..where((s) => s.id.equals(sectionId)))
          .write(HomeSectionsCompanion(source: Value(source)));

  Future<void> setSectionCollapsed(int sectionId, bool collapsed) =>
      (db.update(db.homeSections)..where((s) => s.id.equals(sectionId)))
          .write(HomeSectionsCompanion(collapsed: Value(collapsed)));

  /// Gives a section an icon, or takes it away again with null.
  Future<void> setSectionIcon(int sectionId, int? codePoint) =>
      (db.update(db.homeSections)..where((s) => s.id.equals(sectionId)))
          .write(HomeSectionsCompanion(icon: Value(codePoint)));

  Future<void> setSectionLimit(int sectionId, int limit) =>
      (db.update(db.homeSections)..where((s) => s.id.equals(sectionId)))
          .write(HomeSectionsCompanion(itemLimit: Value(limit)));

  Future<void> removeSection(int sectionId) =>
      (db.delete(db.homeSections)..where((s) => s.id.equals(sectionId))).go();

  /// Moves a section so it sits directly before [beforeId], or last when that
  /// is null.
  ///
  /// Renumbers the whole column rather than hunting for a gap. There are a
  /// handful of sections, the write is one statement per row inside a
  /// transaction, and gap-finding code that runs rarely is code that is wrong
  /// when it finally runs.
  Future<void> moveSection(int sectionId, {int? beforeId}) async {
    final rows = await db
        .customSelect(
          'SELECT id FROM home_sections ORDER BY position, id',
          readsFrom: {db.homeSections},
        )
        .get();
    final order = [for (final row in rows) row.read<int>('id')]
      ..remove(sectionId);
    final at = beforeId == null ? order.length : order.indexOf(beforeId);
    order.insert(at < 0 ? order.length : at, sectionId);

    await db.transaction(() async {
      for (var i = 0; i < order.length; i++) {
        await (db.update(db.homeSections)..where((s) => s.id.equals(order[i])))
            .write(
          HomeSectionsCompanion(position: Value((i + 1) * _positionGap)),
        );
      }
    });
  }

  // ------------------------------------------------------------------- items

  /// Adds one item to a section, or to a collection inside it.
  Future<int> addItem({
    required int sectionId,
    required HomeItemKind kind,
    int? parentId,
    int? refId,
    String? label,
    String? query,
  }) async {
    final last = await db
        .customSelect(
          'SELECT COALESCE(MAX(position), 0) AS p FROM home_items '
          'WHERE section_id = ?1 AND parent_id IS ?2',
          variables: [Variable(sectionId), Variable(parentId)],
          readsFrom: {db.homeItems},
        )
        .getSingle();

    return db.into(db.homeItems).insert(
          HomeItemsCompanion.insert(
            sectionId: sectionId,
            parentId: Value(parentId),
            position: last.read<int>('p') + _positionGap,
            kind: kind,
            refId: Value(refId),
            label: Value(label),
            query: Value(query),
          ),
        );
  }

  Future<void> renameItem(int itemId, String? label) =>
      (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
          .write(HomeItemsCompanion(label: Value(label)));

  Future<void> setItemQuery(int itemId, String query) =>
      (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
          .write(HomeItemsCompanion(query: Value(query)));

  Future<void> setItemArtworkCount(int itemId, int count) =>
      (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
          .write(HomeItemsCompanion(artworkCount: Value(count)));

  Future<void> setItemImage(int itemId, int? imageId) =>
      (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
          .write(HomeItemsCompanion(imageId: Value(imageId)));

  Future<void> removeItem(int itemId) =>
      (db.delete(db.homeItems)..where((i) => i.id.equals(itemId))).go();

  /// Moves an item within its parent, or into a different one.
  ///
  /// [newParentId] of null means "directly in the section". Moving a collection
  /// into its own descendant is refused rather than corrected: there is no
  /// sensible interpretation of it, and silently doing something else is how
  /// a tree quietly loses a branch.
  Future<void> moveItem(
    int itemId, {
    required int sectionId,
    int? newParentId,
    int? beforeId,
  }) async {
    if (newParentId == itemId) return;
    if (newParentId != null && await _isDescendant(newParentId, of: itemId)) {
      return;
    }

    await (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
        .write(HomeItemsCompanion(
      parentId: Value(newParentId),
      sectionId: Value(sectionId),
    ));
    // `section_id` is carried on every item, nested ones included, so a whole
    // section reads in one query. That means a cross-section move has to
    // rewrite the dragged item's descendants as well -- leaving them behind
    // would file them under a section they are no longer in, where nothing
    // would ever read them again.
    await _restampSection(itemId, sectionId);

    final rows = await db.customSelect(
      'SELECT id FROM home_items WHERE section_id = ?1 AND parent_id IS ?2 '
      'ORDER BY position, id',
      variables: [Variable(sectionId), Variable(newParentId)],
      readsFrom: {db.homeItems},
    ).get();

    final order = [for (final row in rows) row.read<int>('id')]..remove(itemId);
    final at = beforeId == null ? order.length : order.indexOf(beforeId);
    order.insert(at < 0 ? order.length : at, itemId);

    await db.transaction(() async {
      for (var i = 0; i < order.length; i++) {
        await (db.update(db.homeItems)..where((it) => it.id.equals(order[i])))
            .write(HomeItemsCompanion(position: Value((i + 1) * _positionGap)));
      }
    });
  }

  /// Turns track ids into items, in the order given.
  ///
  /// What a search inside a collection becomes once it has been run: the
  /// collection's contents are "these, then everything that matches, then
  /// those", so the matches have to arrive as items like any other.
  Future<List<HomeItemView>> trackItems(List<int> trackIds, int sectionId) async {
    if (trackIds.isEmpty) return const [];
    final rows = await db.customSelect(
      '''
      SELECT t.id AS id, t.title AS title,
        im.stored_path AS image_path,
        (SELECT ar.name FROM track_credits tc
          JOIN artists ar ON ar.id = tc.artist_id
         WHERE tc.track_id = t.id AND tc.role = 'mainArtist'
         ORDER BY tc.sort_order LIMIT 1) AS artist_name
      FROM tracks t
      LEFT JOIN v_track_artwork vt ON vt.track_id = t.id
      LEFT JOIN images im ON im.id = vt.image_id
      WHERE t.id IN (${trackIds.join(',')})
      ''',
      readsFrom: {db.tracks, db.images, db.trackCredits, db.artists},
    ).get();

    // Re-ordered to match the ids given: `IN` says nothing about order, and
    // a search's own ranking is the whole reason it was asked.
    final byId = {for (final row in rows) row.read<int>('id'): row};
    return [
      for (var i = 0; i < trackIds.length; i++)
        if (byId[trackIds[i]] case final row?)
          HomeItemView(
            // Negative, like a computed section's rows: these are not in
            // `home_items` and must never look reorderable or removable.
            id: -(i + 1),
            sectionId: sectionId,
            kind: HomeItemKind.track,
            title: row.read<String>('title'),
            subtitle: row.read<String?>('artist_name'),
            refId: trackIds[i],
            imagePath: row.read<String?>('image_path'),
            trackCount: 1,
          ),
    ];
  }

  /// Puts [targetId] inside a brand-new collection standing in its place.
  ///
  /// The other half of dropping one tile on the middle of another: the
  /// collection takes the target's spot, the target goes in it, and the
  /// caller then drops whatever was being dragged in alongside.
  ///
  /// Returns the new collection's id, or null when the target has gone.
  Future<int?> wrapInCollection({
    required int sectionId,
    required int targetId,
    String title = 'New collection',
  }) async {
    final row = await db.customSelect(
      'SELECT parent_id FROM home_items WHERE id = ?1',
      variables: [Variable(targetId)],
      readsFrom: {db.homeItems},
    ).getSingleOrNull();
    if (row == null) return null;

    final collectionId = await addItemAt(
      sectionId: sectionId,
      kind: HomeItemKind.collection,
      parentId: row.read<int?>('parent_id'),
      beforeId: targetId,
      label: title,
    );
    await moveItem(targetId, sectionId: sectionId, newParentId: collectionId);
    return collectionId;
  }

  // ------------------------------------------------------------- playback

  /// An album's tracks, in running order.
  Future<List<int>> tracksOfAlbum(int albumId) async {
    final rows = await db.customSelect(
      'SELECT id FROM tracks WHERE album_id = ?1 '
      'ORDER BY disc_no, track_no, sort_title, id',
      variables: [Variable(albumId)],
      readsFrom: {db.tracks},
    ).get();
    return [for (final row in rows) row.read<int>('id')];
  }

  /// Everything an artist is credited on, in any role.
  ///
  /// Any role, not just main: this is the same promise the artist's own page
  /// makes, and a guest appearance is still their work. Ordered by release so
  /// playing an artist tile is a chronology rather than a shuffle.
  Future<List<int>> tracksOfArtist(int artistId) async {
    final rows = await db.customSelect(
      '''
      SELECT DISTINCT t.id AS id
      FROM track_credits tc
      JOIN tracks t ON t.id = tc.track_id
      LEFT JOIN albums al ON al.id = t.album_id
      WHERE tc.artist_id = ?1
      ORDER BY al.release_year, al.sort_title, t.disc_no, t.track_no, t.id
      ''',
      variables: [Variable(artistId)],
      readsFrom: {db.trackCredits, db.tracks, db.albums},
    ).get();
    return [for (final row in rows) row.read<int>('id')];
  }

  /// Walks an item's descendants, putting them in [sectionId].
  Future<void> _restampSection(int itemId, int sectionId) async {
    final children = await db.customSelect(
      'SELECT id FROM home_items WHERE parent_id = ?1',
      variables: [Variable(itemId)],
      readsFrom: {db.homeItems},
    ).get();
    for (final row in children) {
      final childId = row.read<int>('id');
      await (db.update(db.homeItems)..where((i) => i.id.equals(childId)))
          .write(HomeItemsCompanion(sectionId: Value(sectionId)));
      await _restampSection(childId, sectionId);
    }
  }

  /// Adds an item and, when [beforeId] is given, puts it in that place rather
  /// than at the end.
  ///
  /// Two writes rather than one insert with a computed position: working out
  /// a position between two neighbours duplicates the ordering rules that
  /// [moveItem] already has and tests cover, and this runs once per drop.
  Future<int> addItemAt({
    required int sectionId,
    required HomeItemKind kind,
    int? parentId,
    int? beforeId,
    int? refId,
    String? label,
    String? query,
  }) async {
    final id = await addItem(
      sectionId: sectionId,
      kind: kind,
      parentId: parentId,
      refId: refId,
      label: label,
      query: query,
    );
    if (beforeId != null) {
      await moveItem(
        id,
        sectionId: sectionId,
        newParentId: parentId,
        beforeId: beforeId,
      );
    }
    return id;
  }

  /// Creates a section in a particular place rather than at the end.
  Future<int> addSectionAt({
    required String title,
    int? beforeId,
    HomeLayout layout = HomeLayout.grid,
  }) async {
    final id = await addSection(title: title, layout: layout);
    if (beforeId != null) await moveSection(id, beforeId: beforeId);
    return id;
  }

  /// Whether [candidate] sits somewhere beneath [of] in the item tree.
  Future<bool> _isDescendant(int candidate, {required int of}) async {
    var at = candidate;
    for (var guard = 0; guard < 16; guard++) {
      final row = await db.customSelect(
        'SELECT parent_id FROM home_items WHERE id = ?1',
        variables: [Variable(at)],
        readsFrom: {db.homeItems},
      ).getSingleOrNull();
      final parent = row?.read<int?>('parent_id');
      if (parent == null) return false;
      if (parent == of) return true;
      at = parent;
    }
    return false;
  }
}

/// One query for a whole section's items, resolving all four reference kinds.
///
/// Held as a constant rather than inlined so the Dart around it stays
/// readable. A `CASE` per column rather than four joins: an item knows its
/// own kind, so exactly one branch is ever taken for a given row, and the
/// alternative is four left joins that are null for three quarters of the
/// rows in every result.
const _itemsSql = '''
SELECT
  hi.id AS id, hi.parent_id AS parent_id, hi.kind AS kind,
  hi.ref_id AS ref_id, hi.label AS label, hi.query AS query,
  hi.artwork_count AS artwork_count,
  own.stored_path AS own_image,
  CASE hi.kind
    WHEN 'album' THEN (SELECT a.title FROM albums a WHERE a.id = hi.ref_id)
    WHEN 'artist' THEN (SELECT ar.name FROM artists ar WHERE ar.id = hi.ref_id)
    WHEN 'playlist' THEN (SELECT p.name FROM playlists p WHERE p.id = hi.ref_id)
    WHEN 'track' THEN (SELECT t.title FROM tracks t WHERE t.id = hi.ref_id)
  END AS ref_title,
  CASE hi.kind
    WHEN 'album' THEN (SELECT ar.name FROM albums a
                        JOIN artists ar ON ar.id = a.album_artist_id
                       WHERE a.id = hi.ref_id)
    WHEN 'track' THEN (SELECT ar.name FROM track_credits tc
                        JOIN artists ar ON ar.id = tc.artist_id
                       WHERE tc.track_id = hi.ref_id
                         AND tc.role = 'mainArtist'
                       ORDER BY tc.sort_order LIMIT 1)
  END AS ref_subtitle,
  CASE hi.kind
    WHEN 'album' THEN (SELECT im.stored_path FROM v_album_artwork va
                        JOIN images im ON im.id = va.image_id
                       WHERE va.album_id = hi.ref_id)
    WHEN 'artist' THEN (SELECT im.stored_path FROM artists ar
                         JOIN images im ON im.id = ar.image_id
                        WHERE ar.id = hi.ref_id)
    WHEN 'playlist' THEN (SELECT im.stored_path FROM playlists p
                           JOIN images im ON im.id = p.image_id
                          WHERE p.id = hi.ref_id)
    WHEN 'track' THEN (SELECT im.stored_path FROM v_track_artwork vt
                        JOIN images im ON im.id = vt.image_id
                       WHERE vt.track_id = hi.ref_id)
  END AS ref_image,
  CASE hi.kind
    WHEN 'album' THEN (SELECT COUNT(*) FROM tracks t WHERE t.album_id = hi.ref_id)
    WHEN 'artist' THEN (SELECT COUNT(DISTINCT tc.track_id) FROM track_credits tc
                         WHERE tc.artist_id = hi.ref_id)
    WHEN 'playlist' THEN (SELECT COUNT(*) FROM playlist_items pi
                           WHERE pi.playlist_id = hi.ref_id)
    WHEN 'track' THEN 1
    ELSE 0
  END AS ref_tracks
FROM home_items hi
LEFT JOIN images own ON own.id = hi.image_id
WHERE hi.section_id = ?1
ORDER BY hi.position, hi.id
''';
