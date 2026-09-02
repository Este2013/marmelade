import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A faint grain that breaks up colour banding in a heavily blurred image.
///
/// [ArtworkBackdrop] decodes its source at a tiny size before blurring it to
/// a smear, which is cheap but leaves the blur very little real colour
/// variation to work with -- a mostly one-colour cover can come out as
/// visible stepped bands instead of a smooth gradient, because the blur is
/// still rounding to 8 bits per channel and a flat source rounds the same
/// way everywhere. A little per-pixel noise, blended in at low strength,
/// randomises where each band's rounding actually lands, which reads as
/// smooth again without visibly changing the colour -- the same trick as
/// film grain over a gradient, or dithering before quantising an image.
class DitherOverlay extends StatelessWidget {
  const DitherOverlay({super.key, this.strength = 1});

  /// How strongly the noise shows through, from 0 (off) to 1 (full).
  ///
  /// A plain constructor parameter rather than reading a provider directly:
  /// this widget has no opinion on where the value comes from, so a caller
  /// with nothing to tune can just omit it and get the original strength.
  final double strength;

  /// One tile of noise, generated once and shared by every instance: it
  /// tiles seamlessly at any size, and nobody can tell a shared tile from a
  /// freshly generated one when it is this fine-grained.
  static Future<ui.Image>? _tile;

  static Future<ui.Image> _loadTile() => _tile ??= _generate();

  static Future<ui.Image> _generate() {
    const size = 64;
    // Centred on mid-grey with a narrow spread: BlendMode.overlay treats
    // 50% grey as a no-op and darkens or lightens either side of it, so a
    // narrow spread around it is a small nudge rather than visible static.
    final random = Random(7);
    final bytes = Uint8List(size * size * 4);
    for (var i = 0; i < size * size; i++) {
      final value = 128 + random.nextInt(29) - 14;
      final offset = i * 4;
      bytes[offset] = value;
      bytes[offset + 1] = value;
      bytes[offset + 2] = value;
      bytes[offset + 3] = 255;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bytes,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Image>(
      future: _loadTile(),
      builder: (context, snapshot) {
        final image = snapshot.data;
        // Absent until the tile decodes, rather than an empty box held for
        // it: this paints nothing meaningful on its own, so there is no
        // layout to reserve.
        if (image == null || strength <= 0) return const SizedBox.shrink();
        return Positioned.fill(
          child: Opacity(
            opacity: strength.clamp(0, 1),
            child: CustomPaint(painter: _NoisePainter(image)),
          ),
        );
      },
    );
  }
}

class _NoisePainter extends CustomPainter {
  const _NoisePainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = ui.ImageShader(
      image,
      ui.TileMode.repeated,
      ui.TileMode.repeated,
      Matrix4.identity().storage,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = shader
        ..blendMode = BlendMode.overlay,
    );
  }

  // The tile never changes after it first decodes, and a repaint this
  // painter didn't ask for would just redraw identical pixels.
  @override
  bool shouldRepaint(covariant _NoisePainter oldDelegate) => false;
}
