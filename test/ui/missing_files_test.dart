import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/missing_files_repository.dart';
import 'package:marmelade/features/settings/missing_files_section.dart';

/// Telling someone their library has lost files.
///
/// The rule that matters is when this is *absent*: a settings page that warns
/// about a problem nobody has trains people to scroll past warnings, and the
/// one time it appears it needs to be read.
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester, MissingSummary summary) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          missingSummaryProvider.overrideWith((ref) => Stream.value(summary)),
        ],
        child: const MaterialApp(
          home: Scaffold(body: MissingFilesSection()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('says nothing at all when nothing is missing', (tester) async {
    await pump(tester, MissingSummary.none);

    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('missing'), findsNothing);
  });

  testWidgets('counts the songs, and the albums that went with them',
      (tester) async {
    await pump(tester, const MissingSummary(tracks: 12, albums: 2, files: 14));

    expect(find.textContaining('12 songs are missing their files'),
        findsOneWidget);
    expect(find.textContaining('2 albums'), findsOneWidget);
  });

  testWidgets('offers hiding and removing, and leads with hiding',
      (tester) async {
    // Order is the argument: a missing file is usually a drive left at home,
    // so the reversible answer is the one in reach and the permanent one is
    // a plain text button.
    await pump(tester, const MissingSummary(tracks: 3, albums: 0, files: 3));

    expect(find.text('Keep them out of the lists'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Remove them from the library'),
        findsOneWidget);
  });

  testWidgets('warns what removing costs before doing it', (tester) async {
    await pump(tester, const MissingSummary(tracks: 3, albums: 1, files: 3));

    await tester.tap(find.text('Remove them from the library'));
    await tester.pumpAndSettle();

    // The part people do not think of: the files are gone either way, but the
    // work put into describing them need not be.
    expect(find.textContaining('tags, ratings, play counts and lyrics'),
        findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Keep them'), findsOneWidget);
  });

  group('the sentence it leads with', () {
    test('names songs alone when no album is entirely gone', () {
      expect(
        describeMissing(const MissingSummary(tracks: 4, albums: 0, files: 4)),
        '4 songs are missing their files.',
      );
    });

    test('mentions whole albums when there are any', () {
      expect(
        describeMissing(const MissingSummary(tracks: 9, albums: 1, files: 9)),
        contains('including 1 album that is gone entirely'),
      );
    });

    test('reads properly for a single song', () {
      expect(
        describeMissing(const MissingSummary(tracks: 1, albums: 0, files: 1)),
        '1 song is missing its file.',
      );
    });
  });
}
