import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/app/theme/app_theme.dart';
import 'package:marmelade/app/theme/theme_settings.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:marmelade/widgets/artwork.dart';
import 'package:path/path.dart' as p;

/// Whether the blurred artwork behind a page turns with the palette.
///
/// The setting exists because this is a taste, so both answers have to work:
/// on, a rotated palette takes the ambiance with it; off, the picture is the
/// picture. And with a style that does not rotate anything, the filter must
/// not be in the tree at all -- a colour matrix over a full-bleed image is
/// not free.
void main() {
  late MarmeladeDatabase db;
  late Directory artRoot;
  late String storedPath;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    artRoot = Directory.systemTemp.createTempSync('marmelade_backdrop_');
    // A real file, since the widget only draws a picture when one exists.
    storedPath = p.join('ab', 'cover.png');
    final file = File(p.join(artRoot.path, storedPath));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(_onePixelPng);
  });
  tearDown(() async {
    await db.close();
    try {
      artRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold the decode open.
    }
  });

  Future<void> pump(
    WidgetTester tester, {
    required PaletteVariant style,
    required bool follows,
    AccentSource accent = AccentSource.system,
    // The picture's own hue, normally measured by decoding it -- which a
    // widget test's binding will not complete, so it is supplied here. 220
    // is a blue, and expressive lands on 120 from the seed below, which is
    // the hundred degrees this is about.
    double? pictureHue = 220,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          artStoreProvider.overrideWithValue(ArtStore(artRoot)),
          themeSettingsProvider.overrideWith(() => _FixedTheme(style, accent)),
          backdropFollowsPaletteProvider.overrideWith(() => _Flag(follows)),
          artworkHueProvider(storedPath).overrideWith((ref) async => pictureHue),
        ],
        child: MaterialApp(
          // Built from the style, the way main.dart builds it: the widget
          // measures against the palette actually in front of the picture,
          // so a test with the stock theme would be measuring nothing.
          theme: buildTheme(
            seed: const Color(0xFF4285F4),
            brightness: Brightness.light,
            variant: style.variant,
            hueShift: style.hueShift,
          ),
          home: Scaffold(body: ArtworkBackdrop(storedPath: storedPath)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  Finder tint() => find.descendant(
        of: find.byType(ArtworkBackdrop),
        matching: find.byType(ColorFiltered),
      );

  testWidgets('turns the picture for a style that turns the palette',
      (tester) async {
    await pump(tester, style: PaletteVariant.swapped, follows: true);

    expect(tint(), findsOne);
  });

  testWidgets('leaves it alone when the setting is off', (tester) async {
    await pump(tester, style: PaletteVariant.swapped, follows: false);

    expect(tint(), findsNothing);
  });

  testWidgets('costs nothing for a style that turns nothing',
      (tester) async {
    // No filter in the tree at all, rather than an identity one: a colour
    // matrix over a full-bleed image is not free.
    await pump(tester, style: PaletteVariant.tonalSpot, follows: true);

    expect(tint(), findsNothing);
  });

  testWidgets('follows a style that lands on its own hue, once the palette '
      'comes from the artwork', (tester) async {
    // Expressive shifts by a table rather than a fixed angle, so there is no
    // number to follow -- only the distance between where the picture was
    // and where the palette ended up.
    await pump(
      tester,
      style: PaletteVariant.expressive,
      follows: true,
      accent: AccentSource.adaptive,
    );
    await tester.pumpAndSettle();

    expect(tint(), findsOne);
  });

  testWidgets('and leaves a greyscale sleeve alone, having no hue to turn',
      (tester) async {
    // Nothing to rotate towards or away from, and a hue read off near-grey
    // is noise.
    await pump(
      tester,
      style: PaletteVariant.expressive,
      follows: true,
      accent: AccentSource.adaptive,
      pictureHue: null,
    );
    await tester.pumpAndSettle();

    expect(tint(), findsNothing);
  });

  testWidgets('but leaves the picture alone against a fixed accent',
      (tester) async {
    // The measurement would then say how far the artwork sits from the
    // Windows accent, and turning a red sleeve blue to match a blue
    // interface throws away the one thing the backdrop is there for.
    await pump(
      tester,
      style: PaletteVariant.expressive,
      follows: true,
      accent: AccentSource.system,
    );
    await tester.pumpAndSettle();

    expect(tint(), findsNothing);
  });
}

/// The appearance settings, fixed to one palette style.
class _FixedTheme extends ThemeSettings {
  _FixedTheme(this.style, this.accent);

  final PaletteVariant style;
  final AccentSource accent;

  @override
  ThemePreference build() =>
      ThemePreference(variant: style, accent: accent);
}

class _Flag extends StoredFlag {
  _Flag(this.value) : super('test.backdrop');

  final bool value;

  @override
  bool build() => value;
}

/// The smallest valid PNG, so the widget has a real file to decode.
const _onePixelPng = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
