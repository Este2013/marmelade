import 'package:drift/drift.dart';

import '../../core/logging/app_log.dart';
import '../../domain/models/library_views.dart';
import '../../domain/search/smart_query.dart';
import '../db/database.dart';
import 'library_repository.dart';
import 'playlist_repository.dart';
import 'tag_repository.dart';

/// One search, across everything the library knows about.
///
/// Searching has to find a track by anyone credited on it. That is the whole
/// reason this app exists: "Name1 x Name2" is two artists, and typing either
/// name must return the song. The credit splitting does the hard part; here it
/// costs nothing, because the index already lists every credited artist under
/// the track.
///
/// Ranking is tiered rather than scored. A single opaque number is impossible
/// to argue with when a result looks wrong, and "the exact name you typed comes
/// first" is a promise worth being able to check:
///
///   4  the title is exactly what was typed
///   3  the title, or another name it goes by, starts with what was typed
///   2  every word matched the title or an alias
///   1  matched somewhere else -- a credited artist, the album, a category
///   0  matched only as a substring (mid-word, or CJK)
///
/// Within a kind, a tier is broken by how much music the thing accounts for,
/// then by name. Across kinds -- which only matters for the one result the view
/// leads with -- an artist named "Amiga" beats a track called "Amiga".
class SearchRepository {
  SearchRepository({
    required this.db,
    required this.library,
    required this.tags,
    required this.playlists,
    this.resolveAdvanced,
  });

  final MarmeladeDatabase db;
  final LibraryRepository library;
  final TagRepository tags;
  final PlaylistRepository playlists;

  /// Resolves the smart-playlist query language against tracks, for a search
  /// written that way -- `artist:Camellia tag=live`.
  ///
  /// A function rather than a [SmartPlaylistResolver] held directly: the
  /// resolver's own word half runs through [trackIdsMatching], so holding one
  /// another would be the same construction cycle [SmartPlaylistResolver]
  /// itself avoids by taking a callback instead of this repository. Optional
  /// so a caller with nothing to do with playlists can still build this.
  final Future<List<int>> Function(String query, {int limit})? resolveAdvanced;

  /// How many index rows one query will look at.
  ///
  /// A one-letter query prefix-matches most of a large library, and none of
  /// those tail rows can win: anything worth showing matched in a higher tier.
  static const _indexLimit = 600;

  /// Which kind wins a tie, and why: you searched a name, and a name most
  /// often means the artist, then the release, then something you assembled
  /// yourself. A track shares its title with its album often enough that
  /// leading with the album is the better guess.
  static const _kindPreference = [
    SearchEntity.artist,
    SearchEntity.album,
    SearchEntity.playlist,
    SearchEntity.tag,
    SearchEntity.track,
  ];

  /// How many candidates per kind survive to hydration.
  ///
  /// Hydration is what turns an id into a card, and it is the expensive half.
  /// Generous next to the handful actually shown, so the cut only ever bites
  /// into the lowest tier present.
  static const _candidatesPerKind = 40;

