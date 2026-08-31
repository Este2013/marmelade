import 'package:drift/drift.dart';

import '../../domain/text/normalize.dart';
import '../../domain/models/library_views.dart';
import '../db/database.dart';
import '../indexer/search_indexer.dart';

/// What a tag is attached to.
///
/// The four differ only in the join table, so everything here is written once
/// and switched on this.
enum TagTarget {
  track('track_tags', 'track_id', SearchEntity.track),
  album('album_tags', 'album_id', SearchEntity.album),
  artist('artist_tags', 'artist_id', SearchEntity.artist),
  playlist('playlist_tags', 'playlist_id', SearchEntity.playlist);

  const TagTarget(this.table, this.column, this.entity);

  final String table;
  final String column;

  /// What this target is called in the search index. Carried here rather than
  /// derived from [name], which is a different vocabulary.
  final SearchEntity entity;
}

/// Where a tag on a track came from.
enum TagOrigin {
  /// Put on the track itself.
  own,

  /// Inherited from the album the track is on.
  album,

  /// Inherited from a playlist the track is in.
  playlist,
}

/// A tag as attached to something, with where it came from.
class AttachedTag {
  const AttachedTag({
    required this.id,
    required this.name,
    required this.origin,
    this.categoryId,
    this.categoryName,
    this.color,
  });

  final int id;
  final String name;

  /// Own, or inherited from an album or a playlist.
  ///
  /// An inherited tag cannot be removed from the track: it is removed from the
  /// thing that granted it. Saying so is more useful than hiding it.
  final TagOrigin origin;

  final int? categoryId;
  final String? categoryName;
  final int? color;

  bool get isInherited => origin != TagOrigin.own;
}

/// A tag category, for grouping.
class TagCategoryRow {
  const TagCategoryRow({
    required this.id,
    required this.name,
    required this.slug,
    required this.isSystem,
    required this.tagCount,
    this.color,
    this.icon,
  });

  final int id;
  final String name;
  final String slug;

  /// Code point of the icon chosen for this category.
  ///
  /// Stored as a number and looked up in a fixed list of icons rather than fed
  /// to `IconData` directly: Flutter's release build strips unused glyphs, and
  /// an IconData built from a runtime value defeats that -- the tool cannot see
  /// which glyphs are reachable, so it either keeps the whole font or refuses
  /// to build.
  final int? icon;

  /// System categories -- Genre and Language -- are written by the indexer and
  /// cannot be deleted, only renamed and recoloured.
  final bool isSystem;

  final int tagCount;
  final int? color;
}

/// Reads and writes tags, and resolves the cascade.
///
/// Tags go on tracks, albums, artists and playlists. The ones on an album or a
/// playlist reach the tracks inside: `v_track_effective_tags` unions the three
/// sources, so untagging the container untags its tracks with nothing to keep
/// in step.
class TagRepository {
  TagRepository({required this.db, required this.searchIndexer});

  final MarmeladeDatabase db;
  final SearchIndexer searchIndexer;

  // ------------------------------------------------------------------ reading

  /// Watches every tag, with how many tracks carry it once the cascade is
  /// taken into account.
  Stream<List<TagCard>> watchTags({int? categoryId, List<int>? ids}) {
    if (ids != null && ids.isEmpty) return Stream.value(const []);
    final filters = <String>[
      if (categoryId != null) 't.category_id = ?1',
      // Interpolated rather than bound: the count varies per call, and these
      // are integers straight out of the database, never user text.
      if (ids != null) 't.id IN (${ids.join(',')})',
    ];
    final filter = filters.isEmpty ? '' : 'WHERE ${filters.join(' AND ')}';
    return db
        .customSelect(
          '''
      SELECT
        t.id AS id, t.name AS name, t.color AS color,
        t.category_id AS category_id, c.name AS category_name,
        im.stored_path AS image_path,
        (SELECT COUNT(DISTINCT e.track_id) FROM v_track_effective_tags e
          WHERE e.tag_id = t.id) AS track_count,
        (SELECT COUNT(*) FROM tags ch WHERE ch.parent_tag_id = t.id)
          AS child_count
      FROM tags t
      LEFT JOIN tag_categories c ON c.id = t.category_id
      LEFT JOIN images im ON im.id = t.image_id
      $filter
      ORDER BY c.sort_order, c.name, t.sort_order, t.name
      ''',
          variables: [if (categoryId != null) Variable(categoryId)],
          readsFrom: {
            db.tags,
            db.tagCategories,
            db.images,
            db.trackTags,
            db.albumTags,
            db.playlistTags,
            db.playlistItems,
            db.tracks,
          },
        )
        .watch()
        .map(
          (rows) => [
            for (final row in rows)
              TagCard(
                id: row.read<int>('id'),
                name: row.read<String>('name'),
                trackCount: row.read<int>('track_count'),
                categoryId: row.read<int?>('category_id'),
                categoryName: row.read<String?>('category_name'),
                color: row.read<int?>('color'),
                imagePath: row.read<String?>('image_path'),
                childCount: row.read<int>('child_count'),
              ),
          ],
        );
  }

