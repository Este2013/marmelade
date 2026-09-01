import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/tag_repository.dart';
import 'package:marmelade/features/library/bulk_actions.dart';

/// The "Add a tag" dialog shared by every tag line and the mass-tag menu.
///
/// The category is picked from the text field's own leading icon rather than
/// a separate dropdown -- there is only one thing to say ("which category"),
/// and it used to take a whole extra field to say it.
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
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

  ({String name, int? categoryId})? result;

  Future<void> pump(WidgetTester tester) async {
    result = null;
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
                onPressed: () async {
                  result = await askForTag(context, ref, title: 'Add a tag');
                },
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

  testWidgets('with no category picked, adding is categoryId: null',
      (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'chiptune');
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(result, (name: 'chiptune', categoryId: null));
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
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(result, (name: 'chiptune', categoryId: 1));
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
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(result, (name: 'chill', categoryId: null));
  });
}
