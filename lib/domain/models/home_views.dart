/// Read models for the home page.
///
/// Shaped like the rest of `library_views.dart`: one query per screen rather
/// than one per tile, and plain immutable data so the widget layer never has
/// to know how a home page is stored.
library;

import '../../data/db/enums.dart';

/// One picture in a collection's mosaic, and whether it is of a person.
typedef HomeCover = ({String path, bool round});

/// One section, with its items already resolved and ordered.
class HomeSectionView {
  const HomeSectionView({
    required this.id,
    required this.title,
    required this.layout,
    required this.source,
    required this.items,
    this.itemLimit = 20,
    this.collapsed = false,
    this.icon,
  });

  final int id;
  final String title;
  final HomeLayout layout;
  final HomeSectionSource source;
  final int itemLimit;

  /// Rolled up to its header. Its contents are still loaded -- collapsing is
  /// about the screen, not about what the page knows.
  final bool collapsed;

  /// Material icon code point, or null for the plain collapse chevron.
  final int? icon;

  /// Top-level items. A collection's own contents hang off [HomeItemView.children].
  final List<HomeItemView> items;

  /// How many rows a list shows before handing over to "View all".
  ///
  /// Ten, per the brief. A list longer than that stops being a glance and
  /// starts being a page, and the home page is made of glances.
  static const listPreview = 10;

  bool get isEmpty => items.isEmpty;

  /// What a list actually renders, and whether anything was held back.
  List<HomeItemView> get preview =>
      layout == HomeLayout.list && items.length > listPreview
          ? items.sublist(0, listPreview)
          : items;

  bool get hasMore =>
      layout == HomeLayout.list && items.length > listPreview;
}

/// One tile or row.
class HomeItemView {
  const HomeItemView({
    required this.id,
    required this.kind,
    required this.title,
    this.label,
    this.sectionId = 0,
    this.refId,
    this.subtitle,
    this.query,
    this.queryType = HomeQueryType.album,
    this.querySort = HomeQuerySort.matched,
    this.queryInverted = false,
    this.imagePath,
    this.children = const [],
    this.artworkCount = 4,
    this.artworkMode = HomeArtworkMode.quadrant,
    this.collapsed = false,
    this.quadrantPaths = const [],
    this.trackCount = 0,
  });

  /// Row id in `home_items`, which is what reordering and removal act on.
  /// Negative for an item the user never placed -- see [HomeItemView.computed].
  final int id;

  final HomeItemKind kind;

  /// The section this belongs to, carried on the item rather than looked up.
  ///
  /// A move is written against a section, and a nested item is handed to the
  /// overlay that expands it with no section in sight by then -- threading it
  /// down three levels of recursion is how it ends up null somewhere.
  final int sectionId;

  /// What the tile says: the user's own label when they set one, otherwise
  /// the name of whatever it points at.
  final String title;

  /// The user's own name for this item, or null when they never gave one.
  ///
  /// Kept apart from [title] so a search can tell "called nothing" from
  /// "called something": the first prints its rule, the second prints the
  /// name, and folding them together loses the difference.
  final String? label;

  /// A second line -- an album's artist, a collection's size. Null for none.
  final String? subtitle;

  /// The album, artist, playlist or track this points at.
  final int? refId;

  /// The smart query, for [HomeItemKind.query].
  final String? query;

  /// What that query is looking for. Meaningless on every other kind.
  final HomeQueryType queryType;

  /// How it orders what it found. Meaningless on every other kind.
  final HomeQuerySort querySort;

  /// Whether [querySort] runs backwards.
  final bool queryInverted;

  /// The sentence a search tile says it is: "Albums where tag:hardcore".
  ///
  /// Built here rather than in the widget so the tile, the chip inside a
  /// collection and the add dialog all read the same way -- three places
  /// phrasing the same rule differently is three chances to phrase one of
  /// them wrong.
  String? get querySentence {
    if (query == null || query!.trim().isEmpty) return null;
    final sentence = '${queryType.label} where ${query!.trim()}';
    // The sort is only worth saying when it is not the default: "as found" is
    // what the rule already decided, so printing it adds a clause that tells
    // the reader nothing. Reversed, though, it is worth saying either way --
    // including on "as found", where the clause is the only sign that the
    // list is deliberately back to front rather than simply odd.
    final inverted = queryInverted && querySort.canInvert;
    if (querySort == HomeQuerySort.matched) {
      return inverted ? '$sentence, last match first' : sentence;
    }
    final order = querySort.label.toLowerCase();
    return inverted
        ? '$sentence, by $order, reversed'
        : '$sentence, by $order';
  }

