import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/tag_repository.dart';
import 'package:marmelade/features/tags/tag_line.dart';

/// The tags on a detail page's header line.
///
/// A hover cannot be photographed, so the appearing "Add" chip is only
/// checkable here.
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  const attached = [
    AttachedTag(
      id: 10,
      name: 'genshin impact',
      origin: TagOrigin.own,
      categoryName: 'Game',
      color: 0xFFE91E63,
    ),
    AttachedTag(id: 11, name: 'orchestral', origin: TagOrigin.own),
  ];

  Future<void> pump(
    WidgetTester tester, {
    List<AttachedTag> tags = attached,
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          taggedProvider.overrideWith((ref) => const Stream.empty()),
          attachedTagsProvider(
            (target: TagTarget.album, id: 7),
          ).overrideWith((ref) => Stream.value(tags)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: TagLine(target: TagTarget.album, id: 7),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The opacity the "Add" chip is currently drawn at.
  double addOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byType(ActionChip),
          matching: find.byType(AnimatedOpacity),
        ),
      )
      .opacity;

  testWidgets('every tag on the thing is shown', (tester) async {
    await pump(tester);

    expect(find.text('genshin impact'), findsOneWidget);
    expect(find.text('orchestral'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the add chip stays out of the way until hovered',
      (tester) async {
    await pump(tester);
    expect(addOpacity(tester), 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('orchestral')));
    await tester.pumpAndSettle();

    expect(addOpacity(tester), 1);
  });

  testWidgets('with no tags the add chip is there to be found',
      (tester) async {
    // Nothing to hover on an empty line, so hiding it would hide the only way
    // to put the first tag on.
    await pump(tester, tags: const []);

    expect(addOpacity(tester), 1);
    expect(find.text('Add a tag'), findsOneWidget);
  });

  testWidgets('the chip is in the tree even while invisible', (tester) async {
    // Faded rather than removed: adding and removing an interactive widget on
    // every hover churns the Windows accessibility tree, and a screen reader
    // should reach it without a pointer.
    await pump(tester);

    expect(find.byType(ActionChip), findsOneWidget);
  });
}
