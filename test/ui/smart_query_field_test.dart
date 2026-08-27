import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/features/playlists/smart_query_field.dart';

/// The field that writes a smart playlist's query.
///
/// It says back what it understood, as it is typed, and that is the only part
/// of the UI here with any logic in it: a query language you can be silently
/// wrong about is a query language nobody will trust.
void main() {
  Future<void> pump(WidgetTester tester, TextEditingController controller) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmartQueryField(controller: controller),
          ),
        ),
      );

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
