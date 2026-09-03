import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/edit_repository.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/features/playlists/smart_query_field.dart';

/// The field that writes a smart playlist's query.
///
/// It says back what it understood, as it is typed, and that is the only part
/// of the UI here with any logic in it: a query language you can be silently
/// wrong about is a query language nobody will trust.
/// An edit repository that answers from a list instead of the database.
///
/// The field looks up artist and album names as they are typed. Backing that
/// with a real database here would run a drift query, and cancelling a drift
/// query stream schedules a cleanup timer that the test binding's fake clock
/// never drains -- the test then fails on a pending timer rather than on
/// anything to do with the field.
class _FakeEdits extends EditRepository {
  _FakeEdits(MarmeladeDatabase db)
      : super(
          db: db,
          searchIndexer: SearchIndexer(db),
          artStore: ArtStore(Directory.systemTemp),
        );

  @override
  Future<List<({int id, String name, ArtistKind kind, int trackCount})>>
      findArtists(String query, {Set<int> exclude = const {}}) async => [
            (
              id: 1,
              name: 'Nanahira',
              kind: ArtistKind.person,
              trackCount: 12,
            ),
            (
              id: 2,
              name: 'Nanawo Akari',
              kind: ArtistKind.person,
              trackCount: 5,
            ),
          ];

  @override
  Future<List<({int id, String title, String? artistName, int trackCount})>>
      findAlbums(String query, {Set<int> exclude = const {}}) async => [
            (
              id: 1,
              title: 'Comic and Cosmic',
              artistName: 'PinocchioP',
              trackCount: 12,
            ),
          ];
}

void main() {
  late MarmeladeDatabase db;

  setUp(() {
    // Opened but never queried, because the fake answers everything.
    db = MarmeladeDatabase.memory();
  });

  tearDown(() => db.close());

  Future<void> pump(
    WidgetTester tester,
    TextEditingController controller,
  ) async {
    // Wider than the 800px default: the suggestion strip is a lazy horizontal
    // list, so a narrow surface simply never builds the chips at the end and
    // the test would be asserting about the viewport, not the suggestions.
    await tester.binding.setSurfaceSize(const Size(1300, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    return tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            editRepositoryProvider.overrideWithValue(_FakeEdits(db)),
            taggedProvider.overrideWith((ref) => Stream.value(const [])),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SmartQueryField(controller: controller),
            ),
          ),
        ),
      );
  }

  testWidgets('an empty query offers the vocabulary', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pump(tester, controller);

    expect(find.textContaining('Fields narrow it'), findsOneWidget);
  });

  testWidgets('the description follows what is typed', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pump(tester, controller);

    await tester.enterText(find.byType(TextField), 'artist:Nanahira');
    await tester.pump();
    expect(find.text('Tracks by Nanahira'), findsOneWidget);

    // And it keeps up, rather than describing the first thing typed forever.
    await tester.enterText(find.byType(TextField), 'tag:hardcore -tag:remix');
    await tester.pump();
    expect(
      find.text('Tracks tagged hardcore and not tagged remix'),
      findsOneWidget,
    );
  });

  group('suggestions', () {
    testWidgets('an empty field offers the fields to filter by',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      expect(find.widgetWithText(ActionChip, 'artist:'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'tag:'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'added:'), findsOneWidget);
    });

    testWidgets('typing part of a field narrows them', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'ar');
      await tester.pump();

      expect(find.widgetWithText(ActionChip, 'artist:'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'tag:'), findsNothing);
    });

    testWidgets('picking a field leaves the caret ready for a value',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.tap(find.widgetWithText(ActionChip, 'artist:'));
      await tester.pump();

      expect(controller.text, 'artist:');
      // No trailing space: a field alone matches nothing, so the value comes
      // next in the same word.
      expect(controller.selection.baseOffset, 7);
    });

    testWidgets('a name field then suggests real names', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'artist:nan');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.widgetWithText(ActionChip, 'Nanahira'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Nanawo Akari'), findsOneWidget);
    });

    testWidgets('accepting a name completes the clause and moves on',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'artist:nan');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.widgetWithText(ActionChip, 'Nanawo Akari'));
      await tester.pump();

      // Quoted, because a name with a space would otherwise be read as a
      // clause plus a stray search word.
      expect(controller.text, 'artist:"Nanawo Akari" ');
    });

    testWidgets('an age field offers spans in words', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'added:');
      await tester.pump();

      expect(find.widgetWithText(ActionChip, '<30d'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, '>1y'), findsOneWidget);
    });

    testWidgets('a number field offers comparators', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'year:');
      await tester.pump();

      expect(find.widgetWithText(ActionChip, 'year:>='), findsOneWidget);
    });

    testWidgets('a tag suggestion inserts exact, not contains',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.binding.setSurfaceSize(const Size(1300, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            editRepositoryProvider.overrideWithValue(_FakeEdits(db)),
            taggedProvider.overrideWith(
              (ref) => Stream.value(const [
                TagCard(id: 1, name: 'Hardcore', trackCount: 4),
              ]),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(body: SmartQueryField(controller: controller)),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'tag:hard');
      await tester.pump();
      await tester.pump();
      await tester.tap(find.widgetWithText(ActionChip, 'Hardcore'));
      await tester.pump();

      // Picking a real tag out of the list means that tag, not "contains" --
      // even though `tag:` (contains) is what was being typed.
      expect(controller.text, 'tag=Hardcore ');
    });

    testWidgets('"is:" offers flags', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'is:');
      await tester.pump();

      expect(find.widgetWithText(ActionChip, 'is:Favourite'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'is:Single'), findsOneWidget);
    });

    testWidgets('suggestions only touch the word being typed', (tester) async {
      final controller = TextEditingController(text: 'tag:hardcore ');
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'tag:hardcore ar');
      await tester.pump();
      await tester.tap(find.widgetWithText(ActionChip, 'artist:'));
      await tester.pump();

      expect(controller.text, 'tag:hardcore artist:');
    });
  });

  group('the inline hint', () {
    /// The greyed completion drawn behind the field, if any.
    String? ghostOf(WidgetTester tester) {
      final spans = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.textSpan)
          .whereType<TextSpan>()
          .where((span) => span.children?.length == 2);
      if (spans.isEmpty) return null;
      return (spans.first.children!.last as TextSpan).text;
    }

    testWidgets('shows the rest of what Tab would add', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'art');
      await tester.pump();

      // "artist:" minus the "art" already typed.
      expect(ghostOf(tester), 'ist:');
    });

    testWidgets('it agrees with what Tab actually does', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'ta');
      await tester.pump();
      final ghost = ghostOf(tester);

      await tester.tap(find.widgetWithText(ActionChip, 'tag:'));
      await tester.pump();

      expect(controller.text, 'ta$ghost');
    });

    testWidgets('nothing is offered when the caret is not at the end',
        (tester) async {
      // A hint next to a caret in the middle of the text would be pointing at
      // the wrong place and describing something Tab would not do.
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(tester, controller);

      await tester.enterText(find.byType(TextField), 'artist:x tag');
      controller.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();

      expect(ghostOf(tester), isNull);
    });
  });

  testWidgets('a half-typed query still describes itself', (tester) async {
    // Every character is a state the field is in. "year:>" parses to nothing
    // and must not throw on the way there.
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await pump(tester, controller);

    for (final text in ['y', 'year', 'year:', 'year:>', 'year:>2', 'year:>20']) {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: text);
    }
    expect(find.text('Tracks released after 20'), findsOneWidget);
  });
}
