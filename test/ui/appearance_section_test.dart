import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/app/theme/theme_settings.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/features/settings/appearance_section.dart';

/// The appearance settings.
///
/// The sources are listed by hand here, one chip each, so the thing worth
/// asserting is that the list and the enum agree: a source added to the enum
/// with no chip beside it is a setting nobody can reach.
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });
  tearDown(() => db.close());

  Future<void> pump(WidgetTester tester) async {
    // Tall enough for the whole section: this page has grown, and a chip
    // scrolled out of the viewport is a tap that quietly misses.
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AppearanceSection()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('offers a way to choose every source there is', (tester) async {
    await pump(tester);

    for (final source in AccentSource.values) {
      if (source == AccentSource.custom) {
        // Chosen by picking one of the swatches, not by a chip of its own.
        continue;
      }
      expect(find.text(source.label), findsOne, reason: source.name);
    }
  });

  testWidgets('offers every contrast level, and starts on the default',
      (tester) async {
    await pump(tester);

    for (final level in ContrastLevel.values) {
      expect(find.text(level.label), findsOne, reason: level.name);
    }
    final picker = tester.widget<SegmentedButton<ContrastLevel>>(
      find.byType(SegmentedButton<ContrastLevel>),
    );
    expect(picker.selected, {ContrastLevel.normal});
  });

  testWidgets('choosing a contrast level takes effect', (tester) async {
    await pump(tester);

    await tester.tap(find.text(ContrastLevel.highest.label));
    await tester.pump();

    final picker = tester.widget<SegmentedButton<ContrastLevel>>(
      find.byType(SegmentedButton<ContrastLevel>),
    );
    expect(picker.selected, {ContrastLevel.highest});

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('picking "whatever is playing" sticks', (tester) async {
    await pump(tester);

    await tester.tap(find.text(AccentSource.adaptive.label));
    await tester.pump();

    final chip = tester.widget<ChoiceChip>(
      find.ancestor(
        of: find.text(AccentSource.adaptive.label),
        matching: find.byType(ChoiceChip),
      ),
    );
    expect(chip.selected, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('says what it will do, including where it falls back',
      (tester) async {
    // "Adaptive" says nothing on its own, and an app that changes colour on
    // its own needs to explain itself.
    await pump(tester);
    await tester.tap(find.text(AccentSource.adaptive.label));
    await tester.pump();

    expect(find.textContaining('artwork of whatever is playing'), findsOne);
    expect(find.textContaining('when nothing is loaded'), findsOne);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
