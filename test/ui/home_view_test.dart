import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/domain/models/home_views.dart';
import 'package:marmelade/data/repositories/home_repository.dart';
import 'package:marmelade/features/home/home_drag.dart';
import 'package:marmelade/features/home/drag_scroll.dart';
import 'package:marmelade/features/library/album_detail_view.dart';
import 'package:marmelade/features/library/artist_detail_view.dart';
import 'package:marmelade/features/home/home_artwork.dart';
import 'package:marmelade/features/home/home_tile.dart';
import 'package:marmelade/features/home/home_view.dart';
import 'package:marmelade/features/home/query_fields.dart';
import 'package:marmelade/widgets/artwork.dart';
import 'package:marmelade/features/home/section_header.dart';
import 'package:marmelade/features/playlists/smart_query_field.dart';
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
    void Function(bool collapsed)? onCollapse,
    void Function(int itemId, bool collapsed)? onCollapseItem,
    void Function(int albumId)? onOpenAlbum,
    void Function(int artistId)? onOpenArtist,
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
          if (onMove != null ||
              onCombine != null ||
              onCollapse != null ||
              onCollapseItem != null)
            homeRepositoryProvider.overrideWith(
              (ref) => _RecordingHome(
                db,
                onMove,
                onCombine,
                onCollapse,
                onCollapseItem,
              ),
            ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: HomeView(
              onOpenAlbum: onOpenAlbum ?? (_) {},
              onOpenArtist: onOpenArtist ?? (_) {},
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

    testWidgets('the whole bar collapses, not just the title', (tester) async {
      // Hitting the few characters of a short word is a worse target than
      // the row it sits in.
      final collapses = <bool>[];
      await open(
        tester,
        [
          sectionOf([album('One')], title: 'Hi'),
        ],
        onCollapse: collapses.add,
      );

      // Far to the right of a two-letter title, where there is nothing but
      // empty header.
      final bar = tester.getRect(find.byType(SectionHeader));
      await tester.tapAt(Offset(bar.right - 24, bar.center.dy));
      await tester.pumpAndSettle();

      expect(collapses, [true]);
    });

    testWidgets('right-clicking the empty part of the bar still opens the menu',
        (tester) async {
      await open(tester, [
        sectionOf([album('One')], title: 'Hi'),
      ]);

      final bar = tester.getRect(find.byType(SectionHeader));
      await tester.tapAt(
        Offset(bar.right - 24, bar.center.dy),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
    });

    testWidgets('the bar stretches the full width it is given', (tester) async {
      await open(
        tester,
        [
          sectionOf([album('One')], title: 'Hi'),
        ],
        size: const Size(1600, 900),
      );

      final bar = tester.getSize(find.byType(SectionHeader));

      // The page pads 28 each side; anything much narrower than that means
      // the row collapsed to its content and most of it is not a target.
      expect(bar.width, greaterThan(1600 - 28 * 2 - 80));
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

    testWidgets('the slot after the last item is reachable', (tester) async {
      // Every other target means "before this one", which leaves the end of
      // a run with nothing to aim at.
      final moves = <({int id, int? before, int? parent})>[];
      await open(
        tester,
        [
          sectionOf([album('One', id: 1), album('Two', id: 2)]),
        ],
        onMove: (id, before, parent) =>
            moves.add((id: id, before: before, parent: parent)),
      );

      final start = tester.getCenter(find.text('One'));
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveTo(start + const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 100));

      final end = tester.getCenter(find.byType(HomeDropEnd));
      await gesture.moveTo(end);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(moves.single.id, 1);
      expect(moves.single.before, isNull, reason: 'last means no anchor');
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
              queryType: HomeQueryType.track,
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

    testWidgets('dragging a search block turns on edge scrolling',
        (tester) async {
      // It announces itself like every other draggable now. It did not, and
      // that one omission is why a search block had no trailing slot to aim
      // past, no gaps between sections, and no scrolling when held at an
      // edge -- three symptoms with one cause.
      await open(tester, [
        sectionOf([mixed()]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      DragScroll scroller() => tester.widget<DragScroll>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(DragScroll),
                )
                .first,
          );
      expect(find.byType(DragScroll), findsWidgets);

      final start = tester.getCenter(find.text('Songs where tag:hardcore'));
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.moveTo(start + const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 100));

      final active = tester
          .widgetList<DragScroll>(find.byType(DragScroll))
          .any((one) => one.active);

      await gesture.up();
      await tester.pumpAndSettle();

      expect(active, isTrue);
      expect(scroller, isNotNull);
    });

    testWidgets('a search sits where it was put, not always first',
        (tester) async {
      // The whole point of making it a block: its position among the
      // hand-picked items is its own, and the grid follows the children.
      await open(tester, [
        sectionOf([mixed()]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      final a = tester.getTopLeft(find.text('Hand-picked A')).dy;
      final rule = tester.getTopLeft(find.text('Songs where tag:hardcore')).dy;
      final b = tester.getTopLeft(find.text('Hand-picked B')).dy;

      expect(a, lessThan(rule), reason: 'A was placed before it');
      expect(rule, lessThan(b), reason: 'B after it');
    });

    testWidgets('its header can be picked up to move the whole block',
        (tester) async {
      await open(tester, [
        sectionOf([mixed()]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      expect(
        find.ancestor(
          of: find.text('Songs where tag:hardcore'),
          matching: find.byType(LongPressDraggable<HomeDrag>),
        ),
        findsOneWidget,
      );
    });

    testWidgets('right-clicking the header offers what a rule can have done',
        (tester) async {
      await open(tester, [
        sectionOf([mixed()]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      await tester.tapAt(
        tester.getCenter(find.text('Songs where tag:hardcore')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit the search'), findsOneWidget);
      expect(find.text('Remove the search'), findsOneWidget);
    });

    testWidgets('what a search found is not itself draggable', (tester) async {
      // Those are not rows anybody placed; moving one would be undone the
      // next time the rule ran.
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

      expect(
        find.ancestor(
          of: find.text('Found by search'),
          matching: find.byType(HomeDraggable),
        ),
        findsNothing,
      );
      // The hand-picked ones beside it still are.
      expect(
        find.ancestor(
          of: find.text('Hand-picked A'),
          matching: find.byType(HomeDraggable),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a title of its own replaces the rule in the heading',
        (tester) async {
      // Optional, and when it is there it is what the block is called --
      // the rule moves to the second line rather than being said twice.
      await open(tester, [
        sectionOf([
          collectionItem(
            'Mixed',
            const [
              HomeItemView(
                id: 2,
                kind: HomeItemKind.query,
                title: 'Loud things',
                label: 'Loud things',
                query: 'tag:hardcore',
                queryType: HomeQueryType.track,
              ),
            ],
            id: 9,
          ),
        ]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      expect(find.text('Loud things'), findsOneWidget);
      expect(find.text('Songs where tag:hardcore'), findsNothing);
    });

    testWidgets('no hint is shown on hover any more', (tester) async {
      await open(tester, [
        sectionOf([mixed()]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      expect(find.textContaining('hold to move'), findsNothing);
    });

    testWidgets('clicking the heading rolls the block up', (tester) async {
      var collapsed = false;
      await open(
        tester,
        [
          sectionOf([mixed()]),
        ],
        onCollapseItem: (_, to) => collapsed = to,
      );
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Songs where tag:hardcore'));
      await tester.pumpAndSettle();

      expect(collapsed, isTrue);
    });

    testWidgets('a rolled-up block shows its heading and nothing else',
        (tester) async {
      await open(tester, [
        sectionOf([
          collectionItem(
            'Mixed',
            const [
              HomeItemView(
                id: 2,
                kind: HomeItemKind.query,
                title: 'Loud things',
                label: 'Loud things',
                query: 'tag:hardcore',
                queryType: HomeQueryType.track,
                collapsed: true,
              ),
            ],
            id: 9,
          ),
        ]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      expect(find.text('Loud things'), findsOneWidget);
      expect(find.text('Nothing matches it right now.'), findsNothing);
    });

    testWidgets('a search in the first slot can be moved past the run below it',
        (tester) async {
      final moves = <({int id, int? before, int? parent})>[];
      await open(
        tester,
        [
          sectionOf([
            collectionItem(
              'Mixed',
              [
                const HomeItemView(
                  id: 2,
                  kind: HomeItemKind.query,
                  title: 'Loud',
                  label: 'Loud',
                  query: 'tag:hardcore',
                  queryType: HomeQueryType.track,
                ),
                album('First', id: 1),
                album('Second', id: 3),
              ],
              id: 9,
            ),
          ]),
        ],
        onMove: (id, before, parent) =>
            moves.add((id: id, before: before, parent: parent)),
      );
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      // Pick the search up by its heading.
      final start = tester.getCenter(find.text('Loud'));
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.moveTo(start + const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 100));

      final slot = find.descendant(
        of: find.ancestor(
          of: find.text('First'),
          matching: find.byType(GridView),
        ),
        matching: find.byType(HomeDropEnd),
      );
      expect(slot, findsOneWidget, reason: 'the run offers an end slot');

      await gesture.moveTo(tester.getCenter(slot));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(moves, hasLength(1), reason: 'the drop landed');
      expect(moves.single.id, 2);
      expect(moves.single.before, isNull, reason: 'past everything below it');
    });

    testWidgets('a collection has a slot after its last hand-picked item',
        (tester) async {
      // The run of picked items inside a collection had no trailing target
      // at all once the panel became a list of blocks.
      final moves = <({int id, int? before, int? parent})>[];
      await open(
        tester,
        [
          sectionOf([
            collectionItem(
              'Mixed',
              [album('First', id: 1), album('Second', id: 2)],
              id: 9,
            ),
          ]),
        ],
        onMove: (id, before, parent) =>
            moves.add((id: id, before: before, parent: parent)),
      );
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      final start = tester.getCenter(find.text('First'));
      final gesture = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveTo(start + const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 100));

      // Scoped to the grid the dragged tile is in: the page behind the
      // dialog has end slots of its own, and the first one in tree order is
      // one of those -- behind the barrier, where no drop can land.
      final slot = find.descendant(
        of: find.ancestor(
          of: find.text('First'),
          matching: find.byType(GridView),
        ),
        matching: find.byType(HomeDropEnd),
      );
      expect(slot, findsOneWidget);
      await gesture.moveTo(tester.getCenter(slot));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(moves, hasLength(1));
      expect(moves.single.id, 1);
      expect(moves.single.parent, 9, reason: 'still inside the collection');
      expect(moves.single.before, isNull, reason: 'last means no anchor');
    });

    testWidgets('the rule heads its own block, in place', (tester) async {
      // A block with a title saying where its contents came from, sitting
      // where it sits among the hand-picked ones -- not a chip in the header
      // describing something spliced invisibly into a flat grid.
      await open(tester, [
        sectionOf([mixed()]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      expect(find.text('Songs where tag:hardcore'), findsOneWidget);
      expect(find.byType(InputChip), findsNothing);
    });
  });

  group('the fields a search is built from', () {
    /// Mounts the three fields on their own, which is what both the add
    /// dialog and the rule editor put on screen.
    Future<void> mount(
      WidgetTester tester, {
      HomeQueryType type = HomeQueryType.album,
      HomeQuerySort sort = HomeQuerySort.matched,
      bool inverted = false,
      required void Function(HomeQueryType) onType,
      required void Function(HomeQuerySort) onSort,
      void Function(bool)? onInverted,
    }) async {
      await tester.binding.setSurfaceSize(const Size(700, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = TextEditingController();
      final titleController = TextEditingController();
      addTearDown(controller.dispose);
      addTearDown(titleController.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            artStoreProvider.overrideWithValue(ArtStore(artRoot)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: QueryFields(
                controller: controller,
                titleController: titleController,
                type: type,
                sort: sort,
                onTypeChanged: onType,
                onSortChanged: onSort,
                inverted: inverted,
                onInvertedChanged: onInverted ?? (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('all three are there, labelled', (tester) async {
      await mount(tester, onType: (_) {}, onSort: (_) {});

      expect(find.text('Find'), findsWidgets);
      expect(find.text('Sorted by'), findsWidgets);
      // The query field itself.
      expect(find.byType(SmartQueryField), findsOneWidget);
    });

    testWidgets('they are the Material 3 menus, not the old buttons',
        (tester) async {
      await mount(tester, onType: (_) {}, onSort: (_) {});

      expect(find.byType(DropdownMenu<HomeQueryType>), findsOneWidget);
      expect(find.byType(DropdownMenu<HomeQuerySort>), findsOneWidget);
      expect(find.byType(DropdownButton), findsNothing);
    });

    testWidgets('the sort options follow the type', (tester) async {
      // Albums have a release year to be ordered by.
      await mount(tester, onType: (_) {}, onSort: (_) {});
      await tester.tap(find.byType(DropdownMenu<HomeQuerySort>));
      await tester.pumpAndSettle();
      expect(find.text('Release year'), findsWidgets);

      // Artists do not.
      await mount(
        tester,
        type: HomeQueryType.artist,
        onType: (_) {},
        onSort: (_) {},
      );
      await tester.tap(find.byType(DropdownMenu<HomeQuerySort>));
      await tester.pumpAndSettle();
      expect(find.text('Release year'), findsNothing);
      expect(find.text('Number of songs'), findsWidgets);
    });

    testWidgets('changing the type drops a sort it could not obey',
        (tester) async {
      // Keeping it would mean storing an order that is silently ignored.
      HomeQuerySort? reset;
      await mount(
        tester,
        sort: HomeQuerySort.releaseYear,
        onType: (_) {},
        onSort: (sort) => reset = sort,
      );

      await tester.tap(find.byType(DropdownMenu<HomeQueryType>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Artists').last);
      await tester.pumpAndSettle();

      expect(reset, HomeQuerySort.matched);
    });

    testWidgets('a sort the new type can still obey is left alone',
        (tester) async {
      HomeQuerySort? reset;
      await mount(
        tester,
        sort: HomeQuerySort.name,
        onType: (_) {},
        onSort: (sort) => reset = sort,
      );

      await tester.tap(find.byType(DropdownMenu<HomeQueryType>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Artists').last);
      await tester.pumpAndSettle();

      expect(reset, isNull, reason: 'name works for artists too');
    });

    testWidgets('the order can be turned around from beside it',
        (tester) async {
      bool? flipped;
      await mount(
        tester,
        sort: HomeQuerySort.releaseYear,
        onType: (_) {},
        onSort: (_) {},
        onInverted: (value) => flipped = value,
      );

      // Beside the field, not inside the menu: the whole point is that the
      // menu does not carry a second entry for every order.
      await tester.tap(find.byIcon(Icons.swap_vert));
      await tester.pumpAndSettle();

      expect(flipped, isTrue);
    });

    testWidgets('and turned back again', (tester) async {
      bool? flipped;
      await mount(
        tester,
        sort: HomeQuerySort.releaseYear,
        inverted: true,
        onType: (_) {},
        onSort: (_) {},
        onInverted: (value) => flipped = value,
      );

      await tester.tap(find.byIcon(Icons.swap_vert));
      await tester.pumpAndSettle();

      expect(flipped, isFalse);
    });

    testWidgets('the menu offers one Name, not two', (tester) async {
      // What the button replaced: a Z-to-A entry beside the A-to-Z one, and
      // a matching pair for every other order anybody ever asked for.
      await mount(tester, onType: (_) {}, onSort: (_) {});
      await tester.tap(find.byType(DropdownMenu<HomeQuerySort>));
      await tester.pumpAndSettle();

      expect(find.text('Name (Z–A)'), findsNothing);
      expect(find.text('Name'), findsWidgets);
    });

    testWidgets('the button sits on the field, not above or below it',
        (tester) async {
      // It is in a Row with a form field, which is the arrangement most
      // likely to come out a few pixels off and stay that way.
      await mount(tester, onType: (_) {}, onSort: (_) {});

      final field = tester.getRect(find.byType(DropdownMenu<HomeQuerySort>));
      final button = tester.getRect(
        find.ancestor(
          of: find.byIcon(Icons.swap_vert),
          matching: find.byType(IconButton),
        ),
      );

      expect(button.center.dy, closeTo(field.center.dy, 1));
      expect(button.left, greaterThan(field.right));
    });

    testWidgets('a shuffle reports that it has no reverse', (tester) async {
      // Left pressable rather than disabled on purpose: a button that
      // switches between enabled and disabled as the menu beside it changes
      // is what the Windows accessibility bridge mishandles.
      await mount(
        tester,
        sort: HomeQuerySort.random,
        onType: (_) {},
        onSort: (_) {},
      );

      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.swap_vert),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNotNull);
      expect(
        tester.widget<Tooltip>(
          find.ancestor(
            of: find.byIcon(Icons.swap_vert),
            matching: find.byType(Tooltip),
          ),
        ).message,
        'A shuffle has no reverse',
      );
    });
  });

  testWidgets('an artist tile is the same size as its neighbours',
      (tester) async {
    // The report this covers: with no second line of text, an artist's tile
    // was handed the spare height and came out bigger and oval beside the
    // albums next to it.
    await open(tester, [
      sectionOf([
        HomeItemView(
          id: 1,
          kind: HomeItemKind.album,
          title: 'An album',
          subtitle: 'With an artist line',
          refId: 1,
        ),
        const HomeItemView(
          id: 2,
          kind: HomeItemKind.artist,
          title: 'A person',
          refId: 2,
        ),
      ]),
    ]);

    Size artworkOf(String title) => tester.getSize(
          find.descendant(
            of: find.ancestor(
              of: find.text(title),
              matching: find.byType(HomeTile),
            ),
            matching: find.byType(HomeArtwork),
          ),
        );

    final album = artworkOf('An album');
    final person = artworkOf('A person');

    expect(person.width, album.width);
    expect(person.height, album.height, reason: 'no spare height to absorb');
    expect(person.width, person.height, reason: 'square, so a circle is round');
  });

  testWidgets('a mosaic draws an artist cell round and an album cell square',
      (tester) async {
    // The library's vocabulary holds inside a quartered tile too: round
    // means a person everywhere, and this would be the one place it did not.
    await open(tester, [
      sectionOf([
        collectionItem(
          'Mixed',
          const [
            HomeItemView(
              id: 10,
              kind: HomeItemKind.album,
              title: 'An album',
              imagePath: 'a.jpg',
            ),
            HomeItemView(
              id: 11,
              kind: HomeItemKind.artist,
              title: 'A person',
              imagePath: 'b.jpg',
            ),
          ],
          id: 9,
        ),
      ]),
    ]);

    final cells = tester
        .widgetList<Artwork>(find.byType(Artwork))
        .where((art) => art.storedPath == 'a.jpg' || art.storedPath == 'b.jpg')
        .toList();

    expect(cells, hasLength(2));
    expect(cells.firstWhere((a) => a.storedPath == 'a.jpg').borderRadius, 0);
    expect(cells.firstWhere((a) => a.storedPath == 'b.jpg').borderRadius, 999);
  });

  group('opening something from inside a collection', () {
    /// Unmounts deliberately. A detail view watches live drift queries, and
    /// drift posts a zero-duration cleanup timer when one is cancelled -- a
    /// scope torn down by the binding afterwards fails the test with "a
    /// Timer is still pending", which presents as the whole file hanging.
    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      // Zero does not work: the cleanup timer needs a tick to fire.
      await tester.pump(const Duration(milliseconds: 1));
    }

    /// A collection holding one album and one artist.
    HomeItemView mixedTargets() => collectionItem(
          'Mixed',
          [
            album('Antenna', id: 1),
            // Not the album fixture's own artist line, which would make
            // the finder ambiguous rather than the test wrong.
            const HomeItemView(
              id: 2,
              kind: HomeItemKind.artist,
              title: 'Camellia',
              refId: 2,
            ),
          ],
          id: 9,
        );

    testWidgets('an album opens on top, leaving the collection open',
        (tester) async {
      // The report this covers: it used to land in the page behind, under
      // the collection that was still open, so seeing it meant closing the
      // thing you clicked it from.
      var openedInPage = 0;
      await open(
        tester,
        [
          sectionOf([mixedTargets()]),
        ],
        onOpenAlbum: (_) => openedInPage++,
      );
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Antenna'));
      await tester.pumpAndSettle();

      expect(openedInPage, 0, reason: 'not pushed into the page behind');
      expect(find.byType(AlbumDetailView), findsOneWidget);
      // And the collection it came from is still there underneath.
      expect(find.text('Mixed'), findsWidgets);

      await unmount(tester);
    });

    testWidgets('an artist does the same', (tester) async {
      var openedInPage = 0;
      await open(
        tester,
        [
          sectionOf([mixedTargets()]),
        ],
        onOpenArtist: (_) => openedInPage++,
      );
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Camellia'));
      await tester.pumpAndSettle();

      expect(openedInPage, 0);
      expect(find.byType(ArtistDetailView), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('closing it goes back to the collection, not to the page',
        (tester) async {
      await open(tester, [
        sectionOf([mixedTargets()]),
      ]);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Antenna'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close').first);
      await tester.pumpAndSettle();

      expect(find.byType(AlbumDetailView), findsNothing);
      // Still inside the collection, which is the whole point.
      expect(find.text('Play all'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a tile on the page itself still opens the full page',
        (tester) async {
      // Unchanged on purpose: that is where editing and the caption strip
      // live, and nothing is covering it.
      var opened = 0;
      await open(
        tester,
        [
          sectionOf([album('Antenna', id: 1)]),
        ],
        onOpenAlbum: (_) => opened++,
      );

      await tester.tap(find.text('Antenna'));
      await tester.pumpAndSettle();

      expect(opened, 1);
      expect(find.byType(AlbumDetailView), findsNothing);
    });
  });

  group('a collection picture', () {
    testWidgets('only a collection is offered one', (tester) async {
      // Everything else shows what the library already has for it, and
      // overriding that here would be editing the album from the wrong place.
      await open(tester, [
        sectionOf([
          album('Antenna', id: 1),
          collectionItem('Box', const [], id: 9),
        ]),
      ]);

      await tester.tapAt(
        tester.getCenter(find.text('Antenna')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Change picture'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tapAt(
        tester.getCenter(find.text('Box')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('Change picture'), findsOneWidget);
    });

    testWidgets('it opens on the quadrant, with four quarters to aim at',
        (tester) async {
      await open(tester, [
        sectionOf([collectionItem('Box', const [], id: 9)]),
      ]);
      await tester.tapAt(
        tester.getCenter(find.text('Box')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change picture'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Picture for'), findsOneWidget);
      // The mode lives in the title row, because it decides what the rest of
      // the dialog is asking.
      expect(find.text('Quadrant'), findsOneWidget);
      expect(find.text('Picture'), findsOneWidget);
      expect(find.byTooltip('Whatever comes next'), findsNWidgets(4));
    });

    testWidgets('clicking a quarter offers what is inside, searches included',
        (tester) async {
      // A collection whose contents are a rule still has pictures in it --
      // they just have to be asked for first.
      final albumId = await db.into(db.albums).insert(
            AlbumsCompanion.insert(title: 'Found', nameKey: 'found'),
          );
      final imageId = await db.into(db.images).insert(
            ImagesCompanion.insert(
              sha256: 'abc',
              storedPath: 'ab/abc.jpg',
              mimeType: 'image/jpeg',
              byteSize: 10,
              kind: ImageKind.userProvided,
            ),
          );
      await (db.update(db.albums)..where((a) => a.id.equals(albumId)))
          .write(AlbumsCompanion(imageId: Value(imageId)));
      final trackId = await db.into(db.tracks).insert(
            TracksCompanion.insert(
              title: 'A song',
              nameKey: 'a song',
              albumId: Value(albumId),
            ),
          );
      final tagId = await db
          .into(db.tags)
          .insert(TagsCompanion.insert(name: 'hardcore', nameKey: 'hardcore'));
      await db.into(db.trackTags).insert(
            TrackTagsCompanion.insert(trackId: trackId, tagId: tagId),
          );

      await open(tester, [
        sectionOf([
          collectionItem(
            'Rules only',
            const [
              HomeItemView(
                id: 2,
                kind: HomeItemKind.query,
                title: 'Hardcore',
                query: 'tag:hardcore',
              ),
            ],
            id: 9,
          ),
        ]),
      ]);

      await tester.tapAt(
        tester.getCenter(find.text('Rules only')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change picture'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Whatever comes next').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('first quarter'), findsOneWidget);
      expect(find.byTooltip('Found'), findsOneWidget);
    });

    testWidgets('switching to Picture offers one whole image instead',
        (tester) async {
      await open(tester, [
        sectionOf([collectionItem('Box', const [], id: 9)]),
      ]);
      await tester.tapAt(
        tester.getCenter(find.text('Box')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change picture'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Picture'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Whatever comes next'), findsNothing);
      expect(find.text('Change it'), findsOneWidget);
    });

    testWidgets('a quarter with nothing to offer cannot be clicked',
        (tester) async {
      // Rather than opening a chooser with an empty grid in it.
      await open(tester, [
        sectionOf([collectionItem('Empty', const [], id: 9)]),
      ]);
      await tester.tapAt(
        tester.getCenter(find.text('Empty')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change picture'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Whatever comes next').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('first quarter'), findsNothing);
      // Choosing a file is still the way out, from the whole-picture side.
      expect(find.text('Picture'), findsOneWidget);
    });

    testWidgets('the picture currently in use wears a check', (tester) async {
      // Opening the chooser should say what the answer is now, not only
      // offer to change it.
      final albumId = await db.into(db.albums).insert(
            AlbumsCompanion.insert(title: 'Cover', nameKey: 'cover'),
          );
      final imageId = await db.into(db.images).insert(
            ImagesCompanion.insert(
              sha256: 'abc',
              storedPath: 'ab/abc.jpg',
              mimeType: 'image/jpeg',
              byteSize: 10,
              kind: ImageKind.userProvided,
            ),
          );
      await (db.update(db.albums)..where((a) => a.id.equals(albumId)))
          .write(AlbumsCompanion(imageId: Value(imageId)));

      await open(tester, [
        sectionOf([
          collectionItem(
            'Box',
            [
              const HomeItemView(
                id: 10,
                kind: HomeItemKind.album,
                title: 'Cover',
                imagePath: 'ab/abc.jpg',
              ),
            ],
            id: 9,
          ),
        ]),
      ]);

      await tester.tapAt(
        tester.getCenter(find.text('Box')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change picture'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Picture'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change it'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Cover'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing,
          reason: 'nothing chosen yet, so nothing is checked');
    });
  });

  group('a collection open on screen follows the database', () {
    /// This group deliberately does *not* fake [homeProvider]: what is being
    /// checked is that the panel re-reads the page, which a fixed stream
    /// cannot show. That means a live drift query, so each test unmounts
    /// deliberately at the end -- drift posts a zero-duration cleanup timer
    /// when a query stream is cancelled, and a scope torn down by the binding
    /// afterwards fails the test with "a Timer is still pending".
    Future<void> openLive(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            artStoreProvider.overrideWithValue(ArtStore(artRoot)),
            playbackEngineProvider.overrideWithValue(SilentEngine()),
            playerProvider.overrideWith(() => IdlePlayer(db)),
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

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      // Zero does not work: the cleanup timer needs a tick to fire.
      await tester.pump(const Duration(milliseconds: 1));
    }

    /// A section holding one empty collection, and a track a search can find.
    Future<int> seed() async {
      await db.delete(db.homeSections).go();
      final repository = HomeRepository(db);
      final sectionId = await repository.addSection(title: 'Mine');
      final collectionId = await repository.addItem(
        sectionId: sectionId,
        kind: HomeItemKind.collection,
        label: 'Mixed',
      );

      final trackId = await db.into(db.tracks).insert(
            TracksCompanion.insert(title: 'Found by search', nameKey: 'found'),
          );
      final tagId = await db
          .into(db.tags)
          .insert(TagsCompanion.insert(name: 'hardcore', nameKey: 'hardcore'));
      await db.into(db.trackTags).insert(
            TrackTagsCompanion.insert(trackId: trackId, tagId: tagId),
          );
      return collectionId;
    }

    testWidgets('a search added while it is open shows its results at once',
        (tester) async {
      // The bug this covers: the panel held the collection it was handed when
      // it opened, and a dialog route is never rebuilt by the page behind it
      // -- so a rule added from in here was written and never shown.
      final collectionId = await seed();
      await openLive(tester);

      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();
      expect(find.text('Found by search'), findsNothing);

      await HomeRepository(db).addItem(
        sectionId: (await HomeRepository(db).watchHome().first).single.id,
        parentId: collectionId,
        kind: HomeItemKind.query,
        query: 'tag:hardcore',
        queryType: HomeQueryType.track,
      );
      await tester.pumpAndSettle();

      expect(find.text('Found by search'), findsOneWidget);
      expect(find.text('Songs where tag:hardcore'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('removing the rule takes its results with it', (tester) async {
      final collectionId = await seed();
      final repository = HomeRepository(db);
      final sectionId = (await repository.watchHome().first).single.id;
      final searchId = await repository.addItem(
        sectionId: sectionId,
        parentId: collectionId,
        kind: HomeItemKind.query,
        query: 'tag:hardcore',
        queryType: HomeQueryType.track,
      );

      await openLive(tester);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();
      expect(find.text('Found by search'), findsOneWidget);

      await repository.removeItem(searchId);
      await tester.pumpAndSettle();

      expect(find.text('Found by search'), findsNothing);
      expect(find.text('Songs where tag:hardcore'), findsNothing);

      await unmount(tester);
    });

    testWidgets('a search can be dragged above the items placed before it',
        (tester) async {
      // Reordering a block is an ordinary reorder of the children, so this
      // goes through the same move the rest of the page uses.
      final collectionId = await seed();
      final repository = HomeRepository(db);
      final sectionId = (await repository.watchHome().first).single.id;
      final albumId = await db.into(db.albums).insert(
            AlbumsCompanion.insert(title: 'Picked', nameKey: 'picked'),
          );
      final pickedId = await repository.addItem(
        sectionId: sectionId,
        parentId: collectionId,
        kind: HomeItemKind.album,
        refId: albumId,
      );
      final searchId = await repository.addItem(
        sectionId: sectionId,
        parentId: collectionId,
        kind: HomeItemKind.query,
        query: 'tag:hardcore',
        queryType: HomeQueryType.track,
      );

      await openLive(tester);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      // The album was added first, so it is above the rule to begin with.
      expect(
        tester.getTopLeft(find.text('Picked')).dy,
        lessThan(tester.getTopLeft(find.text('Songs where tag:hardcore')).dy),
      );

      await repository.moveItem(
        searchId,
        sectionId: sectionId,
        newParentId: collectionId,
        beforeId: pickedId,
      );
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.text('Songs where tag:hardcore')).dy,
        lessThan(tester.getTopLeft(find.text('Picked')).dy),
        reason: 'the block moved with its rule',
      );

      await unmount(tester);
    });

    testWidgets('an ordinary item added while it is open shows up too',
        (tester) async {
      // Not only searches: the panel was equally frozen for anything else
      // dropped or added into it.
      final collectionId = await seed();
      await openLive(tester);

      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();

      final repository = HomeRepository(db);
      final albumId = await db.into(db.albums).insert(
            AlbumsCompanion.insert(title: 'Antenna', nameKey: 'antenna'),
          );
      await repository.addItem(
        sectionId: (await repository.watchHome().first).single.id,
        parentId: collectionId,
        kind: HomeItemKind.album,
        refId: albumId,
      );
      await tester.pumpAndSettle();

      expect(find.text('Antenna'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('rewriting a rule re-runs it rather than keeping what it found',
        (tester) async {
      final collectionId = await seed();
      final repository = HomeRepository(db);
      final sectionId = (await repository.watchHome().first).single.id;
      final searchId = await repository.addItem(
        sectionId: sectionId,
        parentId: collectionId,
        kind: HomeItemKind.query,
        query: 'tag:hardcore',
        queryType: HomeQueryType.track,
      );

      await openLive(tester);
      await tester.tap(find.text('Mixed'));
      await tester.pumpAndSettle();
      expect(find.text('Found by search'), findsOneWidget);

      await repository.setItemQuery(searchId, 'tag:nothing-matches-this');
      await tester.pumpAndSettle();

      expect(find.text('Found by search'), findsNothing);

      await unmount(tester);
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
  _RecordingHome(
    super.db,
    this.onMove,
    this.onCombine,
    this.onCollapse,
    this.onCollapseItem,
  );

  final void Function(int id, int? beforeId, int? parentId)? onMove;
  final void Function(int targetId)? onCombine;
  final void Function(bool collapsed)? onCollapse;
  final void Function(int itemId, bool collapsed)? onCollapseItem;

  @override
  Future<void> setItemCollapsed(int itemId, bool collapsed) async =>
      onCollapseItem?.call(itemId, collapsed);

  @override
  Future<void> setSectionCollapsed(int sectionId, bool collapsed) async =>
      onCollapse?.call(collapsed);

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