  /// Runs a search.
  ///
  /// [perKind] is how many of each kind to return. [kinds] narrows the search
  /// when a caller only wants some of them.
  Future<SearchResults> search(
    String text, {
    int perKind = 6,
    Set<SearchEntity>? kinds,
  }) async {
    // Written in the same grammar a smart playlist is -- `artist:Camellia
    // tag=live`, `is:Favourite` -- rather than a plain word: a field means
    // something specific, so it is answered precisely (tracks matching the
    // query) instead of run through the fuzzy, cross-entity search below.
    final advanced = resolveAdvanced;
    if (advanced != null && SmartQuery.parse(text).clauses.isNotEmpty) {
      return _searchAdvanced(text, advanced, perKind: perKind, kinds: kinds);
    }

    final terms = searchTerms(text);
    if (terms.isEmpty) return SearchResults.empty(text);
    final wanted = kinds ?? SearchEntity.values.toSet();

    // Both caps scale with what was asked for. A caller wanting a thousand
    // results and getting forty, silently, is the kind of bug that reads as a
    // ranking problem for weeks.
    final candidateCap =
        perKind > _candidatesPerKind ? perKind : _candidatesPerKind;
    final rowLimit = perKind > _indexLimit ? perKind : _indexLimit;

    final candidates = <(SearchEntity, int), _Candidate>{};
    var truncated = false;

    void note(
      SearchEntity entity,
      int id,
      int tier,
      String? title,
      String? aliases,
    ) {
      final key = (entity, id);
      final existing = candidates[key];
      if (existing == null) {
        candidates[key] = _Candidate(entity, id, tier, title, aliases);
      } else {
        existing.indexedTitle ??= title;
        existing.indexedAliases ??= aliases;
        if (tier > existing.tier) existing.tier = tier;
      }
    }

    // Words matched against the name, and against any other name the thing is
    // known by. This is the tier people mean when they say "search".
    truncated |= await _matchTokens(
      terms.map((t) => '{title aliases}:${_phrase(t)}').join(' AND '),
      wanted,
      rowLimit,
      (entity, id, title, aliases) => note(entity, id, 2, title, aliases),
    );

    // The same words, unrestricted: this is what finds a song by the artist
    // credited on it, or an album by the artist who made it.
    truncated |= await _matchTokens(
      terms.map(_phrase).join(' AND '),
      wanted,
      rowLimit,
      (entity, id, title, aliases) => note(entity, id, 1, title, aliases),
    );

    // Substrings, which is the only thing that works mid-word and the only
    // thing that works at all for a run of Japanese: the word tokenizer treats
    // one as a single token, so a substring of it can never match there.
    if (db.trigramSearchAvailable) {
      final needle = terms.join(' ');
      void hit(SearchEntity entity, int id) =>
          note(entity, id, 0, null, null);
      if (needle.length >= 3) {
        truncated |= await _matchTrigrams(needle, wanted, rowLimit, hit);
      } else if (needle.runes.any(_writtenWithoutWordBreaks)) {
        // A trigram MATCH needs three characters. Two of them is an entirely
        // ordinary Japanese word rather than half a typed one, so scan the
        // same haystack instead of refusing: slower, but the alternative is
        // telling someone their word is too short to look for.
        truncated |= await _scanHaystack(needle, wanted, rowLimit, hit);
      }
    }

    if (candidates.isEmpty) return SearchResults.empty(text);

    // Promote on the strength of the name itself. Done here rather than in SQL
    // because the index hands back the title it stored, so it is free.
    final folded = terms.join(' ');
    for (final candidate in candidates.values) {
      final title = candidate.indexedTitle;
      if (title != null) {
        final name = foldForSearch(title);
        if (name == folded) {
          candidate.tier = 4;
          continue;
        }
        if (name.startsWith(folded)) {
          candidate.tier = 3;
          continue;
        }
      }
      // Also on the other names it goes by, so an artist whose Japanese alias
      // is what you typed is not beaten by an unrelated one-track artist whose
      // name happens to start the same way.
      //
      // Never tier 4 from here: the index joins every alias into one string, so
      // this can tell that a name starts with the query but not that it *is*
      // the query. A prefix of the wrong alias only nudges the order.
      final aliases = candidate.indexedAliases;
      if (aliases == null || candidate.tier >= 3) continue;
      final otherNames = foldForSearch(aliases);
      if (otherNames.startsWith(folded) || otherNames.contains(' $folded')) {
        candidate.tier = 3;
      }
    }

    // Group, cut to what is worth hydrating, hydrate, then rank properly.
    final byKind = <SearchEntity, List<_Candidate>>{};
    for (final candidate in candidates.values) {
      byKind.putIfAbsent(candidate.entity, () => []).add(candidate);
    }

    final ids = <SearchEntity, List<int>>{};
    for (final entry in byKind.entries) {
      final sorted = entry.value.toList()
        ..sort((a, b) => b.tier.compareTo(a.tier));
      if (sorted.length > candidateCap) {
        AppLog.instance.debug(
          'search dropped low-tier candidates before hydration',
          fields: {
            'kind': entry.key.key,
            'found': sorted.length,
            'kept': candidateCap,
          },
        );
      }
      ids[entry.key] = sorted.take(candidateCap).map((c) => c.id).toList();
    }

    final tierOf = <(SearchEntity, int), int>{
      for (final candidate in candidates.values)
        (candidate.entity, candidate.id): candidate.tier,
    };
    int tier(SearchEntity entity, int id) => tierOf[(entity, id)] ?? 0;

    // One query per kind, all at once: they do not depend on each other.
    final hydrated = await Future.wait([
      _artists(ids[SearchEntity.artist]),
      _albums(ids[SearchEntity.album]),
      _tracks(ids[SearchEntity.track]),
      _tags(ids[SearchEntity.tag]),
      _playlists(ids[SearchEntity.playlist]),
    ]);

    // An index row whose catalog row is gone would make a total lie, so the
    // exact count comes from what hydrated. Only a capped kind falls back to
    // the candidate count, and that one is honestly a floor.
    final totals = <SearchEntity, int>{};
    void total(SearchEntity kind, int hydratedCount) {
      final found = byKind[kind]?.length ?? 0;
      if (found == 0) return;
      totals[kind] = found <= candidateCap ? hydratedCount : found;
    }

    total(SearchEntity.artist, (hydrated[0] as List).length);
    total(SearchEntity.album, (hydrated[1] as List).length);
    total(SearchEntity.track, (hydrated[2] as List).length);
    total(SearchEntity.tag, (hydrated[3] as List).length);
    total(SearchEntity.playlist, (hydrated[4] as List).length);

    final artists = (hydrated[0] as List<ArtistCard>)
        .sortedForSearch(SearchEntity.artist, tier, (a) => a.trackCount,
            (a) => a.name, (a) => a.id)
        .take(perKind)
        .toList();
    final albums = (hydrated[1] as List<AlbumCard>)
        .sortedForSearch(SearchEntity.album, tier, (a) => a.trackCount,
            (a) => a.title, (a) => a.id)
        .take(perKind)
        .toList();
    final tracks = (hydrated[2] as List<TrackRow>)
        .sortedForSearch(SearchEntity.track, tier, (t) => t.playCount,
            (t) => t.title, (t) => t.id)
        .take(perKind)
        .toList();
    final foundTags = (hydrated[3] as List<TagCard>)
        .sortedForSearch(SearchEntity.tag, tier, (t) => t.trackCount,
            (t) => t.name, (t) => t.id)
        .take(perKind)
        .toList();
    final foundPlaylists = (hydrated[4] as List<PlaylistCard>)
        .sortedForSearch(SearchEntity.playlist, tier, (p) => p.trackCount,
            (p) => p.name, (p) => p.id)
        .take(perKind)
        .toList();

    // The single best answer, so the view can lead with it instead of making
    // someone scan five headings for the obvious one.
    final leaders = <(SearchEntity, int, int, int)>[
      if (artists.isNotEmpty)
        (
          SearchEntity.artist,
          artists.first.id,
          tier(SearchEntity.artist, artists.first.id),
          artists.first.trackCount
        ),
      if (albums.isNotEmpty)
        (
          SearchEntity.album,
          albums.first.id,
          tier(SearchEntity.album, albums.first.id),
          albums.first.trackCount
        ),
      if (foundPlaylists.isNotEmpty)
        (
          SearchEntity.playlist,
          foundPlaylists.first.id,
          tier(SearchEntity.playlist, foundPlaylists.first.id),
          foundPlaylists.first.trackCount
        ),
      if (foundTags.isNotEmpty)
        (
          SearchEntity.tag,
          foundTags.first.id,
          tier(SearchEntity.tag, foundTags.first.id),
          foundTags.first.trackCount
        ),
      if (tracks.isNotEmpty)
        (
          SearchEntity.track,
          tracks.first.id,
          tier(SearchEntity.track, tracks.first.id),
          tracks.first.playCount
        ),
    ]..sort((a, b) {
        final byTier = b.$3.compareTo(a.$3);
        if (byTier != 0) return byTier;
        final byKind = _kindPreference
            .indexOf(a.$1)
            .compareTo(_kindPreference.indexOf(b.$1));
        if (byKind != 0) return byKind;
        return b.$4.compareTo(a.$4);
      });

    return SearchResults(
      query: text,
      artists: artists,
      albums: albums,
      tracks: tracks,
      tags: foundTags,
      playlists: foundPlaylists,
      totals: totals,
      truncated: truncated,
      best: leaders.isEmpty
          ? null
          : (entity: leaders.first.$1, id: leaders.first.$2),
    );
  }

