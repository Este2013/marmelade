import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/features/search/search_view.dart';

/// The search field's own suggestions -- the same query language a smart
/// playlist uses, offered as a small popup rather than by growing the fixed
/// title bar the field lives in.
void main() {
  Future<void> pump(
    WidgetTester tester,
    TextEditingController controller,
    FocusNode focusNode,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taggedProvider.overrideWith((ref) => Stream.value(const [])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SearchToolbar(
              controller: controller,
              focusNode: focusNode,
              onClear: () {
                controller.clear();
                focusNode.requestFocus();
              },
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a field prefix offers suggestions as a popup, not inline',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pump(tester, controller, focusNode);

    focusNode.requestFocus();
    await tester.enterText(find.byType(TextField), 'art');
    await tester.pump();

    // The suggestion is findable, and it did not get there by growing the
    // field's own box -- the field is still one line tall.
    expect(find.text('artist:'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLines ?? 1, 1);
  });

  testWidgets('nothing pops up without focus', (tester) async {
    final controller = TextEditingController(text: 'art');
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pump(tester, controller, focusNode);
    await tester.pump();

    expect(find.text('artist:'), findsNothing);
  });

  testWidgets('tapping a suggestion applies it', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pump(tester, controller, focusNode);

    focusNode.requestFocus();
    await tester.enterText(find.byType(TextField), 'art');
    await tester.pump();

    await tester.tap(find.text('artist:'));
    await tester.pump();

    expect(controller.text, 'artist:');
  });

  testWidgets('Tab accepts the first suggestion', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pump(tester, controller, focusNode);

    focusNode.requestFocus();
    await tester.enterText(find.byType(TextField), 'is');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, 'is:');
  });

  testWidgets('Escape closes the popup without clearing the field',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await pump(tester, controller, focusNode);

    focusNode.requestFocus();
    await tester.enterText(find.byType(TextField), 'art');
    await tester.pump();
    expect(find.text('artist:'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.text('artist:'), findsNothing);
    expect(controller.text, 'art');
  });

  testWidgets('a tag suggestion inserts exact, not contains', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          taggedProvider.overrideWith(
            (ref) => Stream.value(const [
              TagCard(id: 1, name: 'Hardcore', trackCount: 4),
            ]),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SearchToolbar(
              controller: controller,
              focusNode: focusNode,
              onClear: () {},
            ),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.enterText(find.byType(TextField), 'tag:hard');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Hardcore'));
    await tester.pump();

    expect(controller.text, 'tag=Hardcore ');
  });
}
