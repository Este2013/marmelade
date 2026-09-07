import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:marmelade/widgets/artwork.dart';
import 'package:path/path.dart' as p;

/// What size a cover is decoded at.
///
/// Two failure modes sit either side of this number, and both are invisible
/// in a screenshot of a still grid. Too small and every tile is a blurred
/// upscale; too large and forty covers of 1400 pixels each is 300 MB of
/// bitmaps for one screen, which blows the image cache and leaves it
/// re-decoding while you scroll.
void main() {
  late Directory artRoot;
  const stored = 'ab/cover.png';

  setUp(() {
    artRoot = Directory.systemTemp.createTempSync('marmelade_decode_');
    final file = File(p.join(artRoot.path, 'ab', 'cover.png'))
      ..parent.createSync(recursive: true);
    file.writeAsBytesSync(_onePixelPng);
  });
  tearDown(() {
    try {
      artRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may hold the decode open a moment longer.
    }
  });

  Future<int?> decodeWidthFor(
    WidgetTester tester, {
    required double side,
    required double devicePixelRatio,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [artStoreProvider.overrideWithValue(ArtStore(artRoot))],
        child: MediaQuery(
          data: MediaQueryData(devicePixelRatio: devicePixelRatio),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: side,
                height: side,
                child: const Artwork(storedPath: stored),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    return (image.image as ResizeImage).width;
  }

  testWidgets('follows the display, not the logical size', (tester) async {
    // The machine this was reported on runs at 1.25. Decoding 180 pixels for
    // a box that is 225 device pixels wide is a quarter of the detail thrown
    // away before anything is drawn.
    final at1 = await decodeWidthFor(tester, side: 180, devicePixelRatio: 1);
    final at125 =
        await decodeWidthFor(tester, side: 180, devicePixelRatio: 1.25);

    expect(at125, greaterThan(at1!));
    expect(at125! / at1, closeTo(1.25, 0.02));
  });

  testWidgets('leaves room for the hover lift', (tester) async {
    // Both grids scale a cover by 3 to 4 per cent on hover. Decoded to
    // exactly its box, a tile is resampled the moment you point at it, which
    // is what made a hovered tile look softer than its neighbours.
    const side = 180.0;
    const dpr = 1.25;
    final decoded = await decodeWidthFor(
      tester,
      side: side,
      devicePixelRatio: dpr,
    );

    expect(decoded, greaterThan(side * dpr * 1.04),
        reason: 'covers the larger of the two lifts');
  });

  testWidgets('but not extravagantly', (tester) async {
    // The other failure mode. Headroom is for a hover lift, not a licence to
    // decode a poster for a thumbnail.
    const side = 180.0;
    const dpr = 1.25;
    final decoded = await decodeWidthFor(
      tester,
      side: side,
      devicePixelRatio: dpr,
    );

    expect(decoded, lessThan(side * dpr * 1.2));
  });

  testWidgets('and never past the cap, whatever the screen', (tester) async {
    // A 4K display and a full-window cover would otherwise ask for a decode
    // larger than any source image actually is.
    final decoded =
        await decodeWidthFor(tester, side: 2000, devicePixelRatio: 3);

    expect(decoded, maxDecodeWidth);
  });
}

/// The smallest valid PNG, so there is a real file to resolve.
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