  /// Every track the words in [text] match, best first.
  ///
  /// The uncapped sibling of [search], for callers that want the whole set
  /// rather than a page of it: a smart playlist is allowed to be a thousand
  /// tracks long. Ranked the same way, so the first tracks of a smart playlist
  /// are the ones a search for the same words would have led with.
  Future<List<int>> trackIdsMatching(String text, {int limit = 20000}) async {
    final results = await search(
      text,
      perKind: limit,
      kinds: {SearchEntity.track},
    );
    return [for (final track in results.tracks) track.id];
  }

  /// A search written in field syntax: tracks only, since a field like
  /// `artist:` or `is:Favourite` filters tracks, not artists or albums in
  /// their own right.
  Future<SearchResults> _searchAdvanced(
    String text,
    Future<List<int>> Function(String query, {int limit}) advanced, {
    required int perKind,
    Set<SearchEntity>? kinds,
  }) async {
    if (kinds != null && !kinds.contains(SearchEntity.track)) {
      return SearchResults.empty(text);
    }

    final cap = perKind > _candidatesPerKind ? perKind : _candidatesPerKind;
    final ids = await advanced(text, limit: cap);
    if (ids.isEmpty) return SearchResults.empty(text);

    // Hydration does not promise to keep the order it was asked for, so the
    // query's own order (its sort, or its default) is restored afterwards.
    final hydrated = await _tracks(ids);
    final byId = {for (final track in hydrated) track.id: track};
    final ordered = [for (final id in ids) ?byId[id]];

    return SearchResults(
      query: text,
      artists: const [],
      albums: const [],
      tracks: ordered.take(perKind).toList(),
      tags: const [],
      playlists: const [],
      totals: {SearchEntity.track: ids.length},
      truncated: ids.length >= cap,
      best: null,
    );
  }

