import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/enums.dart';
import 'package:marmelade/data/repositories/edit_repository.dart' show LinkRow;
import 'package:marmelade/features/edit/link_icon_button.dart';
import 'package:marmelade/features/edit/link_visuals.dart';
import 'package:path/path.dart' as p;

/// Where a kind's favicon lives, mirroring `link_visuals.dart`'s own private
/// mapping -- only the two kinds that have no asset matter here.
String? _asset(LinkKind kind) => switch (kind) {
      LinkKind.website || LinkKind.other => null,
      _ => 'assets/link_icons/${kind.name}.png',
    };

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

  testWidgets('a link saved without https still knows where it goes',
      (tester) async {
    // Nobody types the scheme, and without one `Uri` reads the whole thing as
    // a path with no host -- so the button opened nothing and the tooltip
    // named no site. Assuming https is what an address bar does.
    await pump(
      tester,
      const LinkRow(
        id: 1,
        url: 'pinocchiop.bandcamp.com/album/x',
        kind: LinkKind.bandcamp,
      ),
    );

    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      contains('pinocchiop.bandcamp.com'),
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNotNull,
      reason: 'the button has somewhere to go',
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

  testWidgets('a badge shares the chip row rhythm but sits under its height',
      (tester) async {
    // Two separate things, and both matter. The *button* is a compact Chip's
    // measured height, so the row keeps one rhythm and every badge has the
    // same tap target -- asserted against a real chip rather than trusting
    // the constant, since chip density or label style would move it. The
    // *favicon* inside is deliberately smaller, because a filled square
    // reads as bigger than an outlined chip of the same height: drawn at the
    // full 30 the badges loomed over the tags beside them.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const LinkIconButton(
                  link: LinkRow(
                    id: 1,
                    url: 'https://x.bandcamp.com',
                    kind: LinkKind.bandcamp,
                  ),
                ),
                Chip(
                  label: Text(
                    'a tag',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  avatar: const Icon(Icons.label, size: 14),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onDeleted: () {},
                  deleteIcon: const Icon(Icons.close, size: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chip = tester.getSize(find.byType(Chip)).height;
    expect(tester.getSize(find.byType(LinkIconButton)).height, chip);

    final glyph = tester.getSize(find.byType(LinkKindIcon)).height;
    expect(glyph, lessThan(chip), reason: 'a filled square reads as bigger');
    expect(glyph, greaterThan(18), reason: 'and it was too small to read at 18');
  });

  testWidgets('a logo that does not fill its square gets one', (tester) async {
    // YouTube's mark is a play button on nothing and Niconico's is a
    // near-black television: one floats in a row of filled tiles, the other
    // vanishes into a dark theme. Both get the site's own backdrop.
    // Scoped to the icon: Material paints plenty of its own ColoredBoxes.
    Color? badgeOf(WidgetTester tester) => tester
        .widget<ColoredBox>(
          find.descendant(
            of: find.byType(LinkKindIcon),
            matching: find.byType(ColoredBox),
          ),
        )
        .color;

    await pump(
      tester,
      const LinkRow(id: 1, url: 'https://youtube.com/@x', kind: LinkKind.youtube),
    );
    // Sampled from the asset, so the fill and the logo are one flat colour.
    // Pure red here would leave a visible pill inside the square.
    expect(badgeOf(tester), const Color(0xFFFF0033));

    // The dark-on-transparent ones, which a dark theme swallowed whole.
    for (final kind in [LinkKind.niconico, LinkKind.bluesky, LinkKind.vgmdb]) {
      await pump(tester, LinkRow(id: 1, url: 'https://x.test', kind: kind));
      expect(badgeOf(tester), Colors.white, reason: kind.name);
    }

    // A logo that already fills its own tile is left alone.
    await pump(
      tester,
      const LinkRow(id: 1, url: 'https://x.bandcamp.com', kind: LinkKind.bandcamp),
    );
    expect(badgeOf(tester), Colors.transparent);
  });

  testWidgets('every kind, rendered side by side for a look', (tester) async {
    // Set MARMELADE_UI_SHOTS to keep the PNG. This is the only way to check a
    // row of brand assets by eye, and they get re-pulled from time to time --
    // a logo that arrives on transparency needs a backdrop adding above, and
    // nothing but looking will tell you.
    //
    // Two things about images in a widget test, both learned the hard way:
    // an `Image.asset` resolves asynchronously and is still blank when the
    // frame rasterises unless it is precached inside `runAsync` first, and
    // Material *icon* glyphs never render at all (the icon font is not
    // loaded), so the website and other kinds always come out as boxes here.
    final shotDir = Platform.environment['MARMELADE_UI_SHOTS'];
    if (shotDir == null) return;

    await tester.binding.setSurfaceSize(const Size(760, 140));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final kind in LinkKind.values)
                    LinkIconButton(
                      link: LinkRow(id: 1, url: 'https://x.test', kind: kind),
                    ),
                  // A real chip on the end, because the size that matters is
                  // the one next to a tag -- which is what this row is.
                  Chip(
                    label: Text(
                      'a tag',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    avatar: const Icon(Icons.label, size: 14),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onDeleted: () {},
                    deleteIcon: const Icon(Icons.close, size: 14),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.runAsync(() async {
      for (final kind in LinkKind.values) {
        if (_asset(kind) == null) continue;
        await precacheImage(
          AssetImage(_asset(kind)!),
          tester.element(find.byType(Wrap)),
        );
      }
    });
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return;
      final file = File(p.join(shotDir, 'link-badges.png'));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes.buffer.asUint8List());
    });
  });

  test('the fallback icon is chosen per kind, not one for all', () {
    expect(fallbackLinkIcon(LinkKind.website), Icons.open_in_browser);
    expect(fallbackLinkIcon(LinkKind.other), Icons.link);
    // A kind whose favicon failed to load still gets the neutral mark rather
    // than the browser glyph, which would claim it is a plain website.
    expect(fallbackLinkIcon(LinkKind.bandcamp), Icons.link);
  });
}
