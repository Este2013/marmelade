import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/services/art/art_store.dart';
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
    if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    bool editable = true,
    String? storedPath,
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
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
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