  // ------------------------------------------------------------------ queries

  /// Runs one MATCH against the word index. Returns whether it hit the limit.
  Future<bool> _matchTokens(
    String match,
    Set<SearchEntity> wanted,
    int rowLimit,
    void Function(
      SearchEntity entity,
      int id,
      String title,
      String aliases,
    ) onHit,
  ) async {
    final rows = await _match(
      'SELECT entity_type, entity_id, title, aliases FROM $ftsTokenTable '
      'WHERE $ftsTokenTable MATCH ?1 LIMIT $rowLimit',
      match,
    );
    for (final row in rows) {
      final entity = _entityOf(row.read<String>('entity_type'));
      if (entity == null || !wanted.contains(entity)) continue;
      final id = int.tryParse(row.read<String>('entity_id'));
      if (id == null) continue;
      onHit(
        entity,
        id,
        row.read<String>('title'),
        row.read<String>('aliases'),
      );
    }
    return rows.length >= rowLimit;
  }

  Future<bool> _matchTrigrams(
    String needle,
    Set<SearchEntity> wanted,
    int rowLimit,
    void Function(SearchEntity entity, int id) onHit,
  ) async {
    final rows = await _match(
      'SELECT entity_type, entity_id FROM $ftsTrigramTable '
      'WHERE $ftsTrigramTable MATCH ?1 LIMIT $rowLimit',
      _phrase(needle),
    );
    for (final row in rows) {
      final entity = _entityOf(row.read<String>('entity_type'));
      if (entity == null || !wanted.contains(entity)) continue;
      final id = int.tryParse(row.read<String>('entity_id'));
      if (id == null) continue;
      onHit(entity, id);
    }
    return rows.length >= rowLimit;
  }

