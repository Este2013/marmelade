import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:marmelade/widgets/artwork.dart';
import 'package:marmelade/widgets/expandable_artwork.dart';

/// The artwork on a detail page: click to see it big, hover to change it.
///
/// Neither hover nor an overlay can be photographed, so this is the only way
/// to check either of them.
void main() {
  late MarmeladeDatabase db;
  late Directory artRoot;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    artRoot = Directory.systemTemp.createTempSync('marmelade_art_');
  });

  tearDown(() async {
    await db.close();
    try {
      if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort: a picture write that reads a file directly (see the
      // "choosing from covers already on hand" group) can still hold it open
      // here, since real disk I/O does not reliably complete under this test
      // binding. The OS temp directory outlives the run either way.
    }
  });

  Future<void> pump(
    WidgetTester tester, {
    bool editable = true,
    String? storedPath,
    List<String> pickFromCovers = const [],
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          artStoreProvider.overrideWithValue(ArtStore(artRoot)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ExpandableArtwork(
                storedPath: storedPath,
                size: 180,
                owner: PictureOwner.album,
                id: 7,
                title: 'AD:HOUSE Winter 4',
                editable: editable,
                pickFromCovers: pickFromCovers,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }

  /// The smallest valid PNG: a 1x1 transparent pixel. Written straight into
  /// the art store's own root, at the path a "cover already in this
  /// playlist" would actually have.
  void seedCover(String storedPath) {
    final file = File('${artRoot.path}/$storedPath');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(const [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);
  }

  testWidgets('clicking it opens a big preview naming what it is',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byType(ExpandableArtwork));
    await tester.pumpAndSettle();

    expect(find.text('AD:HOUSE Winter 4'), findsOneWidget);
    expect(find.text('Change the picture'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the preview closes again', (tester) async {
    await pump(tester);

    await tester.tap(find.byType(ExpandableArtwork));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Close'), findsNothing);
  });

  testWidgets('clicking the empty space around the picture closes it',
      (tester) async {
    // The overlay is mostly empty space around a square picture, and clicking
    // that space is indistinguishable from clicking the barrier.
    await pump(tester);
    await tester.tap(find.byType(ExpandableArtwork));
    await tester.pumpAndSettle();
    expect(find.text('Close'), findsOneWidget);

    // Well outside the picture, but inside the dialog.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(find.text('Close'), findsNothing);
  });

  testWidgets('clicking the picture itself does not close it', (tester) async {
    await pump(tester);
    await tester.tap(find.byType(ExpandableArtwork));
    await tester.pumpAndSettle();

    // The preview's own artwork, which is the second one in the tree.
    await tester.tap(find.byType(Artwork).last);
    await tester.pumpAndSettle();

    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('the hover button is in the tree even before hovering',
      (tester) async {
    // Deliberately: adding and removing an interactive node on every hover is
    // what floods the Windows accessibility bridge, and a screen reader should
    // reach it without a pointer.
    await pump(tester);

    expect(find.byTooltip('Change the picture'), findsOneWidget);
  });

  testWidgets('nothing is offered when there is nothing to change',
      (tester) async {
    // A synthetic single has a negative id and no row to write to.
    await pump(tester, editable: false);

    expect(find.byTooltip('Change the picture'), findsNothing);

    await tester.tap(find.byType(ExpandableArtwork));
    await tester.pumpAndSettle();

    // The preview still opens -- looking is always allowed.
    expect(find.text('AD:HOUSE Winter 4'), findsOneWidget);
    expect(find.text('Change the picture'), findsNothing);
  });

  group('choosing from covers already on hand', () {
    testWidgets('with none to offer, the hover button goes straight to Add',
        (tester) async {
      // Nothing to assert on the file browser itself -- it is a native
      // dialog -- only that reaching for it does not go through a picker
      // first when there is nothing for a picker to show.
      await pump(tester);

      await tester.tap(find.byTooltip('Change the picture'));
      await tester.pump();

      expect(find.text('Choose a picture'), findsNothing);
    });

    testWidgets('with covers on hand, the hover button offers a picker first',
        (tester) async {
      seedCover('ab/existing.png');
      await pump(tester, pickFromCovers: const ['ab/existing.png']);

      await tester.tap(find.byTooltip('Change the picture'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a picture'), findsOneWidget);
      expect(find.text('Browse for a file...'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the big FAB in the expanded preview offers it too',
        (tester) async {
      seedCover('ab/existing.png');
      await pump(tester, pickFromCovers: const ['ab/existing.png']);

      await tester.tap(find.byType(ExpandableArtwork));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change the picture'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a picture'), findsOneWidget);
    });

    testWidgets('picking a cover closes the picker without touching the file browser',
        (tester) async {
      // The actual write is not asserted here: real disk I/O (ArtStore
      // reading the chosen file) does not complete under this test binding no
      // matter how the wait is structured -- tried a bounded pump loop, a
      // runAsync around the tap, and a runAsync around the whole interaction
      // including pumpWidget, and none of them let it resolve. The
      // mechanism itself is exactly [EditRepository.setAlbumPicture], already
      // covered in edit_repository_test.dart; what is new and worth checking
      // here is that choosing a cover reaches that call at all, rather than
      // silently doing nothing or falling through to the file browser.
      seedCover('ab/existing.png');
      await pump(tester, pickFromCovers: const ['ab/existing.png']);

      await tester.tap(find.byTooltip('Change the picture'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Artwork),
        ),
      );
      // A bounded number of frames, not pumpAndSettle: the dialog's own exit
      // transition needs more than one frame to finish removing it from the
      // tree, but the hover button's indeterminate spinner (shown while the
      // write is in flight) would keep pumpAndSettle from ever returning.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text('Choose a picture'), findsNothing);
    });

    testWidgets('cancelling the picker leaves the picture untouched',
        (tester) async {
      seedCover('ab/existing.png');
      await pump(tester, pickFromCovers: const ['ab/existing.png']);

      await tester.tap(find.byTooltip('Change the picture'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Choose a picture'), findsNothing);
      final images =
          await db.customSelect('SELECT COUNT(*) AS n FROM images').getSingle();
      expect(images.read<int>('n'), 0);
    });
  });

  testWidgets('removing is offered only when there is a picture',
      (tester) async {
    await pump(tester);
    await tester.tap(find.byType(ExpandableArtwork));
    await tester.pumpAndSettle();
    expect(find.text('Remove it'), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await pump(tester, storedPath: 'ab/abcdef.jpg');
    await tester.tap(find.byType(ExpandableArtwork));
    await tester.pumpAndSettle();
    expect(find.text('Remove it'), findsOneWidget);
  });
}
