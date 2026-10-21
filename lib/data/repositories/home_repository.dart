import 'dart:io';

import 'package:drift/drift.dart';

import '../indexer/catalog_writer.dart';
import '../../services/art/art_store.dart';

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
  HomeRepository(this.db, {this.artStore});

  final MarmeladeDatabase db;

  /// Needed only to put a hand-picked picture on a collection, which is the
  /// one thing here that writes a file. Optional so the many tests that only
  /// read and rearrange can keep constructing this with a database alone.
  final ArtStore? artStore;

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

    // One lookup for every quarter pinned anywhere in this section, rather
    // than resolving the ids inside the main query: `group_concat` over
    // `json_each` would have done it in one pass but promises nothing about
    // order, and for four slots whose meaning *is* their order that is not a
    // promise worth doing without.
    final pinnedIds = <int>{};
    for (final row in rows) {
      pinnedIds.addAll(_idsIn(row.read<String?>('quadrant_images')));
    }
    final paths = <int, String>{};
    if (pinnedIds.isNotEmpty) {
      final found = await db.customSelect(
        'SELECT id, stored_path FROM images WHERE id IN (${pinnedIds.join(',')})',
        readsFrom: {db.images},
      ).get();
      for (final row in found) {
        paths[row.read<int>('id')] = row.read<String>('stored_path');
      }
    }

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
        final item = _viewOf(
          row,
          sectionId,
          paths,
          build(row.read<int>('id'), depth + 1),
        );
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
  HomeItemView? _viewOf(
    QueryRow row,
    int sectionId,
    Map<int, String> paths,
    List<HomeItemView> children,
  ) {
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
      label: row.read<String?>('label'),
      subtitle: switch (kind) {
        HomeItemKind.collection => _countLabel(children),
        // Filled in after construction -- the sentence needs the type, which
        // the view assembles. See [HomeItemView.querySentence].
        HomeItemKind.query => null,
        _ => row.read<String?>('ref_subtitle'),
      },
      refId: row.read<int?>('ref_id'),
      query: row.read<String?>('query'),
      queryType: HomeQueryType.values
              .where((t) => t.name == row.read<String?>('query_type'))
              .firstOrNull ??
          HomeQueryType.album,
      querySort: HomeQuerySort.values
              .where((t) => t.name == row.read<String?>('query_sort'))
              .firstOrNull ??
          HomeQuerySort.matched,
      queryInverted: row.read<bool>('query_inverted'),
      imagePath:
          row.read<String?>('own_image') ?? row.read<String?>('ref_image'),
      children: children,
      artworkCount: row.read<int>('artwork_count'),
      collapsed: row.read<bool>('collapsed'),
      artworkMode: HomeArtworkMode.values
              .where((m) => m.name == row.read<String?>('artwork_mode'))
              .firstOrNull ??
          HomeArtworkMode.quadrant,
      quadrantPaths: _pinnedPaths(row.read<String?>('quadrant_images'), paths),
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
    HomeQueryType? queryType,
    HomeQuerySort? querySort,
    bool? queryInverted,
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
            queryType:
                queryType == null ? const Value.absent() : Value(queryType),
            querySort:
                querySort == null ? const Value.absent() : Value(querySort),
            queryInverted: queryInverted == null
                ? const Value.absent()
                : Value(queryInverted),
          ),
        );
  }

  Future<void> renameItem(int itemId, String? label) =>
      (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
          .write(HomeItemsCompanion(label: Value(label)));

  Future<void> setItemQuery(
    int itemId,
    String query, {
    HomeQueryType? type,
    HomeQuerySort? sort,
    bool? inverted,
  }) =>
      (db.update(db.homeItems)..where((i) => i.id.equals(itemId))).write(
        HomeItemsCompanion(
          query: Value(query),
          queryType: type == null ? const Value.absent() : Value(type),
          querySort: sort == null ? const Value.absent() : Value(sort),
          queryInverted:
              inverted == null ? const Value.absent() : Value(inverted),
        ),
      );

  Future<void> setItemArtworkCount(int itemId, int count) =>
      (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
          .write(HomeItemsCompanion(artworkCount: Value(count)));

  Future<void> setItemImage(int itemId, int? imageId) =>
      (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
          .write(HomeItemsCompanion(imageId: Value(imageId)));

  /// Points a collection at a picture already in the library, named by the
  /// path it is stored under.
  ///
  /// By path rather than by image id because that is what a resolved item
  /// carries: the views the picker is built from know where a cover lives,
  /// not which row in `images` describes it, and widening every one of them
  /// to carry an id would be a lot of plumbing for one dialog.
  /// The image ids a `quadrant_images` column mentions, blanks skipped.
  static Iterable<int> _idsIn(String? csv) => csv == null || csv.isEmpty
      ? const []
      : csv.split(',').map(int.tryParse).whereType<int>();

  /// The four slots as paths, with null for "not pinned".
  ///
  /// Position carries the meaning here, so a blank third entry has to stay a
  /// blank third entry -- and an id whose image has since gone falls back to
  /// null rather than leaving the slot pointing at nothing.
  static List<String?> _pinnedPaths(String? csv, Map<int, String> paths) =>
      csv == null || csv.isEmpty
          ? const []
          : [
              for (final part in csv.split(','))
                paths[int.tryParse(part)],
            ];

  Future<void> setItemCollapsed(int itemId, bool collapsed) =>
      (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
          .write(HomeItemsCompanion(collapsed: Value(collapsed)));

  Future<void> setItemArtworkMode(int itemId, HomeArtworkMode mode) =>
      (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
          .write(HomeItemsCompanion(artworkMode: Value(mode)));

  /// Pins a picture to one quarter, or unpins it with a null path.
  ///
  /// Reads the current pins, replaces one, writes the lot back: four slots
  /// in a text column is not worth a read-modify-write that can be skipped,
  /// and doing it in one place keeps the blank-means-auto encoding in one
  /// place too.
  Future<bool> setQuadrantImage(int itemId, int slot, String? storedPath) async {
    int? imageId;
    if (storedPath != null) {
      final found = await db.customSelect(
        'SELECT id FROM images WHERE stored_path = ?1',
        variables: [Variable(storedPath)],
        readsFrom: {db.images},
      ).getSingleOrNull();
      if (found == null) return false;
      imageId = found.read<int>('id');
    }

    final row = await db.customSelect(
      'SELECT quadrant_images FROM home_items WHERE id = ?1',
      variables: [Variable(itemId)],
      readsFrom: {db.homeItems},
    ).getSingleOrNull();
    if (row == null) return false;

    final current = (row.read<String?>('quadrant_images') ?? '').split(',');
    final slots = [for (var i = 0; i < 4; i++) i < current.length ? current[i] : ''];
    slots[slot] = imageId?.toString() ?? '';

    // All blank means nothing is pinned, which is stored as nothing rather
    // than as ",,," -- the column reads better and means the same.
    final joined = slots.every((one) => one.isEmpty) ? null : slots.join(',');
    await (db.update(db.homeItems)..where((i) => i.id.equals(itemId)))
        .write(HomeItemsCompanion(quadrantImages: Value(joined)));
    return true;
  }

  Future<bool> setItemImageFromPath(int itemId, String storedPath) async {
    final row = await db.customSelect(
      'SELECT id FROM images WHERE stored_path = ?1',
      variables: [Variable(storedPath)],
      readsFrom: {db.images},
    ).getSingleOrNull();
    if (row == null) return false;
    await setItemImage(itemId, row.read<int>('id'));
    return true;
  }

  /// Stores a file in the art store and returns the path it landed on.
  ///
  /// Split out from [setItemPicture] because pinning a quarter needs the
  /// same import but attaches the result somewhere else, and importing the
  /// file twice to do that would be two rows for one picture.
  Future<String?> storePicture(File file) async {
    final store = artStore;
    if (store == null) return null;
    final stored = await store.putFile(file);
    if (stored == null) return null;

    await CatalogWriter(db).upsertImage(
      sha256: stored.sha256,
      storedPath: stored.storedPath,
      mimeType: stored.mimeType,
      byteSize: stored.byteSize,
      width: stored.width,
      height: stored.height,
      kind: ImageKind.userProvided,
      role: ImageRole.front,
      sourceDescription: 'chosen by hand for a home collection',
    );
    return stored.storedPath;
  }

  /// Puts a picture of the user's own choosing on a collection.
  ///
  /// The store is content-addressed, so choosing a file already in the
  /// library costs nothing on disk and cannot end up duplicated -- the same
  /// property the artist and album pickers rely on.
  Future<bool> setItemPicture(int itemId, File file) async {
    final stored = await storePicture(file);
    if (stored == null) return false;
    // Through the path, so this and a pinned quarter take the same route to
    // the same row.
    return setItemImageFromPath(itemId, stored);
  }

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
  Future<List<HomeItemView>> trackItems(
    List<int> trackIds,
    int sectionId, {
    HomeQuerySort sort = HomeQuerySort.matched,
    bool inverted = false,
  }) async {
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
      ${_trackOrderFor(sort, inverted: inverted)}
      ''',
      readsFrom: {db.tracks, db.images, db.trackCredits, db.artists, db.albums},
    ).get();

    if (sort != HomeQuerySort.matched) {
      return [
        for (var i = 0; i < rows.length; i++)
          HomeItemView(
            id: -(i + 1),
            sectionId: sectionId,
            kind: HomeItemKind.track,
            title: rows[i].read<String>('title'),
            subtitle: rows[i].read<String?>('artist_name'),
            refId: rows[i].read<int>('id'),
            imagePath: rows[i].read<String?>('image_path'),
            trackCount: 1,
          ),
      ];
    }

    // Re-ordered to match the ids given: `IN` says nothing about order, and
    // a search's own ranking is the whole reason it was asked. Inverting
    // "as found" means reading that ranking backwards, which is the only
    // thing reversing can mean when there is no column to turn around.
    final order = inverted ? trackIds.reversed.toList() : trackIds;
    final byId = {for (final row in rows) row.read<int>('id'): row};
    return [
      for (var i = 0; i < order.length; i++)
        if (byId[order[i]] case final row?)
          HomeItemView(
            // Negative, like a computed section's rows: these are not in
            // `home_items` and must never look reorderable or removable.
            id: -(i + 1),
            sectionId: sectionId,
            kind: HomeItemKind.track,
            title: row.read<String>('title'),
            subtitle: row.read<String?>('artist_name'),
            refId: order[i],
            imagePath: row.read<String?>('image_path'),
            trackCount: 1,
          ),
    ];
  }

  /// The distinct albums of [trackIds], in the order those tracks matched.
  ///
  /// "Albums where tag:hardcore" means the records that contain such a song,
  /// so a track's album standing in for it is the whole point. Ordered by
  /// first appearance rather than alphabetically, because a query's own sort
  /// is why it was asked that way.
  Future<List<HomeItemView>> albumItemsFor(
    List<int> trackIds,
    int sectionId, {
    HomeQuerySort sort = HomeQuerySort.matched,
    bool inverted = false,
  }) async {
    if (trackIds.isEmpty) return const [];
    final rows = await db.customSelect(
      'SELECT id, album_id FROM tracks '
      'WHERE id IN (${trackIds.join(',')}) AND album_id IS NOT NULL',
      readsFrom: {db.tracks},
    ).get();
    final albumOf = {
      for (final row in rows) row.read<int>('id'): row.read<int>('album_id'),
    };

    final ordered = <int>[];
    for (final trackId in trackIds) {
      final albumId = albumOf[trackId];
      if (albumId != null && !ordered.contains(albumId)) ordered.add(albumId);
    }
    return _hydrate(
      ordered,
      sectionId,
      HomeItemKind.album,
      '''
      SELECT al.id AS id, al.title AS title,
        ar.name AS subtitle,
        im.stored_path AS image_path
      FROM albums al
      LEFT JOIN artists ar ON ar.id = al.album_artist_id
      LEFT JOIN v_album_artwork va ON va.album_id = al.id
      LEFT JOIN images im ON im.id = va.image_id
      WHERE al.id IN (${ordered.isEmpty ? '0' : ordered.join(',')})
      ${_orderFor(sort, HomeItemKind.album, inverted: inverted)}
      ''',
      {db.albums, db.artists, db.images, db.tracks},
      sorted: sort != HomeQuerySort.matched,
      inverted: inverted,
    );
  }

  /// The distinct artists credited on [trackIds], first appearance first.
  ///
  /// Any role, not only the main one -- the same promise an artist's own page
  /// makes, where a guest appearance still counts as their work.
  Future<List<HomeItemView>> artistItemsFor(
    List<int> trackIds,
    int sectionId, {
    HomeQuerySort sort = HomeQuerySort.matched,
    bool inverted = false,
  }) async {
    if (trackIds.isEmpty) return const [];
    final rows = await db.customSelect(
      'SELECT track_id, artist_id FROM track_credits '
      'WHERE track_id IN (${trackIds.join(',')}) ORDER BY sort_order, id',
      readsFrom: {db.trackCredits},
    ).get();
    final byTrack = <int, List<int>>{};
    for (final row in rows) {
      byTrack
          .putIfAbsent(row.read<int>('track_id'), () => [])
          .add(row.read<int>('artist_id'));
    }

    final ordered = <int>[];
    for (final trackId in trackIds) {
      for (final artistId in byTrack[trackId] ?? const <int>[]) {
        if (!ordered.contains(artistId)) ordered.add(artistId);
      }
    }
    return _hydrate(
      ordered,
      sectionId,
      HomeItemKind.artist,
      '''
      SELECT ar.id AS id, ar.name AS title, NULL AS subtitle,
        im.stored_path AS image_path
      FROM artists ar
      LEFT JOIN images im ON im.id = ar.image_id
      WHERE ar.id IN (${ordered.isEmpty ? '0' : ordered.join(',')})
      ${_orderFor(sort, HomeItemKind.artist, inverted: inverted)}
      ''',
      {db.artists, db.images, db.trackCredits},
      sorted: sort != HomeQuerySort.matched,
      inverted: inverted,
    );
  }

  /// Playlists that list one of [trackIds] directly.
  ///
  /// Directly, which means a smart playlist whose query happens to match is
  /// not included: deciding that would mean resolving every playlist in the
  /// library on every redraw, and a search of searches is a different
  /// feature from the one being asked for here.
  Future<List<HomeItemView>> playlistItemsFor(
    List<int> trackIds,
    int sectionId, {
    HomeQuerySort sort = HomeQuerySort.matched,
    bool inverted = false,
  }) async {
    if (trackIds.isEmpty) return const [];
    final rows = await db.customSelect(
      'SELECT DISTINCT playlist_id FROM playlist_items '
      'WHERE track_id IN (${trackIds.join(',')})',
      readsFrom: {db.playlistItems},
    ).get();
    final ordered = [for (final row in rows) row.read<int>('playlist_id')];
    return _hydrate(
      ordered,
      sectionId,
      HomeItemKind.playlist,
      '''
      SELECT p.id AS id, p.name AS title, NULL AS subtitle,
        im.stored_path AS image_path
      FROM playlists p
      LEFT JOIN images im ON im.id = p.image_id
      WHERE p.id IN (${ordered.isEmpty ? '0' : ordered.join(',')})
      ${_orderFor(sort, HomeItemKind.playlist, inverted: inverted)}
      ''',
      {db.playlists, db.images, db.playlistItems},
      sorted: sort != HomeQuerySort.matched,
      inverted: inverted,
    );
  }

  /// Shared tail of the three above: run the hydrating query, then put the
  /// rows back into the order the ids were given in.
  Future<List<HomeItemView>> _hydrate(
    List<int> ids,
    int sectionId,
    HomeItemKind kind,
    String sql,
    Set<ResultSetImplementation<dynamic, dynamic>> reads, {
    bool sorted = false,
    bool inverted = false,
  }) async {
    if (ids.isEmpty) return const [];
    final rows = await db.customSelect(sql, readsFrom: reads).get();

    // When the query carried its own ORDER BY, the rows are already in the
    // order asked for -- inversion included, since it went into the clause.
    // Only the "as found" case needs putting back into the order the ids
    // arrived in, and only there does reversing have to happen here.
    if (sorted) {
      return [
        for (var i = 0; i < rows.length; i++)
          _generated(rows[i], i, sectionId, kind),
      ];
    }

    final order = inverted ? ids.reversed.toList() : ids;
    final byId = {for (final row in rows) row.read<int>('id'): row};
    return [
      for (var i = 0; i < order.length; i++)
        if (byId[order[i]] case final row?)
          HomeItemView(
            // Negative, like every other generated row: these are not in
            // `home_items` and must never look reorderable or removable.
            id: -(i + 1),
            sectionId: sectionId,
            kind: kind,
            title: row.read<String>('title'),
            subtitle: row.read<String?>('subtitle'),
            refId: order[i],
            imagePath: row.read<String?>('image_path'),
          ),
    ];
  }

  /// One generated row as a view. See [_hydrate] for why the id is negative.
  static HomeItemView _generated(
    QueryRow row,
    int index,
    int sectionId,
    HomeItemKind kind,
  ) =>
      HomeItemView(
        id: -(index + 1),
        sectionId: sectionId,
        kind: kind,
        title: row.read<String>('title'),
        subtitle: row.read<String?>('subtitle'),
        refId: row.read<int>('id'),
        imagePath: row.read<String?>('image_path'),
      );

  /// The ORDER BY for a run of songs. Separate from [_orderFor] because a
  /// song is the one kind that has a play count and a last-played date.
  ///
  /// Names an expression only; which way round it runs is [_orderBy]'s
  /// answer, so that a reversed search does not need a second table of
  /// clauses with `DESC` typed into half of them.
  static String _trackOrderFor(HomeQuerySort sort, {bool inverted = false}) {
    final column = switch (sort) {
      HomeQuerySort.matched => null,
      HomeQuerySort.name => 'COALESCE(t.sort_title, t.title) COLLATE NOCASE',
      HomeQuerySort.recentlyAdded => 't.added_at',
      HomeQuerySort.recentlyPlayed => 't.last_played_at',
      HomeQuerySort.mostPlayed => 't.play_count',
      HomeQuerySort.releaseYear =>
        'COALESCE(t.release_year, (SELECT al.release_year FROM albums al '
            'WHERE al.id = t.album_id))',
      HomeQuerySort.duration => 't.duration_ms',
      HomeQuerySort.random => 'RANDOM()',
      HomeQuerySort.trackCount => null,
    };
    return _orderBy(column, sort, inverted);
  }

  /// One expression ordered the way its sort means, inverted or not.
  ///
  /// [HomeQuerySort.descendsByNature] carries the default direction, because
  /// it is a fact about the order rather than about the column: "recently
  /// added" means newest first wherever it is asked.
  static String _orderBy(String? column, HomeQuerySort sort, bool inverted) {
    if (column == null) return '';
    // A shuffle read backwards is still a shuffle. Returning it unchanged
    // rather than refusing keeps the caller from having to know that.
    if (sort == HomeQuerySort.random) return 'ORDER BY $column';
    final descending = sort.descendsByNature != inverted;
    return 'ORDER BY $column${descending ? ' DESC' : ''}';
  }

  /// The ORDER BY a sort means for a given kind, or nothing for "as found".
  ///
  /// Written per kind because the columns differ: an album is ordered by its
  /// own `sort_title` and an artist by `sort_name`, and neither has the
  /// other's. A sort that does not apply falls through to no clause rather
  /// than to a guess -- [HomeQuerySort.forType] is what stops the UI offering
  /// one in the first place, and this is the backstop behind it.
  static String _orderFor(
    HomeQuerySort sort,
    HomeItemKind kind, {
    bool inverted = false,
  }) {
    final name = switch (kind) {
      HomeItemKind.album => 'COALESCE(al.sort_title, al.title)',
      HomeItemKind.artist => 'COALESCE(ar.sort_name, ar.name)',
      HomeItemKind.playlist => 'p.name',
      _ => 'title',
    };
    final added = switch (kind) {
      HomeItemKind.album => 'al.created_at',
      HomeItemKind.artist => 'ar.created_at',
      HomeItemKind.playlist => 'p.created_at',
      _ => null,
    };
    final counted = switch (kind) {
      HomeItemKind.album =>
        '(SELECT COUNT(*) FROM tracks t WHERE t.album_id = al.id)',
      HomeItemKind.artist =>
        '(SELECT COUNT(DISTINCT tc.track_id) FROM track_credits tc '
            'WHERE tc.artist_id = ar.id)',
      HomeItemKind.playlist =>
        '(SELECT COUNT(*) FROM playlist_items pi WHERE pi.playlist_id = p.id)',
      _ => null,
    };
    final length = switch (kind) {
      HomeItemKind.album =>
        '(SELECT COALESCE(SUM(t.duration_ms), 0) FROM tracks t '
            'WHERE t.album_id = al.id)',
      _ => null,
    };

    final column = switch (sort) {
      HomeQuerySort.matched => null,
      HomeQuerySort.name => '$name COLLATE NOCASE',
      HomeQuerySort.recentlyAdded => added,
      HomeQuerySort.releaseYear =>
        kind == HomeItemKind.album ? 'al.release_year' : null,
      HomeQuerySort.trackCount => counted,
      HomeQuerySort.duration => length,
      HomeQuerySort.random => 'RANDOM()',
      // Neither belongs to an album, an artist or a playlist -- they are
      // facts about a song, handled by the track path instead.
      HomeQuerySort.recentlyPlayed || HomeQuerySort.mostPlayed => null,
    };
    return _orderBy(column, sort, inverted);
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
    HomeQueryType? queryType,
    HomeQuerySort? querySort,
  }) async {
    final id = await addItem(
      sectionId: sectionId,
      kind: kind,
      parentId: parentId,
      refId: refId,
      label: label,
      query: query,
      queryType: queryType,
      querySort: querySort,
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
  hi.artwork_count AS artwork_count, hi.query_type AS query_type,
  hi.artwork_mode AS artwork_mode, hi.quadrant_images AS quadrant_images,
  hi.collapsed AS collapsed,
  hi.query_sort AS query_sort, hi.query_inverted AS query_inverted,
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
