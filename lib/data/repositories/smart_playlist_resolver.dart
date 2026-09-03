import 'package:drift/drift.dart';

import '../../domain/search/smart_query.dart';
import '../db/database.dart';

/// Turns a smart playlist's query into the tracks it currently means.
///
/// Two halves, because the query has two halves. Bare words go to the search
/// index -- which is what lets a smart playlist inherit the credit splitting,
/// so `camellia` collects the collaborations too -- and everything with a field
/// becomes SQL against the catalog, where dates and numbers belong.
///
/// A query can be several `OR`'d groups; each is resolved to its own AND'd
/// condition (the word half included), and the groups are OR'd together in
/// the final `WHERE`. A query with no `OR` at all is just one group, and
/// behaves exactly as it always did.
///
/// Nothing is stored. A smart playlist has no rows of its own: it is the query
/// and the library, evaluated now. That is the whole point of it, and it is also
/// why there is no cache to go stale.
class SmartPlaylistResolver {
  SmartPlaylistResolver({required this.db, required this.searchTracks});

  final MarmeladeDatabase db;

  /// Resolves the word half of a query to track ids, best first.
  ///
  /// A function rather than the search repository itself, because search
  /// hydrates playlist results and playlists resolve through search: holding
  /// the object would be a construction cycle. Narrowing the dependency to the
  /// one call that is actually needed removes the cycle instead of deferring
  /// it.
  final Future<List<int>> Function(String query, {int limit}) searchTracks;

  /// How many index rows the word half of a query will consider.
  ///
  /// Higher than search's own limit: a playlist is allowed to be long, and
  /// "every track by this artist" is an entirely ordinary smart playlist.
  static const _termLimit = 20000;

  /// Resolves [text] to track ids, in the order [sort] asks for.
  ///
  /// [now] is passed in rather than read from the clock so an age clause can be
  /// tested at all.
  Future<List<int>> resolve(
    String text, {
    int? limit,
    String? sort,
    DateTime? now,
  }) async {
    final query = SmartQuery.parse(text);
    if (query.isEmpty) return const [];

    final at = (now ?? DateTime.now()).toUtc();

    final groupSql = <String>[];
    final variables = <Variable<Object>>[];
    for (final group in query.groups) {
      final resolved = await _sqlForGroup(group, at);
      if (resolved == null) continue;
      groupSql.add(resolved.$1);
      variables.addAll(resolved.$2);
    }
    if (groupSql.isEmpty) return const [];

    // Only wrapped in parens when there is more than one: a single group is
    // already the whole WHERE clause, and it can contain its own top-level
    // NOT (...) that parens around it would do nothing to change but still
    // clutter.
    final where = groupSql.length == 1
        ? groupSql.single
        : groupSql.map((g) => '($g)').join(' OR ');

    final rows = await db
        .customSelect(
          'SELECT t.id AS id FROM tracks t '
          'LEFT JOIN albums alb ON alb.id = t.album_id '
          'WHERE $where '
          'ORDER BY ${_orderFor(sort)} '
          '${limit == null ? '' : 'LIMIT $limit'}',
          variables: variables,
          readsFrom: {
            db.tracks,
            db.albums,
            db.trackCredits,
            db.artists,
            db.tags,
            db.trackTags,
            db.albumTags,
            db.mediaFiles,
          },
        )
        .get();

    return [for (final row in rows) row.read<int>('id')];
  }

  /// A human-readable account of what a query selects, for the playlist page.
  String describe(String text) => SmartQuery.parse(text).describe();

  // -------------------------------------------------------------------- SQL