  Stream<List<TagCategoryRow>> watchCategories() {
    return db
        .customSelect(
          '''
      SELECT c.id AS id, c.name AS name, c.slug AS slug, c.color AS color,
             c.icon AS icon, c.is_system AS is_system,
             (SELECT COUNT(*) FROM tags t WHERE t.category_id = c.id) AS n
      FROM tag_categories c
      ORDER BY c.sort_order, c.name
      ''',
          readsFrom: {db.tagCategories, db.tags},
        )
        .watch()
        .map(
          (rows) => [
            for (final row in rows)
              TagCategoryRow(
                id: row.read<int>('id'),
                name: row.read<String>('name'),
                slug: row.read<String>('slug'),
                isSystem: row.read<int>('is_system') == 1,
                tagCount: row.read<int>('n'),
                color: row.read<int?>('color'),
                icon: row.read<int?>('icon'),
              ),
          ],
        );
  }

  /// Watches the tags on one thing.
  ///
  /// For a track this includes what it inherits from its album and from any
  /// playlist it is in, each marked with where it came from. For the other
  /// three it is just their own tags -- nothing cascades *into* an album.
  Stream<List<AttachedTag>> watchTagsOf(TagTarget target, int id) {
    final sql = target == TagTarget.track
        ? '''
      SELECT DISTINCT t.id AS id, t.name AS name, t.color AS color,
             t.category_id AS category_id, c.name AS category_name,
             e.source AS source
        FROM v_track_effective_tags e
        JOIN tags t ON t.id = e.tag_id
        LEFT JOIN tag_categories c ON c.id = t.category_id
       WHERE e.track_id = ?1
       ORDER BY (e.source <> 'track'), c.sort_order, c.name, t.name
      '''
        : '''
      SELECT t.id AS id, t.name AS name, t.color AS color,
             t.category_id AS category_id, c.name AS category_name,
             'own' AS source
        FROM ${target.table} j
        JOIN tags t ON t.id = j.tag_id
        LEFT JOIN tag_categories c ON c.id = t.category_id
       WHERE j.${target.column} = ?1
       ORDER BY c.sort_order, c.name, t.name
      ''';

    return db
        .customSelect(
          sql,
          variables: [Variable(id)],
          readsFrom: {
            db.tags,
            db.tagCategories,
            db.trackTags,
            db.albumTags,
            db.artistTags,
            db.playlistTags,
            db.playlistItems,
            db.tracks,
          },
        )
        .watch()
        .map(
          (rows) => [
            for (final row in rows)
              AttachedTag(
                id: row.read<int>('id'),
                name: row.read<String>('name'),
                origin: switch (row.read<String>('source')) {
                  'album' => TagOrigin.album,
                  'playlist' => TagOrigin.playlist,
                  _ => TagOrigin.own,
                },
                categoryId: row.read<int?>('category_id'),
                categoryName: row.read<String?>('category_name'),
                color: row.read<int?>('color'),
              ),
          ],
        );
  }

