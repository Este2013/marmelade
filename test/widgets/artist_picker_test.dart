import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/features/edit/edit_widgets.dart';
import 'package:marmelade/services/art/art_store.dart';

import 'dart:io';

/// The artist picker, opened with something already to offer.
///
/// Asking "who is this release by" with a blank field is asking a question
/// the library can mostly answer itself: the album artist is nearly always
/// somebody already credited on the tracks. Typing still wins once a query
/// is there -- that is the question being asked at that point.
void main() {
  late MarmeladeDatabase db;
  late Directory artRoot;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    artRoot = Directory.systemTemp.createTempSync('marmelade_picker_art_');
    // One artist to find by typing, so searching can be told apart from
    // suggesting.
    await db.into(db.artists).insert(
          ArtistsCompanion.insert(name: 'Searchable', nameKey: 'searchable'),
        );
  });
  tearDown(() async {
    await db.close();
    if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
  });

  const suggestions = <ArtistSuggestion>[
    (
      artist: (
        id: 1,
        name: 'PinocchioP',
        kind: ArtistKind.person,
        trackCount: 40,
      ),
      appearances: 3,
    ),
    (
      artist: (
        id: 2,
        name: 'Hatsune Miku',
        kind: ArtistKind.person,
        trackCount: 900,
      ),
      appearances: 1,
    ),
  ];

  /// Opens the picker, leaving it on screen. [onPicked] catches what it
  /// returns, for the one test that cares.
  Future<void> open(
    WidgetTester tester, {
    Future<List<ArtistSuggestion>> Function()? offer,
    void Function(PickedArtist?)? onPicked,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          artStoreProvider.overrideWithValue(ArtStore(artRoot)),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  // Awaited into a local first: `onPicked?.call(await ...)`
                  // short-circuits the whole expression when onPicked is
                  // null, so the dialog would never open at all.
                  onPressed: () async {
                    final picked = await pickArtist(
                      context,
                      ref,
                      title: 'Album artist for Antenna',
                      suggestions: offer,
                    );
                    onPicked?.call(picked);
                  },
                  child: const Text('Choose'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
  }

  testWidgets('offers the release\'s own artists before a key is pressed',
      (tester) async {
    await open(tester, offer: () async => suggestions);

    expect(find.text('Already on this release'), findsOneWidget);
    expect(find.text('PinocchioP'), findsOneWidget);
    expect(find.text('Hatsune Miku'), findsOneWidget);
    expect(find.text('Start typing to find an artist.'), findsNothing);
  });

  testWidgets('says how much of the release each one is on', (tester) async {
    // What separates the act whose record it is from a guest on one song.
    await open(tester, offer: () async => suggestions);

    expect(find.text('on 3 tracks of this release'), findsOneWidget);
    expect(find.text('on 1 track of this release'), findsOneWidget);
  });

  testWidgets('keeps the order it was given, which is by how often they appear',
      (tester) async {
    await open(tester, offer: () async => suggestions);

    final first = tester.getTopLeft(find.text('PinocchioP')).dy;
    final second = tester.getTopLeft(find.text('Hatsune Miku')).dy;
    expect(first, lessThan(second));
  });

  testWidgets('picking a suggestion returns it', (tester) async {
    PickedArtist? picked;
    await open(
      tester,
      offer: () async => suggestions,
      onPicked: (artist) => picked = artist,
    );

    await tester.tap(find.text('PinocchioP'));
    await tester.pumpAndSettle();

    expect(picked?.name, 'PinocchioP');
    expect(picked?.id, 1);
  });

  testWidgets('typing replaces the suggestions with what matches',
      (tester) async {
    await open(tester, offer: () async => suggestions);

    await tester.enterText(find.byType(TextField), 'searchable');
    await tester.pumpAndSettle();

    expect(find.text('Searchable'), findsOneWidget);
    expect(find.text('PinocchioP'), findsNothing);
    expect(find.text('Already on this release'), findsNothing);
  });

  testWidgets('clearing the field brings the suggestions back', (tester) async {
    // Emptying the box is not a search for nothing, it is being back where
    // the dialog started.
    await open(tester, offer: () async => suggestions);

    await tester.enterText(find.byType(TextField), 'searchable');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();

    expect(find.text('PinocchioP'), findsOneWidget);
  });

  testWidgets('a caller with nothing to offer is unchanged', (tester) async {
    // Every other picker -- group members, a merge target -- passes none.
    await open(tester);

    expect(find.text('Start typing to find an artist.'), findsOneWidget);
    expect(find.text('Already on this release'), findsNothing);
  });

  testWidgets('an album whose tracks have no credits falls back to typing',
      (tester) async {
    await open(tester, offer: () async => const []);

    expect(find.text('Start typing to find an artist.'), findsOneWidget);
  });
}