  /// One group's AND'd condition, word half included. Null when the group is
  /// empty, or when its word half matched nothing -- either way, a group that
  /// contributes nothing does not become a bare `OR true` in the final query.
  Future<(String, List<Variable<Object>>)?> _sqlForGroup(
    QueryGroup group,
    DateTime now,
  ) async {
    if (group.isEmpty) return null;

    final where = <String>[];
    final variables = <Variable<Object>>[];

    // The word half. Resolved through the index first, then intersected: FTS5
    // cannot be joined against a filtered table cheaply, and the id list is
    // small enough to hand back as a literal.
    if (group.terms.isNotEmpty) {
      final matches = await searchTracks(
        group.terms.join(' '),
        limit: _termLimit,
      );
      if (matches.isEmpty) return null;
      // Integers straight out of the database, never user text.
      where.add('t.id IN (${matches.join(',')})');
    }

    for (final clause in group.clauses) {
      final (sql, args) = _sqlFor(clause, now);
      if (sql == null) continue;
      where.add(clause.negated ? 'NOT ($sql)' : sql);
      variables.addAll(args);
    }

    if (where.isEmpty) return null;
    return (where.join(' AND '), variables);
  }

  (String?, List<Variable<Object>>) _sqlFor(QueryClause clause, DateTime now) {
    switch (clause) {
      case NameClause(:final field, :final value, :final mode):
        return _nameSql(field, mode, value);

      case NumberClause(:final field, :final comparator, :final value, :final upper):
        final column = switch (field) {
          QueryField.releaseYear => 'COALESCE(t.release_year, alb.release_year)',
          QueryField.rating => 't.rating',
          QueryField.playCount => 't.play_count',
          _ => null,
        };
        if (column == null) return (null, const []);
        if (upper != null) {
          return (
            '$column BETWEEN ? AND ?',
            [Variable(value), Variable(upper)],
          );
        }
        final symbol = switch (comparator) {
          QueryComparator.equal => '=',
          QueryComparator.atLeast => '>=',
          QueryComparator.atMost => '<=',
          QueryComparator.greater => '>',
          QueryComparator.less => '<',
        };
        return ('$column $symbol ?', [Variable(value)]);

      case AgeClause(:final field, :final comparator, :final age):
        final column =
            field == QueryField.added ? 't.added_at' : 't.last_played_at';
        final cutoff = now.subtract(age);
        // "Older than" is a smaller timestamp, so the comparison flips. Writing
        // it out rather than being clever about it: this is exactly the kind of
        // inversion that gets silently reversed in a refactor.
        final flipped = switch (comparator) {
          QueryComparator.greater || QueryComparator.atLeast => '<',
          _ => '>=',
        };
        return (
          '$column IS NOT NULL AND $column $flipped ?',
          [Variable(cutoff)],
        );

      case FlagClause(:final flag):
        return switch (flag) {
          QueryFlag.favourite => ('t.is_favorite = 1', const []),
          QueryFlag.rated => ('t.rating IS NOT NULL', const []),
          QueryFlag.verified => ('t.is_verified = 1', const []),
          QueryFlag.variousArtists => ('alb.is_various_artists = 1', const []),
          // A track can carry more than one file (alternate formats of the
          // same rip); "lossless"/"missing" ask whether any/none of them are,
          // not about one column on the track itself.
          QueryFlag.lossless => (
              'EXISTS (SELECT 1 FROM media_files mf '
                  'WHERE mf.track_id = t.id AND mf.lossless = 1)',
              const [],
            ),
          QueryFlag.missing => (
              'NOT EXISTS (SELECT 1 FROM media_files mf '
                  "WHERE mf.track_id = t.id AND mf.status = 'present')",
              const [],
            ),
          QueryFlag.single => ("alb.kind = 'single'", const []),
          QueryFlag.ep => ("alb.kind = 'ep'", const []),
          QueryFlag.live => ("alb.kind = 'live'", const []),
          QueryFlag.compilation => ("alb.kind = 'compilation'", const []),
          QueryFlag.soundtrack => ("alb.kind = 'soundtrack'", const []),
          QueryFlag.demo => ("alb.kind = 'demo'", const []),
          QueryFlag.mixtape => ("alb.kind = 'mixtape'", const []),
        };
    }
  }

