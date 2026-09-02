import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/tag_repository.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/features/tags/tags_view.dart';

/// A tag repository that records what it was asked to do.
///
/// The view's job is to ask for the right change; whether the change lands is
/// the repository's own tested business. Recording the call keeps this test
/// about the gesture.
class _RecordingTags extends TagRepository {
  _RecordingTags(MarmeladeDatabase db)
      : super(db: db, searchIndexer: SearchIndexer(db));

  final moves = <({int tagId, int? categoryId})>[];

  @override
  Future<void> setTagCategory(int tagId, int? categoryId) async {
    moves.add((tagId: tagId, categoryId: categoryId));
  }
}

void main() {
  late MarmeladeDatabase db;
  late _RecordingTags tags;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    tags = _RecordingTags(db);
  });

  tearDown(() => db.close());

  const categories = [
    TagCategoryRow(
      id: 1,
      name: 'Genre',
      slug: 'genre',
      isSystem: true,
      tagCount: 1,
    ),
    TagCategoryRow(
      id: 2,
      name: 'Mood',
      slug: 'mood',
      isSystem: false,
      tagCount: 0,
      icon: 0xe7f2,
      color: 0xFF7C4DFF,
    ),
  ];

  const tagCards = [
    TagCard(
      id: 10,
      name: 'Hardcore',
      trackCount: 40,
      categoryId: 1,
      categoryName: 'Genre',
    ),
    TagCard(id: 11, name: 'Favourite', trackCount: 3),
  ];

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          tagRepositoryProvider.overrideWithValue(tags),
          taggedProvider.overrideWith((ref) => Stream.value(tagCards)),
          tagCategoriesProvider.overrideWith((ref) => Stream.value(categories)),
        ],
        child: MaterialApp(
          home: Scaffold(
            // "New category" now lives in TagsToolbar, the window title
            // bar's content in the real app (see AppShell) -- stood up
            // alongside the view here rather than inside it.
            body: Column(
              children: [
                const TagsToolbar(),
                Expanded(child: TagsView(onOpenTag: (_) {})),
              ],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('every category is a heading, and uncategorised always shows',
      (tester) async {
    await pump(tester);

    expect(find.text('Genre'), findsWidgets);
    expect(find.text('Mood'), findsOneWidget);
    // Empty, but present: it is the only way to drag a tag *out* of a
    // category, and a target that appears only once something is in it cannot
    // be used to put the first thing there.
    expect(find.text('Uncategorised'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging a tag onto a heading moves it there', (tester) async {
    await pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Hardcore')),
    );
    // Moved in steps: a single jump can miss the drag threshold, and the
    // target only lights up once the drag has actually started.
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('Mood')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tags.moves, [(tagId: 10, categoryId: 2)]);
  });

  testWidgets('dragging onto uncategorised takes it out of its category',
      (tester) async {
    await pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Hardcore')),
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('Uncategorised')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tags.moves, [(tagId: 10, categoryId: null)]);
  });

  testWidgets('dragging to the bottom edge scrolls the list down',
      (tester) async {
    // A category further down cannot be dropped on if it is off the screen,
    // and letting go to scroll means starting the drag over.
    final many = [
      ...categories,
      for (var i = 0; i < 30; i++)
        TagCategoryRow(
          id: 100 + i,
          name: 'Category $i',
          slug: 'category-$i',
          isSystem: false,
          tagCount: 0,
        ),
    ];

    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          tagRepositoryProvider.overrideWithValue(tags),
          taggedProvider.overrideWith((ref) => Stream.value(tagCards)),
          tagCategoriesProvider.overrideWith((ref) => Stream.value(many)),
        ],
        child: MaterialApp(
          home: Scaffold(body: TagsView(onOpenTag: (_) {})),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }

    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.pixels, 0);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Hardcore')),
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    // Down into the sensitive band at the bottom of the list.
    await gesture.moveTo(const Offset(600, 690));
    // Pumped in slices rather than settled: the scroll runs on a repeating
    // timer, so settling would wait for something that only stops when the
    // drag does.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }

    expect(position.pixels, greaterThan(0));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the scrolling edge does not swallow the drop', (tester) async {
    // The bands sit over the list, so a heading underneath one has to stay the
    // thing that receives the tag.
    await pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Hardcore')),
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('Mood')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tags.moves, [(tagId: 10, categoryId: 2)]);
  });

  testWidgets('a tag cannot be dropped on the category it is already in',
      (tester) async {
    await pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Hardcore')),
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('Genre').first));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(tags.moves, isEmpty);
  });

  testWidgets('the tag dialog offers a category as well as a name',
      (tester) async {
    await pump(tester);

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Hardcore'),
          matching: find.byType(Row),
        ).first,
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename or recategorise'));
    await tester.pumpAndSettle();

    expect(find.text('Edit tag'), findsOneWidget);
    expect(find.widgetWithText(DropdownButtonFormField<int?>, 'Category'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the category dialog offers icons and colours', (tester) async {
    await pump(tester);

    await tester.tap(find.text('New category'));
    await tester.pumpAndSettle();

    expect(find.text('New tag category'), findsOneWidget);
    expect(find.text('Icon'), findsOneWidget);
    expect(find.text('Colour'), findsOneWidget);
    // Done stays disabled until it has a name, because a nameless category is
    // a heading nobody can read.
    final done = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Done'),
    );
    expect(done.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
