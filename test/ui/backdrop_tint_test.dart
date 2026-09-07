import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
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
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          artStoreProvider.overrideWithValue(ArtStore(artRoot)),
          themeSettingsProvider.overrideWith(() => _FixedTheme(style)),
          backdropFollowsPaletteProvider.overrideWith(() => _Flag(follows)),
        ],
        child: MaterialApp(
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
}

/// The appearance settings, fixed to one palette style.
class _FixedTheme extends ThemeSettings {
  _FixedTheme(this.style);

  final PaletteVariant style;

  @override
  ThemePreference build() => ThemePreference(variant: style);
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
