import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/widgets/empty_state.dart';

/// What a fresh install is looking at.
///
/// Worth its own test because the failure was invisible in code review: the
/// widget took an `onAddFolder` callback and every caller passed nothing, so
/// the screen whose entire job is "get started" rendered a sentence and no
/// way to act on it.
void main() {
  Future<void> pump(WidgetTester tester, {VoidCallback? onOpenSettings}) =>
      tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: LibraryEmptyState(onOpenSettings: onOpenSettings),
            ),
          ),
        ),
      );

  testWidgets('offers a way to add music without going looking for it',
      (tester) async {
    await pump(tester);

    expect(find.text('No music yet'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Choose a music folder'),
      findsOneWidget,
      reason: 'the primary action must be present, not merely possible',
    );
  });

  testWidgets('offers settings as well, and calls back when pressed',
      (tester) async {
    var opened = 0;
    await pump(tester, onOpenSettings: () => opened++);

    await tester.tap(find.widgetWithText(TextButton, 'Open settings'));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets('leaves settings out when nothing can navigate there',
      (tester) async {
    // Rendered outside the shell -- a test, a preview -- there is nowhere to
    // go, and a button that does nothing is worse than no button.
    await pump(tester);

    expect(find.text('Open settings'), findsNothing);
    expect(find.text('Choose a music folder'), findsOneWidget);
  });
}