  /// Scans the substring haystack, for a needle too short to MATCH.
  ///
  /// `instr` rather than `LIKE`: LIKE would read `%` and `_` in the needle as
  /// wildcards, so a search for "50_50" would quietly match more than it
  /// should, and escaping them is a detail this does not need. `lower` folds
  /// ASCII only, which is exactly as far as the needle was folded.
  Future<bool> _scanHaystack(
    String needle,
    Set<SearchEntity> wanted,
    int rowLimit,
    void Function(SearchEntity entity, int id) onHit,
  ) async {
    final rows = await _match(
      'SELECT entity_type, entity_id FROM $ftsTrigramTable '
      'WHERE instr(lower(haystack), ?1) > 0 LIMIT $rowLimit',
      needle,
    );
    for (final row in rows) {
      final entity = _entityOf(row.read<String>('entity_type'));
      if (entity == null || !wanted.contains(entity)) continue;
      final id = int.tryParse(row.read<String>('entity_id'));
      if (id == null) continue;
      onHit(entity, id);
    }
    return rows.length >= rowLimit;
  }

  /// Runs a MATCH, treating a rejected expression as no results.
  ///
  /// [searchTerms] and [_phrase] exist so this cannot happen, but a MATCH that
  /// throws would take down the whole view over a typed character. A search box
  /// that finds nothing is a bad search box; one that shows a red screen is a
  /// broken app.
  Future<List<QueryRow>> _match(String sql, String match) async {
    try {
      return await db
          .customSelect(sql, variables: [Variable(match)])
          .get();
    } catch (error) {
      AppLog.instance.warn(
        'search index rejected a query',
        fields: {'match': match, 'error': '$error'},
      );
      return const [];
    }
  }

  SearchEntity? _entityOf(String key) =>
      SearchEntity.values.where((e) => e.key == key).firstOrNull;

  // --------------------------------------------------------------- hydration

  Future<List<ArtistCard>> _artists(List<int>? ids) async {
    if (ids == null || ids.isEmpty) return const [];
    // Not withTracksOnly: an artist with nothing credited yet is still a real
    // page you can open and edit, and hiding it would make search disagree
    // with what the library holds.
    return library.watchArtists(ids: ids, withTracksOnly: false).first;
  }

  Future<List<AlbumCard>> _albums(List<int>? ids) async {
    if (ids == null || ids.isEmpty) return const [];
    return library.watchAlbums(ids: ids).first;
  }

  Future<List<TrackRow>> _tracks(List<int>? ids) async {
    if (ids == null || ids.isEmpty) return const [];
    return library.watchTracks(trackIds: ids).first;
  }

  Future<List<TagCard>> _tags(List<int>? ids) async {
    if (ids == null || ids.isEmpty) return const [];
    return tags.watchTags(ids: ids).first;
  }

  Future<List<PlaylistCard>> _playlists(List<int>? ids) async {
    if (ids == null || ids.isEmpty) return const [];
    final all = await playlists.watchPlaylists().first;
    final wanted = ids.toSet();
    return all.where((p) => wanted.contains(p.id)).toList();
  }

  /// Wraps a term as an FTS5 prefix phrase.
  static String _phrase(String term) =>
      '"${term.replaceAll('"', '""')}"*';
}

