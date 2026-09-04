import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/enums.dart';
import 'package:marmelade/data/repositories/edit_repository.dart' show LinkRow;
import 'package:marmelade/features/edit/link_icon_button.dart';
import 'package:marmelade/features/edit/link_visuals.dart';

/// One of an artist's links, as the small button that sits in their tag line.
///
/// These replaced a menu behind a single chain-link icon. What matters now is
/// that each button says where it goes before it is clicked -- the icon for
/// the sites that have one, and the tooltip for the ones that do not.
void main() {
  Future<void> pump(WidgetTester tester, LinkRow link) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: LinkIconButton(link: link))),
        ),
      );

  testWidgets('a plain website opens in a browser, and says so',
      (tester) async {
    // There is no favicon to draw for "somebody's own page", and the chain
    // link said nothing about what clicking it does.
    await pump(
      tester,
      const LinkRow(
        id: 1,
        url: 'https://pinocchiop.com',
        kind: LinkKind.website,
      ),
    );

    expect(find.byIcon(Icons.open_in_browser), findsOneWidget);
    expect(find.byIcon(Icons.link), findsNothing);
  });

  testWidgets('the shrug case keeps the chain link', (tester) async {
    await pump(
      tester,
      const LinkRow(id: 1, url: 'https://example.com', kind: LinkKind.other),
    );

    expect(find.byIcon(Icons.link), findsOneWidget);
    expect(find.byIcon(Icons.open_in_browser), findsNothing);
  });

  testWidgets('the tooltip names the kind and where it actually goes',
      (tester) async {
    // "Website" alone is no help when three of them are side by side.
    await pump(
      tester,
      const LinkRow(
        id: 1,
        url: 'https://pinocchiop.bandcamp.com/album/x',
        kind: LinkKind.bandcamp,
      ),
    );

    final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
    expect(tooltip.message, contains('Bandcamp'));
    expect(tooltip.message, contains('pinocchiop.bandcamp.com'));
  });

  testWidgets('a label somebody typed wins over the kind name',
      (tester) async {
    await pump(
      tester,
      const LinkRow(
        id: 1,
        url: 'https://example.com',
        kind: LinkKind.website,
        label: 'Old blog',
      ),
    );

    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      contains('Old blog'),
    );
  });

  testWidgets('a malformed URL is a row somebody typed, not a crash',
      (tester) async {
    await pump(
      tester,
      const LinkRow(id: 1, url: ':::not a url:::', kind: LinkKind.website),
    );

    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('the fallback icon is chosen per kind, not one for all', () {
    expect(fallbackLinkIcon(LinkKind.website), Icons.open_in_browser);
    expect(fallbackLinkIcon(LinkKind.other), Icons.link);
    // A kind whose favicon failed to load still gets the neutral mark rather
    // than the browser glyph, which would claim it is a plain website.
    expect(fallbackLinkIcon(LinkKind.bandcamp), Icons.link);
  });
}