  /// Tags whose name or alias matches [query], for a picker.
  Future<List<({int id, String name, String? categoryName, int trackCount})>>
      findTags(String query) async {
    final key = normalizeKey(query);
    if (key.isEmpty) return const [];

    final rows = await db
        .customSelect(
          '''
      SELECT DISTINCT t.id AS id, t.name AS name, c.name AS category_name,
        (SELECT COUNT(DISTINCT e.track_id) FROM v_track_effective_tags e
          WHERE e.tag_id = t.id) AS track_count
      FROM tags t
      LEFT JOIN tag_categories c ON c.id = t.category_id
      LEFT JOIN tag_aliases ta ON ta.tag_id = t.id
      WHERE t.name_key LIKE ?1 OR ta.alias_key LIKE ?1
      ORDER BY (t.name_key = ?2) DESC, track_count DESC, t.name
      LIMIT 40
      ''',
          variables: [Variable('%$key%'), Variable(key)],
          readsFrom: {db.tags, db.tagCategories, db.tagAliases},
        )
        .get();

    return [
      for (final row in rows)
        (
          id: row.read<int>('id'),
          name: row.read<String>('name'),
          categoryName: row.read<String?>('category_name'),
          trackCount: row.read<int>('track_count'),
        ),
    ];
  }

  /// Watches the tracks carrying a tag, cascade included.
  ///
  /// A stream rather than a future because the answer changes without anything
  /// touching the tracks: tagging an album, or adding a track to a tagged
  /// playlist, both move tracks in and out of this set.
  Stream<List<int>> watchTrackIdsWithTag(int tagId) {
    return db
        .customSelect(
          'SELECT DISTINCT track_id FROM v_track_effective_tags '
          'WHERE tag_id = ?1',
          variables: [Variable(tagId)],
          readsFrom: {
            db.trackTags,
            db.albumTags,
            db.playlistTags,
            db.playlistItems,
            db.tracks,
          },
        )
        .watch()
        .map((rows) => [for (final row in rows) row.read<int>('track_id')]);
  }

  /// The tracks carrying a tag, cascade included.
  Future<List<int>> trackIdsWithTag(int tagId) async {
    final rows = await db
        .customSelect(
          'SELECT DISTINCT track_id FROM v_track_effective_tags '
          'WHERE tag_id = ?1',
          variables: [Variable(tagId)],
          readsFrom: {db.trackTags, db.albumTags, db.playlistTags},
        )
        .get();
    return [for (final row in rows) row.read<int>('track_id')];
  }

  // ------------------------------------------------------------------ writing

  /// Finds or creates a tag by name, and returns its id.
  ///
  /// Matching is on the normalised name, so "Hardcore" and "hardcore" are the
  /// same tag -- a library where they are two is a library where neither
  /// finds everything.
  Future<int> upsertTag(String name, {int? categoryId}) async {
    final trimmed = name.trim();
    final key = normalizeKey(trimmed);

    final existing = await db
        .customSelect(
          'SELECT id FROM tags WHERE name_key = ?1 LIMIT 1',
          variables: [Variable(key)],
          readsFrom: {db.tags},
        )
        .getSingleOrNull();
    if (existing != null) return existing.read<int>('id');

    final id = await db.into(db.tags).insert(
          TagsCompanion.insert(
            name: trimmed,
            nameKey: key,
            categoryId: Value(categoryId),
          ),
        );
    await searchIndexer.reindexEntity(SearchEntity.tag, id);
    return id;
  }

  Future<void> renameTag(int tagId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await (db.update(db.tags)..where((t) => t.id.equals(tagId))).write(
      TagsCompanion(
        name: Value(trimmed),
        nameKey: Value(normalizeKey(trimmed)),
      ),
    );
    await searchIndexer.reindexEntity(SearchEntity.tag, tagId);
  }

  Future<void> setTagCategory(int tagId, int? categoryId) =>
      (db.update(db.tags)..where((t) => t.id.equals(tagId)))
          .write(TagsCompanion(categoryId: Value(categoryId)));

  Future<void> setTagColor(int tagId, int? color) =>
      (db.update(db.tags)..where((t) => t.id.equals(tagId)))
          .write(TagsCompanion(color: Value(color)));

  /// Deletes a tag and every attachment of it, everywhere.
  Future<void> deleteTag(int tagId) async {
    await (db.delete(db.tags)..where((t) => t.id.equals(tagId))).go();
    await searchIndexer.removeEntity(SearchEntity.tag, tagId);
  }