/// Whether a character belongs to a script written without spaces.
///
/// It decides whether a very short query is half a word -- where prefix
/// matching is the right answer -- or a whole one, where only a substring
/// search will find it.
bool _writtenWithoutWordBreaks(int rune) =>
    (rune >= 0x3040 && rune <= 0x30FF) || // hiragana and katakana
    (rune >= 0x3400 && rune <= 0x4DBF) || // CJK extension A
    (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK unified ideographs
    (rune >= 0xAC00 && rune <= 0xD7AF) || // hangul syllables
    (rune >= 0xF900 && rune <= 0xFAFF); // CJK compatibility ideographs

/// Splits typed text into search terms.
///
/// User text cannot go into a MATCH expression as-is: FTS5 reads `AND`, `OR`,
/// `NOT`, `NEAR`, `-`, `*`, `:`, `(` and `"` as syntax, so searching for
/// `AC/DC -` would be a syntax error rather than a search. Taking only runs of
/// letters, digits and marks leaves nothing that could be read as an operator,
/// and loses nothing: those characters are separators to the tokenizer anyway.
///
/// Exposed for the tests, which are the only place the exact split matters.
List<String> searchTerms(String text) {
  final matches = RegExp(r'[\p{L}\p{N}\p{M}]+', unicode: true)
      .allMatches(text.toLowerCase());
  return [
    for (final match in matches) foldForSearch(match.group(0)!),
  ]..removeWhere((term) => term.isEmpty);
}

/// Lowercases and strips the diacritics the index also strips.
///
/// Deliberately approximate -- the common Latin ranges, not all of Unicode.
/// It only decides whether a name counts as an *exact* match, never whether
/// something matches at all, so being incomplete costs a ranking nudge rather
/// than a result.
String foldForSearch(String text) {
  const from = 'àáâãäåāăąèéêëēĕėęěìíîïĩīĭįıòóôõöøōŏőùúûüũūŭůűųçćĉċčñńņňýÿŷđďłßæœ';
  const to = 'aaaaaaaaaeeeeeeeeeiiiiiiiiiooooooooouuuuuuuuuucccccnnnnyyyddlsao';
  final lower = text.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    final index = from.indexOf(char);
    buffer.write(index == -1 ? char : to[index]);
  }
  return buffer.toString();
}

/// A hit before it has been turned into something showable.
class _Candidate {
  _Candidate(
    this.entity,
    this.id,
    this.tier,
    this.indexedTitle,
    this.indexedAliases,
  );

  final SearchEntity entity;
  final int id;
  int tier;

  /// The name as the index stored it, when the index handed one back.
  String? indexedTitle;

  /// Every other name it goes by, as the index joined them.
  String? indexedAliases;
}

/// What a search turned up.
class SearchResults {
  const SearchResults({
    required this.query,
    required this.artists,
    required this.albums,
    required this.tracks,
    required this.tags,
    required this.playlists,
    required this.totals,
    required this.truncated,
    required this.best,
  });

  const SearchResults.empty(this.query)
      : artists = const [],
        albums = const [],
        tracks = const [],
        tags = const [],
        playlists = const [],
        totals = const {},
        truncated = false,
        best = null;

  final String query;
  final List<ArtistCard> artists;
  final List<AlbumCard> albums;
  final List<TrackRow> tracks;
  final List<TagCard> tags;
  final List<PlaylistCard> playlists;

  /// How many of each kind matched, before the per-kind cut. What lets the
  /// view offer "43 more" instead of pretending six was all of it.
  final Map<SearchEntity, int> totals;

  /// Whether the index limit was reached, so the totals are a floor.
  final bool truncated;

  /// The one result to lead with, when there is one.
  final ({SearchEntity entity, int id})? best;

  bool get isEmpty =>
      artists.isEmpty &&
      albums.isEmpty &&
      tracks.isEmpty &&
      tags.isEmpty &&
      playlists.isEmpty;

  int get matchCount => totals.values.fold(0, (sum, n) => sum + n);

  /// How many of [kind] matched but are not shown.
  int hidden(SearchEntity kind, int shown) {
    final total = totals[kind] ?? 0;
    return total <= shown ? 0 : total - shown;
  }
}

/// Ranking, shared by every kind so they cannot disagree about it.
extension _SearchOrder<T> on List<T> {
  /// Orders hydrated results: tier, then kind, then reach, then name.
  List<T> sortedForSearch(
    SearchEntity entity,
    int Function(SearchEntity entity, int id) tier,
    int Function(T) reach,
    String Function(T) name,
    int Function(T) idOf,
  ) {
    final sorted = toList();
    sorted.sort((a, b) {
      final byTier = tier(entity, idOf(b)).compareTo(tier(entity, idOf(a)));
      if (byTier != 0) return byTier;
      final byReach = reach(b).compareTo(reach(a));
      if (byReach != 0) return byReach;
      return foldForSearch(name(a)).compareTo(foldForSearch(name(b)));
    });
    return sorted;
  }
}