  /// What a tile prints as its name.
  ///
  /// A search with no title of its own is named by its rule, which is the
  /// only honest thing to call it -- and the moment somebody gives it one,
  /// that wins.
  String get displayTitle =>
      kind == HomeItemKind.query ? label ?? querySentence ?? title : title;

  /// The second line a tile actually prints.
  ///
  /// A search has no stored subtitle -- the sentence *is* its subtitle, and
  /// it depends on the type, so it is assembled here rather than written into
  /// the database where a later type change would leave it stale.
  /// Null for a titled search: its rule is already the line above, and
  /// printing it twice says nothing the second time.
  String? get displaySubtitle =>
      subtitle ?? (kind == HomeItemKind.query && label != null
          ? querySentence
          : null);

  /// A single cover, when this item has or inherits exactly one.
  ///
  /// Null on a collection that composes a mosaic instead; the covers for that come
  /// from [children], so a collection never needs artwork of its own to look like
  /// something.
  final String? imagePath;

  /// Contents of a collection, already ordered. Empty for every other kind.
  final List<HomeItemView> children;

  /// How many covers a collection composes when it has none of its own.
  final int artworkCount;

  /// Whether the tile quarters four pictures or shows one whole.
  final HomeArtworkMode artworkMode;

  /// Rolled up to its header, for a search heading a block in a collection.
  final bool collapsed;

  /// Pictures pinned to particular quarters, already resolved to paths.
  ///
  /// Four entries once populated, with null meaning "whatever would have
  /// gone there" -- an override is per slot, so pinning the third says
  /// nothing about the other three.
  final List<String?> quadrantPaths;

  /// How many tracks playing this item would queue, where that is known
  /// without resolving it. Zero means "not counted", not "nothing to play".
  final int trackCount;

  bool get isCollection => kind == HomeItemKind.collection;

  /// True for an item generated by a computed section, which exists only for
  /// as long as it is on screen and cannot be edited or reordered.
  bool get isComputed => id < 0;

  /// The covers a collection tile composes, in order, capped at what it
  /// shows.
  ///
  /// Each carries its own shape rather than only a path: a mosaic holding an
  /// artist has to draw that one cell round, because round means a person
  /// everywhere else in the app and a square portrait in a quartered tile
  /// would be the one place it did not.
  ///
  /// Walks into nested collections rather than stopping at them: a collection
  /// of collections whose own tiles are all mosaics would otherwise compose a
  /// mosaic of nothing. Four deep is far past any arrangement anyone will
  /// build, and the bound is what keeps a collection that somehow contains
  /// itself from hanging the page.
  List<HomeCover> covers({int depth = 0}) {
    final found = <HomeCover>[];
    if (imagePath != null) {
      found.add((path: imagePath!, round: kind.isRound));
    }
    if (depth > 4) return found;
    for (final child in children) {
      if (found.length >= artworkCount) break;
      for (final cover in child.covers(depth: depth + 1)) {
        if (found.length >= artworkCount) break;
        if (!found.any((one) => one.path == cover.path)) found.add(cover);
      }
    }
    return found;
  }

  /// What a collection's tile actually paints, honouring its mode.
  ///
  /// One place, so the tile, the picker's preview and the panel header can
  /// never disagree about what a collection currently looks like -- three
  /// renderings of the same rule is three chances to get one wrong.
  ///
  /// In [HomeArtworkMode.single] this is exactly one cover: the chosen
  /// picture, or the first one it would otherwise have composed. That is the
  /// bug it fixes -- a picture chosen by hand used to become the first
  /// quarter, which is not what choosing a picture means.
  List<HomeCover> paintedCovers() {
    if (!isCollection) return covers();

    if (artworkMode == HomeArtworkMode.single) {
      if (imagePath != null) {
        return [(path: imagePath!, round: false)];
      }
      final auto = covers();
      return auto.isEmpty ? const [] : [auto.first];
    }

    // Quarters: a pinned picture wins its slot, and the rest are filled from
    // the contents in order, skipping anything already pinned so the same
    // cover does not appear twice.
    final auto = covers().where((c) => !quadrantPaths.contains(c.path)).toList();
    final out = <HomeCover>[];
    var next = 0;
    for (var slot = 0; slot < artworkCount; slot++) {
      final pinned = slot < quadrantPaths.length ? quadrantPaths[slot] : null;
      if (pinned != null) {
        out.add((path: pinned, round: _roundFor(pinned)));
      } else if (next < auto.length) {
        out.add(auto[next++]);
      }
    }
    return out;
  }

  /// Whether a pinned path belongs to a person, so the quarter stays round.
  bool _roundFor(String path) {
    for (final cover in covers()) {
      if (cover.path == path) return cover.round;
    }
    return false;
  }
}
