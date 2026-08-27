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

    final where = <String>[];
    final variables = <Variable<Object>>[];
    final at = (now ?? DateTime.now()).toUtc();

    // The word half. Resolved through the index first, then intersected: FTS5
    // cannot be joined against a filtered table cheaply, and the id list is
    // small enough to hand back as a literal.
    if (query.terms.isNotEmpty) {
      final matches = await searchTracks(
        query.terms.join(' '),
        limit: _termLimit,
      );
      if (matches.isEmpty) return const [];
      // Integers straight out of the database, never user text.
      where.add('t.id IN (${matches.join(',')})');
    }

    for (final clause in query.clauses) {
      final (sql, args) = _sqlFor(clause, at);
      if (sql == null) continue;
      where.add(clause.negated ? 'NOT ($sql)' : sql);
      variables.addAll(args);
    }

    if (where.isEmpty) return const [];

    final rows = await db
        .customSelect(
          'SELECT t.id AS id FROM tracks t '
          'LEFT JOIN albums alb ON alb.id = t.album_id '
          'WHERE ${where.join(' AND ')} '
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
          },
        )
        .get();

    return [for (final row in rows) row.read<int>('id')];
  }

  /// A human-readable account of what a query selects, for the playlist page.
  String describe(String text) => SmartQuery.parse(text).describe();

  // -------------------------------------------------------------------- SQL

  (String?, List<Variable<Object>>) _sqlFor(QueryClause clause, DateTime now) {
    switch (clause) {
      case NameClause(:final field, :final value):
        // Prefix matching, like the rest of search: nobody should have to
        // finish typing a name to find out whether the query works.
        final pattern = '${value.toLowerCase()}%';
        return switch (field) {
          // Any credit, in any role, so a guest appearance counts.
          QueryField.artist => (
              'EXISTS (SELECT 1 FROM track_credits tc '
                  'JOIN artists a ON a.id = tc.artist_id '
                  'WHERE tc.track_id = t.id AND ('
                  'lower(a.name) LIKE ?'
                  ' OR EXISTS (SELECT 1 FROM artist_aliases al '
                  'WHERE al.artist_id = a.id AND lower(al.alias) LIKE ?)))',
              [Variable(pattern), Variable(pattern)],
            ),
          QueryField.album => (
              'lower(alb.title) LIKE ?',
              [Variable(pattern)],
            ),
          QueryField.title => (
              'lower(t.title) LIKE ?',
              [Variable(pattern)],
            ),
          // The effective tags, so a tag on the album or on a playlist counts
          // here exactly as it counts everywhere else.
          QueryField.tag => (
              'EXISTS (SELECT 1 FROM v_track_effective_tags e '
                  'JOIN tags g ON g.id = e.tag_id '
                  'WHERE e.track_id = t.id AND lower(g.name) LIKE ?)',
              [Variable(pattern)],
            ),
          _ => (null, const []),
        };

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
    }
  }

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
