import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/domain/models/home_views.dart';
import 'package:marmelade/data/repositories/home_repository.dart';
import 'package:marmelade/features/home/home_drag.dart';
import 'package:marmelade/features/home/home_tile.dart';
import 'package:marmelade/features/home/home_view.dart';
import 'package:marmelade/features/home/section_header.dart';
import 'package:marmelade/services/art/art_store.dart';

import '../support/silent_player.dart';

/// The home page, as a page rather than as storage.
///
/// What is checked here is the behaviour the brief asked for and nothing
/// else: a list stops at ten and says so, a grid does not, a group opens into
/// its contents, and the whole arranging surface stays out of the way until
/// it is asked for.
void main() {
  late MarmeladeDatabase db;
  late Directory artRoot;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    artRoot = Directory.systemTemp.createTempSync('marmelade_home_art_');
  });

  tearDown(() async {
    await db.close();
    if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
  });

  HomeItemView album(String title, {int id = 1}) => HomeItemView(
        id: id,
        kind: HomeItemKind.album,
        title: title,
        refId: id,
        subtitle: 'PinocchioP',
      );

  HomeItemView collectionItem(String title, List<HomeItemView> children,
          {int id = 90}) =>
      HomeItemView(
        id: id,
        kind: HomeItemKind.collection,
        title: title,
        children: children,
        subtitle: '${children.length} items',
      );

  HomeSectionView sectionOf(
    List<HomeItemView> items, {
    String title = 'Mine',
    HomeLayout layout = HomeLayout.grid,
  }) =>
      HomeSectionView(
        id: 1,
        title: title,
        layout: layout,
        source: HomeSectionSource.curated,
        items: items,
      );

  /// The opacity an AnimatedOpacity is currently showing [finder] at.
  double opacityOf(WidgetTester tester, Finder finder) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(of: finder, matching: find.byType(AnimatedOpacity)).first,
      )
      .opacity;

  Future<void> open(
    WidgetTester tester,
    List<HomeSectionView> sections, {
    Size size = const Size(1200, 900),
    void Function(int id, int? beforeId, int? parentId)? onMove,
    void Function(int targetId)? onCombine,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          artStoreProvider.overrideWithValue(ArtStore(artRoot)),
          playbackEngineProvider.overrideWithValue(SilentEngine()),
          playerProvider.overrideWith(() => IdlePlayer(db)),
          // A live drift stream here posts a cleanup timer after the scope is
          // torn down, which fails the test with "a Timer is still pending".
          homeProvider.overrideWith((ref) => Stream.value(sections)),
          // The page is fed a fixed list, so a real move would write to a
          // database nothing here reads back. Recording the call is what the
          // assertion is actually about: that the gesture resolved to the
          // right move, before/into and all.
          if (onMove != null || onCombine != null)
            homeRepositoryProvider.overrideWith(
              (ref) => _RecordingHome(db, onMove, onCombine),
            ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: HomeView(
              onOpenAlbum: (_) {},
              onOpenArtist: (_) {},
              onOpenPlaylist: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows a section and what is in it', (tester) async {
    await open(tester, [sectionOf([album('Antenna')])]);

    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('Antenna'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a list stops at ten and offers the rest', (tester) async {
    // The brief's number. A list longer than a glance stops being a glance.
    await open(tester, [
      sectionOf(
        [for (var i = 0; i < 14; i++) album('Album $i', id: i + 1)],
        layout: HomeLayout.list,
      ),
    ]);

    expect(find.text('Album 0'), findsOneWidget);
    expect(find.text('Album 9'), findsOneWidget);
    expect(find.text('Album 10'), findsNothing);
    expect(find.text('View all 14'), findsOneWidget);
  });

  testWidgets('a list row stays reachable in a wide window', (tester) async {
    // A row is a thumbnail, a name and a play button. Stretched across a
    // maximised window, the button ends up most of a screen from the name it
    // belongs to, which is a long way to travel to press play.
    await open(
      tester,
      [
        sectionOf([album('Antenna')], layout: HomeLayout.list),
      ],
      size: const Size(1900, 900),
    );

    final row = tester.getSize(find.byType(HomeRow));

    expect(row.width, lessThanOrEqualTo(720));
  });

  testWidgets('a grid is not capped the way a list is', (tester) async {
    await open(tester, [
      sectionOf([for (var i = 0; i < 14; i++) album('Album $i', id: i + 1)]),
    ]);

    expect(find.text('View all 14'), findsNothing);
    expect(find.text('Album 11'), findsOneWidget);
  });

  testWidgets('"View all" opens the whole list', (tester) async {
    await open(tester, [
      sectionOf(
        [for (var i = 0; i < 12; i++) album('Album $i', id: i + 1)],
        layout: HomeLayout.list,
      ),
    ]);

    await tester.tap(find.text('View all 12'));
    await tester.pumpAndSettle();

    // The eleventh item is past both the list's ten-row preview and the
    // dialog's own height, so finding it means the dialog really does hold
    // the whole section rather than a longer slice of it.
    await tester.scrollUntilVisible(
      find.text('Album 11'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();

    expect(find.text('Album 11'), findsOneWidget);
  });

  testWidgets('a collection opens into its contents', (tester) async {
    await open(tester, [
      sectionOf([
        collectionItem('Soundtracks', [album('Rain World', id: 2)]),
      ]),
    ]);

    expect(find.text('Rain World'), findsNothing, reason: 'closed to begin with');

    await tester.tap(find.text('Soundtracks'));
    await tester.pumpAndSettle();

    expect(find.text('Rain World'), findsOneWidget);
    expect(find.text('Play all'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a collection inside a collection opens again, with no special case',
      (tester) async {
    await open(tester, [
      sectionOf([
        collectionItem(
          'Outer',
          [
            collectionItem('Inner', [album('Deep', id: 3)], id: 91),
          ],
        ),
      ]),
    ]);

    await tester.tap(find.text('Outer'));
    await tester.pumpAndSettle();
    expect(find.text('Inner'), findsOneWidget);

    await tester.tap(find.text('Inner'));
    await tester.pumpAndSettle();

    expect(find.text('Deep'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  
  
  testWidgets('a computed section offers no way to add to it', (tester) async {
    // Its contents are a fact about what was played, so there is nothing to
    // put in it by hand and no plus to offer.
    await open(tester, [
      HomeSectionView(
        id: 2,
        title: 'Recently played',
        layout: HomeLayout.grid,
        source: HomeSectionSource.recentlyPlayed,
        items: [
          const HomeItemView(
            id: -1,
            kind: HomeItemKind.track,
            title: 'Heard it',
            refId: 5,
          ),
        ],
      ),
    ]);

    expect(find.byTooltip('Add items to "Recently played"'), findsNothing);
  });

  testWidgets('an empty page says so and offers the way out of it',
      (tester) async {
    await open(tester, const []);

    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.text('New section'), findsOneWidget);
  });

  group('a section header carries its own settings', () {
    testWidgets('the plus appears on hover and nowhere else', (tester) async {
      // What the arranging mode used to reveal, attached to the thing it
      // acts on instead of to a toggle somewhere else.
      await open(tester, [
        sectionOf([album('One')]),
      ]);

      final plus = find.byTooltip('Add items to "Mine"');
      expect(plus, findsOneWidget, reason: 'built, so it can be reached');
      expect(opacityOf(tester, plus), 0, reason: 'but invisible at rest');

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Mine')));
      await tester.pumpAndSettle();

      expect(opacityOf(tester, plus), 1);
    });

    testWidgets('right-clicking offers layout, rename and removal',
        (tester) async {
      await open(tester, [
        sectionOf([album('One')]),
      ]);

      await tester.tapAt(
        tester.getCenter(find.text('Mine')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('Show as a list'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Give it an icon'), findsOneWidget);
      expect(find.text('Remove section'), findsOneWidget);
    });

    testWidgets('a collapsed section shows its header and nothing else',
        (tester) async {
      await open(tester, [
        HomeSectionView(
          id: 1,
          title: 'Mine',
          layout: HomeLayout.grid,
          source: HomeSectionSource.curated,
          collapsed: true,
          items: [album('One')],
        ),
      ]);

      expect(find.text('Mine'), findsOneWidget);
      expect(find.text('One'), findsNothing);
      expect(find.byTooltip('Expand'), findsOneWidget);
    });

    testWidgets('an icon stands in for the chevron without replacing its job',
        (tester) async {
      await open(tester, [
        HomeSectionView(
          id: 1,
          title: 'Mine',
          layout: HomeLayout.grid,
          source: HomeSectionSource.curated,
          icon: 0xe3af,
          items: [album('One')],
        ),
      ]);

      // Still the collapse control -- it has only been given a face.
      expect(find.byTooltip('Collapse'), findsOneWidget);
    });
  });

  group('dragging', () {
    /// Starts a drag on [from] and releases it over [to].
    ///
    /// Stepped rather than dropped in one move: a LongPressDraggable needs
    /// the press held before it picks anything up, and DragTarget only
    /// recomputes which part of a tile is under the pointer on movement.
    Future<void> drag(WidgetTester tester, Finder from, Offset to) async {
      final gesture = await tester.startGesture(tester.getCenter(from));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveTo(to);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(to);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('every item is draggable, with no mode to switch on',
        (tester) async {
      await open(tester, [
        sectionOf([album('One', id: 1), album('Two', id: 2)]),
      ]);

      expect(find.byType(LongPressDraggable<HomeDrag>), findsNWidgets(2));
    });

    testWidgets('a computed section is still not draggable', (tester) async {
      await open(tester, [
        HomeSectionView(
          id: 3,
          title: 'Recently played',
          layout: HomeLayout.grid,
          source: HomeSectionSource.recentlyPlayed,
          items: [
            const HomeItemView(
              id: -1,
              kind: HomeItemKind.track,
              title: 'Heard it',
              refId: 5,
            ),
          ],
        ),
      ]);

      expect(find.byType(LongPressDraggable<HomeDrag>), findsNothing);
    });

    testWidgets('dropping one item on another reorders them', (tester) async {
      final moves = <({int id, int? before, int? parent})>[];
      await open(
        tester,
        [
          sectionOf([album('One', id: 1), album('Two', id: 2)]),
        ],
        onMove: (id, before, parent) =>
            moves.add((id: id, before: before, parent: parent)),
      );

      final target = tester.getTopLeft(find.text('One'));
      await drag(tester, find.text('Two'), target + const Offset(6, -40));

      expect(moves.single.id, 2);
      expect(moves.single.before, 1);
      expect(moves.single.parent, isNull);
    });

    testWidgets('dropping an item on the middle of a collection puts it inside',
        (tester) async {
      final moves = <({int id, int? before, int? parent})>[];
      await open(
        tester,
        [
          sectionOf([
            album('Loose', id: 1),
            collectionItem('Box', const [], id: 9),
          ]),
        ],
        onMove: (id, before, parent) =>
            moves.add((id: id, before: before, parent: parent)),
      );

      await drag(
        tester,
        find.text('Loose'),
        tester.getCenter(
          find.ancestor(
            of: find.text('Box'),
            matching: find.byType(HomeDraggable),
          ),
        ),
      );

      expect(moves.single.parent, 9, reason: 'into it, not beside it');
    });

    testWidgets('dropping on the middle of a plain tile combines them',
        (tester) async {
      final combines = <int>[];
      await open(
        tester,
        [
          sectionOf([album('One', id: 1), album('Two', id: 2)]),
        ],
        onCombine: combines.add,
      );

      await drag(
        tester,
        find.text('Two'),
        tester.getCenter(
          find.ancestor(
            of: find.text('One'),
            matching: find.byType(HomeDraggable),
          ),
        ),
      );

      expect(combines, [1], reason: 'wrapped around the tile aimed at');
    });

    testWidgets('gaps for a new section appear only while dragging',
        (tester) async {
      await open(tester, [
        sectionOf([album('One', id: 1)]),
      ]);
      expect(find.text('New section here'), findsNothing);

      // Measured before the drag starts: once it does, the drag chip shows
      // the same title and the finder is ambiguous from then on.
      final start = tester.getCenter(find.text('One'));
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveTo(start + const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('New section here'), findsNWidgets(2));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('New section here'), findsNothing);
    });

    testWidgets('an end-drop zone appears only while dragging', (tester) async {
      await open(tester, [
        sectionOf([album('One', id: 1)]),
      ]);
      expect(find.byType(HomeDropEnd), findsNothing);

      final start = tester.getCenter(find.text('One'));
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveTo(start + const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(HomeDropEnd), findsOneWidget);

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a long press on a tile does not move its section',
        (tester) async {
      // Only the header starts a section drag. Wrapping the whole block
      // would have made a long press on a tile race the tile's own drag,
      // and which won would come down to whose delay was shorter.
      await open(tester, [
        sectionOf([album('One', id: 1)]),
      ]);

      final tile = find.ancestor(
        of: find.text('One'),
        matching: find.byType(HomeDraggable),
      );
      expect(
        find.descendant(
          of: tile,
          matching: find.byType(ReorderableDelayedDragStartListener),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(SectionHeader),
          matching: find.byType(ReorderableDelayedDragStartListener),
        ),
        findsNothing,
        reason: 'the listener is around the header, not inside it',
      );
      expect(
        find.ancestor(
          of: find.byType(SectionHeader),
          matching: find.byType(ReorderableDelayedDragStartListener),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a collection always shows its badge', (tester) async {
      await open(tester, [
        sectionOf([collectionItem('Box', const [], id: 9)]),
      ]);

      expect(find.byTooltip('0 inside'), findsOneWidget);
    });
  });

  group('a search inside a collection', () {
    /// A collection holding a hand-picked album, a search, and another album
    /// -- the shape the brief asks for: A, all of Q, then B.
    HomeItemView mixed() => collectionItem(
          'Mixed',
          [
            album('Hand-picked A', id: 1),
            const HomeItemView(
              id: 2,
              kind: HomeItemKind.query,
              title: 'Some search',
              query: 'tag:hardcore',
            ),
            album('Hand-picked B', id: 3),
          ],
          id: 9,
        );

    testWidgets('shows what it matches, in its place between the others',
        (tester) async {
      final trackId = await db.into(db.tracks).insert(
            TracksCompanion.insert(title: 'Found by search', nameKey: 'found'),
          );
      final tagId = await db
          .into(db.tags)
          .insert(TagsCompanion.insert(name: 'hardcore', nameKey: 'hardcore'));
      await db.into(db.trackTags).insert(
            TrackTagsCompanion.insert(trackId: trackId, tagId: tagId),
          );

      await open(tester, [
        sectionOf([mixed()]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      expect(find.text('Hand-picked A'), findsOneWidget);
      expect(find.text('Found by search'), findsOneWidget,
          reason: 'the search became its results');
      expect(find.text('Hand-picked B'), findsOneWidget);
    });

    testWidgets('the rule itself stays reachable, as a chip', (tester) async {
      // Its results are out in the grid, which leaves the rule with nowhere
      // to be clicked unless it is given somewhere of its own.
      await open(tester, [
        sectionOf([mixed()]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(InputChip, 'Some search'), findsOneWidget);
    });
  });

  testWidgets('a collection can be filled from inside it', (tester) async {
    // The add dialog has always said to open a group and use "Add items"
    // inside; until drag-and-drop went in, that button did not exist.
    await open(tester, [
      sectionOf([collectionItem('Box', const [], id: 9)]),
    ]);

    await tester.tap(find.text('Box'));
    await tester.pumpAndSettle();

    expect(find.text('Add items'), findsOneWidget);
  });

  testWidgets('an empty section says what to do about it', (tester) async {
    await open(tester, [sectionOf(const [])]);

    expect(find.textContaining('Use the + beside the title'), findsOneWidget);
  });
}

/// A [HomeRepository] that reports moves instead of performing them.
class _RecordingHome extends HomeRepository {
  _RecordingHome(super.db, this.onMove, this.onCombine);

  final void Function(int id, int? beforeId, int? parentId)? onMove;
  final void Function(int targetId)? onCombine;

  @override
  Future<void> moveItem(
    int itemId, {
    required int sectionId,
    int? newParentId,
    int? beforeId,
  }) async =>
      onMove?.call(itemId, beforeId, newParentId);

  @override
  Future<int?> wrapInCollection({
    required int sectionId,
    required int targetId,
    String title = 'New collection',
  }) async {
    onCombine?.call(targetId);
    return null;
  }
}
