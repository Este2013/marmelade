import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/tag_repository.dart';
import 'package:marmelade/features/library/bulk_actions.dart';

/// The "Add a tag" dialog shared by every tag line and the mass-tag menu.
///
/// It writes to the database directly now rather than handing a single
/// picked name back to its caller: every add and remove happens the moment
/// it is asked for, and the dialog can stay open to do another. That is what
/// makes the "existing tags" section meaningful -- it is a live view of what
/// this item actually carries, not a snapshot taken when the dialog opened.
void main() {
  late MarmeladeDatabase db;
  late int trackId;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    trackId = await db.into(db.tracks).insert(
          const TracksCompanion(
            title: Value('Song'),
            nameKey: Value('song'),
          ),
        );
  });

  tearDown(() => db.close());

  const categories = [
    TagCategoryRow(
      id: 1,
      name: 'Genre',
      slug: 'genre',
      isSystem: true,
      tagCount: 1,
      icon: 0xe405,
      color: 0xFF7C4DFF,
    ),
    TagCategoryRow(
      id: 2,
      name: 'Mood',
      slug: 'mood',
      isSystem: false,
      tagCount: 0,
    ),
  ];

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          taggedProvider.overrideWith((ref) => Stream.value(const [])),
          tagCategoriesProvider
              .overrideWith((ref) => Stream.value(categories)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () => askForTag(
                  context,
                  ref,
                  title: 'Add a tag',
                  target: TagTarget.track,
                  ids: {trackId},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The category actually stored against a tag by that name, straight from
  /// the table -- the dialog no longer hands a value back to check.
  Future<int?> storedCategoryOf(String name) async {
    final row = await db.customSelect(
      'SELECT category_id FROM tags WHERE name = ?1',
      variables: [Variable(name)],
    ).getSingleOrNull();
    return row?.read<int?>('category_id');
  }

  testWidgets('typing a name and adding creates it uncategorised',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump();
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    expect(await storedCategoryOf('chiptune'), isNull);
    // The dialog stays open -- closing communicates "I am done", not
    // "commit what I chose" -- so the add lands while it is still there.
    expect(find.text('Add a tag'), findsOneWidget);

    // A live attachedTagsProvider stream is the whole point of this test;
    // cancelling one schedules a zero-duration cleanup timer the test
    // binding's fake clock never drains on its own unless the tree is
    // unmounted deliberately first -- see smart_query_field_test.dart.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('picking a category from the leading icon carries it through',
      (tester) async {
    await pump(tester);

    await tester.tap(find.byTooltip('Category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Genre'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump();
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    expect(await storedCategoryOf('chiptune'), 1);

    // A live attachedTagsProvider stream is the whole point of this test;
    // cancelling one schedules a zero-duration cleanup timer the test
    // binding's fake clock never drains on its own unless the tree is
    // unmounted deliberately first -- see smart_query_field_test.dart.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('"None" clears a category once one has been picked',
      (tester) async {
    // Regression guard: "None" is a real, selectable value here, not the
    // absence of one. PopupMenuButton pops plain `null` for a dismissed menu
    // too, so a "None" item whose own value was `null` could never be told
    // apart from someone tapping outside the menu -- onSelected simply never
    // fired for it. See bulk_actions.dart's `_noCategory` sentinel.
    await pump(tester);

    await tester.tap(find.byTooltip('Category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mood'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('None'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'chill');
    await tester.pump();
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    expect(await storedCategoryOf('chill'), isNull);

    // A live attachedTagsProvider stream is the whole point of this test;
    // cancelling one schedules a zero-duration cleanup timer the test
    // binding's fake clock never drains on its own unless the tree is
    // unmounted deliberately first -- see smart_query_field_test.dart.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('an added tag shows up under "Existing tags" with a remove',
      (tester) async {
    await pump(tester);

    expect(find.text('Existing tags'), findsNothing);

    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump();
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    expect(find.text('Existing tags'), findsOneWidget);
    expect(find.text('chiptune'), findsOneWidget);
    // The old wording this replaced must not still be here.
    expect(find.text('Tags you already have'), findsNothing);

    // A live attachedTagsProvider stream is the whole point of this test;
    // cancelling one schedules a zero-duration cleanup timer the test
    // binding's fake clock never drains on its own unless the tree is
    // unmounted deliberately first -- see smart_query_field_test.dart.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('removing an existing tag detaches it, dialog stays open',
      (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump();
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    expect(find.text('chiptune'), findsOneWidget);

    // Chip's own delete icon.
    await tester.tap(find.descendant(
      of: find.widgetWithText(Chip, 'chiptune'),
      matching: find.byIcon(Icons.close),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Existing tags'), findsNothing);
    final tags = await db.customSelect(
      'SELECT COUNT(*) AS c FROM track_tags WHERE track_id = ?1',
      variables: [Variable(trackId)],
    ).getSingle();
    expect(tags.read<int>('c'), 0);
    // Removing did not close the dialog.
    expect(find.text('Add a tag'), findsOneWidget);

    // A live attachedTagsProvider stream is the whole point of this test;
    // cancelling one schedules a zero-duration cleanup timer the test
    // binding's fake clock never drains on its own unless the tree is
    // unmounted deliberately first -- see smart_query_field_test.dart.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
