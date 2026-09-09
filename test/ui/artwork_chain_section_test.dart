import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/edit_repository.dart';
import 'package:marmelade/features/edit/artwork_chain_section.dart';
import 'package:marmelade/services/art/art_store.dart';

/// The track editor's picture section: three cards for `v_track_artwork`'s
/// own fallback (artist, then album, then track -- the order the cascade
/// itself is overridden in), with the stage that actually wins highlighted.
/// A small hover button on each does the card's one action: open_in_new for
/// the album and the artist, edit for the track, which is also what tapping
/// the card itself does.
void main() {
  late Directory artRoot;

  setUp(() {
    artRoot = Directory.systemTemp.createTempSync('marmelade_chain_art_');
  });

  tearDown(() {
    if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
  });

  Widget wrap(
    Widget child, {
    required TrackArtworkChain? chain,
  }) {
    return ProviderScope(
      overrides: [
        artStoreProvider.overrideWithValue(ArtStore(artRoot)),
        trackArtworkChainProvider.overrideWith((ref, id) => Stream.value(chain)),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  Future<void> pump(WidgetTester tester, Widget widget) async {
    // A blank frame first, so a second pumpWidget in the same test (the
    // fall-through case) starts from nothing rather than diffing against
    // whatever tree was there a moment ago.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(widget);
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('lists the three stages left to right: artist, album, track',
      (tester) async {
    await pump(
      tester,
      wrap(
        const TrackArtworkChainSection(trackId: 1, trackTitle: 'Feel Right'),
        chain: const TrackArtworkChain(
          albumId: 2,
          albumTitle: 'AD:HOUSE Winter 4',
          artistId: 3,
          artistName: 'Koiflower',
        ),
      ),
    );

    double left(String label) => tester.getTopLeft(find.text(label)).dx;
    expect(left('Artist'), lessThan(left('Album')));
    expect(left('Album'), lessThan(left('Track')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('highlights the track card when the track has its own picture',
      (tester) async {
    await pump(
      tester,
      wrap(
        const TrackArtworkChainSection(trackId: 1, trackTitle: 'Feel Right'),
        chain: const TrackArtworkChain(
          trackImagePath: 'tr/ack.jpg',
          albumId: 2,
          albumTitle: 'AD:HOUSE Winter 4',
        ),
      ),
    );

    expect(
      find.text("This track has its own picture, which wins over the album "
          'and the artist.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'falls through to the album, then the artist, exactly like the app '
      'does', (tester) async {
    await pump(
      tester,
      wrap(
        const TrackArtworkChainSection(trackId: 1, trackTitle: 'Feel Right'),
        chain: const TrackArtworkChain(
          albumId: 2,
          albumTitle: 'AD:HOUSE Winter 4',
          albumImagePath: 'al/bum.jpg',
        ),
      ),
    );
    expect(
      find.text("This track has no picture of its own, so the album's is "
          'shown.'),
      findsOneWidget,
    );

    await pump(
      tester,
      wrap(
        const TrackArtworkChainSection(trackId: 1, trackTitle: 'Feel Right'),
        chain: const TrackArtworkChain(
          artistId: 3,
          artistName: 'Koiflower',
          artistImagePath: 'ar/tist.jpg',
        ),
      ),
    );
    expect(
      find.text("Neither this track nor its album has a picture, so the "
          "artist's is shown."),
      findsOneWidget,
    );
  });

  testWidgets('the album card opens the album it names', (tester) async {
    int? opened;
    await pump(
      tester,
      wrap(
        TrackArtworkChainSection(
          trackId: 1,
          trackTitle: 'Feel Right',
          onOpenAlbum: (id) => opened = id,
        ),
        chain: const TrackArtworkChain(
          albumId: 2,
          albumTitle: 'AD:HOUSE Winter 4',
        ),
      ),
    );

    await tester.tap(find.text('AD:HOUSE Winter 4'));
    await tester.pump();
    expect(opened, 2);
  });

  testWidgets('the artist card opens the artist it names', (tester) async {
    int? opened;
    await pump(
      tester,
      wrap(
        TrackArtworkChainSection(
          trackId: 1,
          trackTitle: 'Feel Right',
          onOpenArtist: (id) => opened = id,
        ),
        chain: const TrackArtworkChain(artistId: 3, artistName: 'Koiflower'),
      ),
    );

    await tester.tap(find.text('Koiflower'));
    await tester.pump();
    expect(opened, 3);
  });

  testWidgets('a track with no album at all offers nothing to tap there',
      (tester) async {
    var tapped = false;
    await pump(
      tester,
      wrap(
        TrackArtworkChainSection(
          trackId: 1,
          trackTitle: 'Feel Right',
          onOpenAlbum: (_) => tapped = true,
        ),
        chain: const TrackArtworkChain(),
      ),
    );

    // No album name to find, but the card's dash placeholder must not crash
    // or somehow still be tappable.
    await tester.tap(find.text('Album'));
    await tester.pump();
    expect(tapped, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the track card is always tappable, even with no picture yet',
      (tester) async {
    await pump(
      tester,
      wrap(
        const TrackArtworkChainSection(trackId: 1, trackTitle: 'Feel Right'),
        chain: const TrackArtworkChain(),
      ),
    );

    // Not actually tapped: that would reach the real file picker, a native
    // dialog a widget test cannot drive. Checking the InkWell itself is
    // wired is what is actually being asked here -- that the card never
    // goes dead just because nothing has been chosen yet.
    final inkWell = tester.widget<InkWell>(
      find.ancestor(of: find.text('Track'), matching: find.byType(InkWell)),
    );
    expect(inkWell.onTap, isNotNull);
  });

  testWidgets(
      'the hover button is open_in_new for album and artist, edit for the '
      'track', (tester) async {
    await pump(
      tester,
      wrap(
        const TrackArtworkChainSection(trackId: 1, trackTitle: 'Feel Right'),
        chain: const TrackArtworkChain(
          albumId: 2,
          albumTitle: 'AD:HOUSE Winter 4',
          artistId: 3,
          artistName: 'Koiflower',
        ),
      ),
    );

    expect(find.byIcon(Icons.open_in_new), findsNWidgets(2));
    expect(find.byIcon(Icons.edit), findsOneWidget);
  });

  testWidgets('the hover button stays out of the way until hovered',
      (tester) async {
    await pump(
      tester,
      wrap(
        const TrackArtworkChainSection(trackId: 1, trackTitle: 'Feel Right'),
        chain: const TrackArtworkChain(),
      ),
    );

    // Icons.edit only ever appears once, on the track card, so this does
    // not have the album and the artist card's shared open_in_new icon to
    // tell apart.
    double editOpacity() => tester
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.byIcon(Icons.edit),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    expect(editOpacity(), 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Track')));
    await tester.pumpAndSettle();

    expect(editOpacity(), 1);
  });

  testWidgets(
      'the track card offers to remove its picture only when it has one',
      (tester) async {
    await pump(
      tester,
      wrap(
        const TrackArtworkChainSection(trackId: 1, trackTitle: 'Feel Right'),
        chain: const TrackArtworkChain(),
      ),
    );
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    await pump(
      tester,
      wrap(
        const TrackArtworkChainSection(trackId: 1, trackTitle: 'Feel Right'),
        chain: const TrackArtworkChain(trackImagePath: 'tr/ack.jpg'),
      ),
    );
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets(
      'removing the track\'s picture reaches the database, the way '
      '"Instant Reaction" by Xtrullor -- a track with its own picture over '
      "its album's -- needed to be clearable", (tester) async {
    final db = MarmeladeDatabase.memory();
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();
    final imageId = await db.into(db.images).insert(
          ImagesCompanion.insert(
            sha256: 'hash',
            kind: ImageKind.embedded,
            mimeType: 'image/jpeg',
            byteSize: 100,
            storedPath: 'tr/ack.jpg',
          ),
        );
    final trackId = await db.into(db.tracks).insert(
          TracksCompanion.insert(
            title: 'Instant Reaction',
            nameKey: 'instant reaction',
            imageId: Value(imageId),
          ),
        );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          artStoreProvider.overrideWithValue(ArtStore(artRoot)),
          // Only the card's own display is faked; the delete button still
          // reaches the real repository and the real database above.
          trackArtworkChainProvider.overrideWith(
            (ref, id) => Stream.value(
              const TrackArtworkChain(trackImagePath: 'tr/ack.jpg'),
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TrackArtworkChainSection(
              trackId: trackId,
              trackTitle: 'Instant Reaction',
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Instant Reaction')));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();

    final row = await db.customSelect(
      'SELECT image_id FROM tracks WHERE id = ?1',
      variables: [Variable(trackId)],
    ).getSingle();
    expect(row.read<int?>('image_id'), isNull);
  });
}