  /// SQL for one name clause, field by field -- artist reaches through
  /// credits and aliases, tag through the album/playlist cascade, album and
  /// title are plain columns.
  (String?, List<Variable<Object>>) _nameSql(
    QueryField field,
    QueryMode mode,
    String value,
  ) {
    switch (field) {
      case QueryField.artist:
        // Any credit, in any role, so a guest appearance counts. A name or
        // its alias, so either counts as a match the same as it does when
        // filed on a track's own credits.
        final name = _matchExpr('a.name', mode, value);
        final alias = _matchExpr('al.alias', mode, value);
        return (
          'EXISTS (SELECT 1 FROM track_credits tc '
              'JOIN artists a ON a.id = tc.artist_id '
              'WHERE tc.track_id = t.id AND ('
              '${name.sql}'
              ' OR EXISTS (SELECT 1 FROM artist_aliases al '
              'WHERE al.artist_id = a.id AND ${alias.sql})))',
          [name.arg, alias.arg],
        );

      case QueryField.album:
        final m = _matchExpr('alb.title', mode, value);
        return (m.sql, [m.arg]);

      case QueryField.title:
        final m = _matchExpr('t.title', mode, value);
        return (m.sql, [m.arg]);

      // The effective tags, so a tag on the album or on a playlist counts
      // here exactly as it counts everywhere else.
      case QueryField.tag:
        final m = _matchExpr('g.name', mode, value);
        return (
          'EXISTS (SELECT 1 FROM v_track_effective_tags e '
              'JOIN tags g ON g.id = e.tag_id '
              'WHERE e.track_id = t.id AND ${m.sql})',
          [m.arg],
        );

      default:
        return (null, const []);
    }
  }

  /// One column's comparison against a name value, in whichever [mode] the
  /// clause was written in.
  ({String sql, Variable<Object> arg}) _matchExpr(
    String column,
    QueryMode mode,
    String value,
  ) =>
      switch (mode) {
        QueryMode.contains => (
            sql: "lower($column) LIKE ? ESCAPE '\\'",
            arg: Variable(_likeContains(value)),
          ),
        QueryMode.exact => (
            sql: 'lower($column) = ?',
            arg: Variable(value.toLowerCase()),
          ),
        // Not lower()'d: the registered `regexp` function folds case itself,
        // so the pattern sees the column exactly as stored -- a raw string
        // written with an explicit [A-Z] still means what it says.
        QueryMode.regex => (sql: '$column REGEXP ?', arg: Variable(value)),
      };

  /// A contains-mode value as a `LIKE` pattern, with the value's own `%`/`_`
  /// escaped so a track literally titled "100%" does not become a wildcard.
  String _likeContains(String value) =>
      '%${_escapeLike(value.toLowerCase())}%';

  String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  /// The ORDER BY for a stored sort key.
  ///
  /// An unknown key falls back to the album running order rather than failing:
  /// a playlist that will not open because its sort key is misspelled is worse
  /// than one that opens in the wrong order.
  String _orderFor(String? sort) => switch (sort) {
        'random' => 'RANDOM()',
        'added:desc' => 't.added_at DESC',
        'added:asc' => 't.added_at',
        'played:desc' => 't.last_played_at DESC',
        'plays:desc' => 't.play_count DESC, t.title',
        'rating:desc' => 't.rating DESC, t.title',
        'year:desc' => 'COALESCE(t.release_year, alb.release_year) DESC',
        'year:asc' => 'COALESCE(t.release_year, alb.release_year)',
        'title' => 't.sort_title, t.title',
        _ => 'alb.sort_title, alb.title, COALESCE(t.disc_no, 1), '
            't.track_no IS NULL, t.track_no, t.title',
      };
}

/// The sort keys the UI offers, with what to call them.
const smartPlaylistSorts = <String, String>{
  '': 'By release',
  'title': 'By title',
  'added:desc': 'Newest first',
  'added:asc': 'Oldest first',
  'plays:desc': 'Most played',
  'rating:desc': 'Highest rated',
  'year:desc': 'Newest release',
  'random': 'Shuffled',
};
