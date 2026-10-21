import 'package:drift/drift.dart';

import '../enums.dart';
import 'images.dart';

/// One section of the home page.
///
/// The home page is entirely the user's: there is no built-in arrangement
/// beyond the one row seeded on first run, and every section here was either
/// put there by somebody or can be removed by them.
///
/// [position] is sparse, like the queue's: gaps are left between sections so
/// moving one is a single row write rather than renumbering the rest.
@TableIndex(name: 'idx_home_sections_position', columns: {#position})
class HomeSections extends Table {
  IntColumn get id => integer().autoIncrement()();

  TextColumn get title => text()();

  TextColumn get layout =>
      textEnum<HomeLayout>().withDefault(const Constant('grid'))();

  IntColumn get position => integer()();

  /// Where the contents come from. See [HomeSectionSource].
  TextColumn get source =>
      textEnum<HomeSectionSource>().withDefault(const Constant('curated'))();

  /// Cap on a computed section's length, so "recently played" can be ten
  /// items in one library and thirty in another.
  IntColumn get itemLimit => integer().withDefault(const Constant(20))();

  /// Whether the section is rolled up to its header.
  ///
  /// Stored rather than kept in memory: a home page somebody has collapsed
  /// down to five headers is the shape they chose for it, and having it
  /// spring open again on the next launch would undo that every time.
  BoolColumn get collapsed => boolean().withDefault(const Constant(false))();

  /// Material icon code point, looked up in a fixed list -- never fed to
  /// `IconData` directly, which would defeat icon-font tree-shaking. Null
  /// means the section shows a plain collapse chevron instead.
  IntColumn get icon => integer().nullable()();
}

/// One item on the home page: a tile in a grid, or a row in a list.
///
/// Items are a tree, not a flat list. [parentId] is null for an item sitting
/// directly in its section and set for one nested inside a [HomeItemKind.collection]
/// tile, which is what makes a grid able to open into another grid.
@TableIndex(name: 'idx_home_items_section', columns: {#sectionId})
@TableIndex(name: 'idx_home_items_parent', columns: {#parentId})
class HomeItems extends Table {
  IntColumn get id => integer().autoIncrement()();

  /// The section this belongs to, carried even on a nested item so a whole
  /// section can be read in one query instead of one per level.
  IntColumn get sectionId =>
      integer().references(HomeSections, #id, onDelete: KeyAction.cascade)();

  /// Enclosing collection, or null when the item sits directly in the section.
  IntColumn get parentId =>
      integer().nullable().references(HomeItems, #id, onDelete: KeyAction.cascade)();

  /// Sparse ordering key within the parent, or within the section at top level.
  IntColumn get position => integer()();

  TextColumn get kind => textEnum<HomeItemKind>()();

  /// The row this points at: an album, artist, playlist or track id.
  ///
  /// Null for a collection (which owns its children instead) and for a query
  /// (which carries its own text). Deliberately not a foreign key: the kinds
  /// point at four different tables, and a column cannot reference all of
  /// them. A dangling reference is handled where items are read, by dropping
  /// the item from the result rather than by failing the whole page.
  IntColumn get refId => integer().nullable()();

  /// A name chosen by the user, replacing whatever the referenced row is
  /// called. Always set for a collection, which has nothing else to be named by.
  TextColumn get label => text().nullable()();

  /// What a [HomeItemKind.query] is looking for -- see [HomeQueryType].
  ///
  /// Albums by default: a search put on a home page is far more often "which
  /// records are like this" than "which individual songs are", and a grid of
  /// four hundred song tiles is not a thing anybody arranges on purpose.
  TextColumn get queryType =>
      textEnum<HomeQueryType>().withDefault(const Constant('album'))();

  /// How a search orders what it found -- see [HomeQuerySort].
  ///
  /// `matched` by default, which is to say "leave it alone": the rule often
  /// carries its own opinion about order, and overriding that unasked would
  /// throw it away.
  TextColumn get querySort =>
      textEnum<HomeQuerySort>().withDefault(const Constant('matched'))();

  /// Whether [querySort] runs backwards.
  ///
  /// A flag rather than a second value per order: every order has an obvious
  /// direction and an opposite, and spelling both into [HomeQuerySort] would
  /// double a menu to say what one button says. It applies to `matched` too,
  /// where it reverses the order the rule itself found things in.
  BoolColumn get queryInverted => boolean().withDefault(const Constant(false))();

  /// The smart query, for [HomeItemKind.query]. Stored as typed, in the same
  /// grammar as a smart playlist.
  TextColumn get query => text().nullable()();

  /// An image chosen to stand for this item, overriding whatever artwork it
  /// would otherwise compose or inherit.
  IntColumn get imageId =>
      integer().nullable().references(Images, #id, onDelete: KeyAction.setNull)();

  /// Whether a block inside a collection is rolled up to its header.
  ///
  /// Only means anything for a search, which is the one kind that heads a
  /// run of other things. Stored for the same reason a section's is: a
  /// collection somebody folded down is the shape they chose for it.
  BoolColumn get collapsed => boolean().withDefault(const Constant(false))();

  /// Whether the tile quarters four pictures or shows one whole.
  ///
  /// Separate from [imageId], which only ever answers "which one": a picture
  /// chosen by hand went into the first quarter before this existed, which is
  /// not what choosing a picture means.
  TextColumn get artworkMode =>
      textEnum<HomeArtworkMode>().withDefault(const Constant('quadrant'))();

  /// Pictures pinned to particular quarters, as image ids separated by
  /// commas, with an empty slot meaning "whatever would have gone there".
  ///
  /// A text column rather than four nullable foreign keys or a side table:
  /// there are at most four, they are an override on something that already
  /// has an answer, and a dangling id is handled the same way every other
  /// dangling reference on this page is -- by falling back rather than
  /// failing.
  TextColumn get quadrantImages => text().nullable()();

  /// How many of the contents' covers a collection tile composes when it has no
  /// [imageId] of its own: 1 for a single cover, 4 for a quartered mosaic.
  ///
  /// Only 1 and 4 are offered in the UI; the column is an integer rather than
  /// a two-value enum so a future 9-up needs no migration.
  IntColumn get artworkCount => integer().withDefault(const Constant(4))();
}
