import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/features/tags/tag_detail_view.dart';
import 'package:marmelade/widgets/track_list.dart';
import 'package:marmelade/widgets/title_with_actions.dart';

import '../support/silent_player.dart';

/// A tag's own page can change the tag.
///
/// Everything else with a page of its own -- an artist, an album -- can be
/// edited from it, and having to go back to the list to rename the thing you
/// are looking at is the sort of gap that makes a page feel read-only.
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  const tag = TagCard(
    id: 10,
    name: 'Hardcore',
    trackCount: 2,
    categoryId: 1,
    categoryName: 'Genre',
  );

  Future<void> pump(
    WidgetTester tester, {
    List<ArtistCard> artists = const [],
    List<AlbumCard> albums = const [],
    List<TrackRow> tracks = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playbackEngineProvider.overrideWithValue(SilentEngine()),
          playerProvider.overrideWith(() => IdlePlayer(db)),
          taggedProvider.overrideWith((ref) => Stream.value(const [tag])),
          tagCategoriesProvider.overrideWith((ref) => Stream.value(const [])),
          tagTrackListProvider(10).overrideWith((ref) => Stream.value(tracks)),
          // Faked rather than left live for the same reason the database is:
          // drift posts a zero-duration cleanup timer when a query stream is
          // cancelled, and a widget test tears the scope down after the last
          // pump, so the binding sees a timer pending after the tree is gone.
          tagArtistsProvider(10).overrideWith((ref) => Stream.value(artists)),
          tagAlbumsProvider(10).overrideWith((ref) => Stream.value(albums)),
        ],
        child: MaterialApp(
          home: Scaffold(
            // The edit/delete controls now live in TagDetailChrome, the
            // window title bar's content in the real app (see AppShell) --
            // stood up alongside the page here rather than inside it.
            body: Column(
              children: [
                const TagDetailChrome(tagId: 10, onBack: _noop),
                Expanded(
                  child: TagDetailView(tagId: 10, onBack: _noop),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the page offers to edit the tag', (tester) async {
    await pump(tester);

    expect(find.byTooltip('Edit this tag'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the edit button opens the rename dialog', (tester) async {
    await pump(tester);

    await tester.tap(find.byTooltip('Edit this tag'));
    await tester.pumpAndSettle();

    // The dialog is the same one the tag list uses, so it renames and moves
    // category in one place.
    expect(find.text('Hardcore'), findsWidgets);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('deleting is offered, behind a confirmation', (tester) async {
    await pump(tester);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Hardcore?'), findsOneWidget);
  });

  testWidgets('names the artists wearing the tag, above the songs',
      (tester) async {
    // A tag on a person is a statement about them, not about one recording,
    // so the page that says what this tag means has to say who wears it --
    // otherwise the only trace is several hundred tracks appearing below for
    // no visible reason.
    await pump(tester, artists: const [
      ArtistCard(
        id: 4,
        name: 'Camellia',
        kind: 'person',
        trackCount: 12,
        albumCount: 3,
      ),
    ]);

    expect(find.text('1 artist with this tag'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Camellia'), findsOneWidget);
  });

  testWidgets('says nothing about artists when none wear it', (tester) async {
    await pump(tester);

    expect(find.textContaining('with this tag'), findsNothing);
  });


  /// A track on an album, or a single when [albumId] is null.
  TrackRow track(int id, {int? albumId, String? albumTitle}) => TrackRow(
        id: id,
        title: 'Track $id',
        credits: const [],
        durationMs: 200000,
        albumId: albumId,
        albumTitle: albumTitle,
      );

  const album = AlbumCard(
    id: 3,
    title: 'Comic and Cosmic',
    artistName: 'Camellia',
    artistId: 2,
    trackCount: 4,
    imagePath: null,
  );

  group('what the tag reaches', () {
    testWidgets('lists the albums above the songs', (tester) async {
      // A list of ninety songs is a poor way to see that most of them come
      // from four records.
      await pump(
        tester,
        albums: const [album],
        tracks: [track(1, albumId: 3, albumTitle: album.title)],
      );

      expect(find.text('Comic and Cosmic'), findsWidgets);
      expect(find.text('1 album'), findsOne);
    });

    testWidgets('accounts for the leftovers as singles', (tester) async {
      // Without it, a row of one album over a list of three tracks looks
      // like a bug rather than an album plus two singles.
      await pump(
        tester,
        albums: const [album],
        tracks: [
          track(1, albumId: 3, albumTitle: album.title),
          track(2),
          track(3),
        ],
      );

      expect(find.text('Singles'), findsOne);
      expect(find.text('1 album and 2 singles'), findsOne);
    });

    testWidgets('and says nothing about singles when there are none',
        (tester) async {
      await pump(
        tester,
        albums: const [album],
        tracks: [track(1, albumId: 3, albumTitle: album.title)],
      );

      expect(find.text('Singles'), findsNothing);
    });

    testWidgets('offers editing beside the name, not in the strip',
        (tester) async {
      await pump(tester);

      expect(
        find.descendant(
          of: find.byType(TitleWithActions),
          matching: find.byTooltip('Edit this tag'),
        ),
        findsOne,
      );
      expect(
        find.descendant(
          of: find.byType(TagDetailChrome),
          matching: find.byTooltip('Edit this tag'),
        ),
        findsNothing,
        reason: 'while the header is on screen',
      );
    });
  });

  group('the collapsing header', () {
    testWidgets('hands the name and the controls to the strip on the way down',
        (tester) async {
      // The experiment: the things worth reaching stay reachable the whole
      // way down a long tag, rather than only at the top of it.
      await pump(
        tester,
        tracks: [for (var i = 1; i <= 40; i++) track(i)],
      );

      expect(
        find.descendant(
          of: find.byType(TagDetailChrome),
          matching: find.text('Hardcore'),
        ),
        findsNothing,
        reason: 'the header still has it',
      );

      await tester.drag(find.byType(TrackList), const Offset(0, -400));
      await tester.pumpAndSettle();

      final inStrip = find.descendant(
        of: find.byType(TagDetailChrome),
        matching: find.text('Hardcore'),
      );
      expect(inStrip, findsOne);
      expect(
        find.descendant(
          of: find.byType(TagDetailChrome),
          matching: find.byTooltip('Play'),
        ),
        findsOne,
      );
      expect(
        find.descendant(
          of: find.byType(TagDetailChrome),
          matching: find.byTooltip('Shuffle'),
        ),
        findsOne,
      );
    });

    testWidgets('and takes them back on the way up', (tester) async {
      await pump(
        tester,
        tracks: [for (var i = 1; i <= 40; i++) track(i)],
      );
      await tester.drag(find.byType(TrackList), const Offset(0, -400));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(TrackList), const Offset(0, 400));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(TagDetailChrome),
          matching: find.text('Hardcore'),
        ),
        findsNothing,
      );
    });
  });

}

void _noop() {}