  /// Attaches a tag, creating it if the name is new.
  ///
  /// Returns the tag's id, so a caller can show what it just made.
  Future<int> attachByName(
    TagTarget target,
    int id,
    String name, {
    int? categoryId,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return -1;
    final tagId = await upsertTag(trimmed, categoryId: categoryId);
    await attach(target, id, tagId);
    return tagId;
  }

  Future<void> attach(TagTarget target, int id, int tagId) async {
    // The join tables are keyed on the pair, so adding a tag twice is a no-op
    // rather than an error.
    await db.customInsert(
      'INSERT OR IGNORE INTO ${target.table} '
      '(${target.column}, tag_id, source, added_at) VALUES (?1, ?2, ?3, ?4)',
      variables: [
        Variable(id),
        Variable(tagId),
        Variable(DataSource.user.name),
        Variable(DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000),
      ],
      updates: {_tableOf(target)},
    );
    await _reindex(target, id);
  }

  Future<void> detach(TagTarget target, int id, int tagId) async {
    await db.customUpdate(
      'DELETE FROM ${target.table} '
      'WHERE ${target.column} = ?1 AND tag_id = ?2',
      variables: [Variable(id), Variable(tagId)],
      updates: {_tableOf(target)},
      updateKind: UpdateKind.delete,
    );
    await _reindex(target, id);
  }

  TableInfo<Table, dynamic> _tableOf(TagTarget target) => switch (target) {
        TagTarget.track => db.trackTags,
        TagTarget.album => db.albumTags,
        TagTarget.artist => db.artistTags,
        TagTarget.playlist => db.playlistTags,
      };

  Future<void> _reindex(TagTarget target, int id) =>
      searchIndexer.reindexEntity(target.entity, id);

  // --------------------------------------------------------------- categories

  Future<int> createCategory(String name, {int? color}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return -1;
    return db.into(db.tagCategories).insert(
          TagCategoriesCompanion.insert(
            name: trimmed,
            // A slug is derived rather than asked for: it exists so the
            // indexer can find the system categories, and a user-made one only
            // needs to be unique.
            slug: '${normalizeKey(trimmed).replaceAll(' ', '-')}-'
                '${DateTime.now().microsecondsSinceEpoch}',
            color: Value(color),
          ),
        );
  }

  /// Changes a category's name, icon and colour together.
  ///
  /// One call rather than three, because the dialog that edits them commits
  /// once: three writes would mean three rebuilds and three chances for a
  /// half-applied change to be what someone sees.
  ///
  /// A null [icon] or [color] clears it; leave the flag false to keep what is
  /// stored. The flags exist because "no icon" and "do not touch the icon" are
  /// different intentions and null cannot say which.
  Future<void> updateCategory(
    int categoryId, {
    String? name,
    int? icon,
    bool setIcon = false,
    int? color,
    bool setColor = false,
  }) async {
    final assignments = <String>[];
    final variables = <Variable<Object>>[];

    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      assignments.add('name = ?${variables.length + 1}');
      variables.add(Variable(trimmed));
    }
    if (setIcon) {
      assignments.add('icon = ?${variables.length + 1}');
      variables.add(Variable(icon));
    }
    if (setColor) {
      assignments.add('color = ?${variables.length + 1}');
      variables.add(Variable(color));
    }
    if (assignments.isEmpty) return;

    variables.add(Variable(categoryId));
    await db.customUpdate(
      'UPDATE tag_categories SET ${assignments.join(', ')} '
      'WHERE id = ?${variables.length}',
      variables: variables,
      updates: {db.tagCategories},
    );
  }

  Future<void> renameCategory(int categoryId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await (db.update(db.tagCategories)..where((t) => t.id.equals(categoryId)))
        .write(TagCategoriesCompanion(name: Value(trimmed)));
  }

  /// Deletes a category. Its tags survive, uncategorised.
  ///
  /// Refused for the system categories: the indexer writes Genre and Language
  /// on every scan, and deleting one would only mean it reappeared empty.
  Future<bool> deleteCategory(int categoryId) async {
    final row = await db
        .customSelect(
          'SELECT is_system FROM tag_categories WHERE id = ?1',
          variables: [Variable(categoryId)],
        )
        .getSingleOrNull();
    if (row == null || row.read<int>('is_system') == 1) return false;

    await (db.delete(db.tagCategories)..where((t) => t.id.equals(categoryId)))
        .go();
    return true;
  }
}
