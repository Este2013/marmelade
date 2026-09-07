import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../app/theme/theme_settings.dart';
import 'dither_overlay.dart';
import 'hue_filter.dart';

/// Hard ceiling on decode width, in physical pixels.
///
/// Nothing in this app draws artwork larger than the now-playing view, so
/// decoding beyond this only wastes memory. It also bounds the damage from a
/// single absurdly large cover.
const maxDecodeWidth = 1200;

/// Decode width used when a widget's constraints are unbounded.
///
/// Unbounded means the parent has not decided yet, which happens inside
/// scrolling and intrinsic layouts. A modest fixed size is better than
/// full-resolution.
const _fallbackDecodeWidth = 256.0;

/// Decoded a little larger than the box it is drawn in.
///
/// Both grids lift a cover on hover -- 1.03 in Albums, 1.04 in Artists -- and
/// a bitmap decoded to exactly its box is being resampled the moment anything
/// moves it, which is what makes a hovered tile look softer than its
/// neighbours. Five per cent clears both lifts and every frame of the
/// animation in between, for about ten per cent more pixels, which on a
/// grid-sized tile is nothing.
const _scaleHeadroom = 1.05;

/// Album or artist artwork, with a placeholder when there is none.
///
/// The fallback chain itself lives in SQL (`v_track_artwork`,
/// `v_album_artwork`), so by the time a path reaches this widget it has already
/// been resolved through track, album and artist. What is left here is the last
/// resort: something that still looks deliberate when a release simply has no
/// art.
class Artwork extends ConsumerWidget {
  const Artwork({
    super.key,
    required this.storedPath,
    this.size,
    this.borderRadius = 8,
    this.fallbackSeed,
    this.fallbackIcon = Icons.album_outlined,
    this.fit = BoxFit.cover,
    this.heroTag,
  });

  /// Path within the artwork store, or null for none.
  final String? storedPath;

  /// Side length. Null fills the available space.
  final double? size;

  final double borderRadius;

  /// Text used to pick a placeholder colour, usually the album or artist name.
  ///
  /// Deriving the colour from the name means a library with no artwork still
  /// looks varied and, more usefully, each release keeps the same colour every
  /// time it is shown.
  final String? fallbackSeed;

  final IconData fallbackIcon;
  final BoxFit fit;

  /// When set, wraps the image in a [Hero] for cross-screen transitions.
  final Object? heroTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = ref.watch(artworkFileProvider(storedPath));
    final radius = BorderRadius.circular(borderRadius);

    Widget content = file == null
        ? _Placeholder(
            seed: fallbackSeed,
            icon: fallbackIcon,
            borderRadius: radius,
          )
        : ClipRRect(
            borderRadius: radius,
            // Every cover must be decoded at roughly the size it is drawn.
            // Album art is commonly 1400x1400 or larger, which is 7.8 MB
            // decoded; a grid of forty of those at full resolution is over
            // 300 MB of bitmaps for one screen, which blows past the image
            // cache and leaves it re-decoding continuously. When no explicit
            // size is given the real constraints have to be measured, because
            // guessing wrong in that direction is the difference between a
            // smooth grid and an unusable one.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final devicePixelRatio =
                    MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
                final logicalWidth = size ??
                    (constraints.hasBoundedWidth
                        ? constraints.maxWidth
                        : _fallbackDecodeWidth);
                final decodeWidth =
                    (logicalWidth * devicePixelRatio * _scaleHeadroom)
                        .round()
                        .clamp(32, maxDecodeWidth);

                return Image.file(
                  file,
                  fit: fit,
                  width: size,
                  height: size,
                  cacheWidth: decodeWidth,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (context, _, _) => _Placeholder(
                    seed: fallbackSeed,
                    icon: Icons.broken_image_outlined,
                    borderRadius: radius,
                  ),
                );
              },
            ),
          );

    if (heroTag != null) {
      // No custom flightShuttleBuilder. Returning the same widget instance for
      // the shuttle put one widget in two places in the tree at once, which
      // confuses semantics; the default shuttle handles the rounded corners
      // well enough.
      content = Hero(tag: heroTag!, child: content);
    }

    return size == null
        ? content
        : SizedBox(width: size, height: size, child: content);
  }
}

/// A coloured tile standing in for missing artwork.
class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.seed,
    required this.icon,
    required this.borderRadius,
  });

  final String? seed;
  final IconData icon;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hue = seed == null ? null : _hueFor(seed!);
    final base = hue == null
        ? scheme.surfaceContainerHighest
        : HSLColor.fromAHSL(
            1,
            hue,
            0.30,
            scheme.brightness == Brightness.dark ? 0.22 : 0.86,
          ).toColor();

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, Color.alphaBlend(scheme.surface.withValues(alpha: 0.45), base)],
        ),
      ),
      child: Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final shortest = math.min(
              constraints.hasBoundedWidth ? constraints.maxWidth : 48,
              constraints.hasBoundedHeight ? constraints.maxHeight : 48,
            );
            return Icon(
              icon,
              size: (shortest * 0.32).clamp(14.0, 64.0),
              color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
            );
          },
        ),
      ),
    );
  }

  /// A stable hue in 0..360 derived from a string.
  static double _hueFor(String value) {
    var hash = 0;
    for (final unit in value.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return (hash % 360).toDouble();
  }
}

/// A blurred, darkened copy of artwork, for use behind content.
///
/// This is what gives the now-playing view its colour: the art fills the frame
/// at whatever aspect ratio it has, and the space around it is the same image
/// blurred past recognition, so the whole screen takes on the release's palette
/// rather than sitting in a grey box.
class ArtworkBackdrop extends ConsumerWidget {
  const ArtworkBackdrop({
    super.key,
    required this.storedPath,
    this.blur = 64,
    this.overlayOpacity = 0.55,
    this.child,
  });

  final String? storedPath;
  final double blur;

  /// How much of the surface colour to lay over the blur, so foreground text
  /// stays readable on bright artwork.
  final double overlayOpacity;

  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = ref.watch(artworkFileProvider(storedPath));
    final scheme = Theme.of(context).colorScheme;

    final shift = ref.watch(backdropFollowsPaletteProvider)
        ? _shiftFor(ref, context)
        : 0.0;

    Widget picture(File image) {
      final decoded = Image.file(
        image,
        fit: BoxFit.cover,
        // A small decode is plenty: it is about to be blurred to a smear,
        // and decoding it at full size would be pure waste.
        cacheWidth: 96,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
      if (shift == 0) return decoded;
      return ColorFiltered(
        colorFilter: ColorFilter.matrix(hueRotation(shift)),
        child: decoded,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (file != null)
          picture(file)
        else
          DecoratedBox(
            decoration: BoxDecoration(color: scheme.surfaceContainerHigh),
          ),
        // A blur plus a scrim, rather than one heavy overlay: the blur carries
        // the colour, the scrim carries the contrast.
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: overlayOpacity),
            ),
          ),
        ),
        // Breaks up the banding a blur this heavy leaves in a mostly
        // one-colour cover -- see DitherOverlay's own comment. Tuned by eye
        // against a real album page: much above this and the grain reads as
        // static instead of quietly smoothing the gradient.
        const DitherOverlay(strength: 0.1),
        ?child,
      ],
    );
  }

  /// How far to turn the picture so it agrees with the palette in front of it.
  ///
  /// Two routes, because the styles move the hue two different ways. Swapped
  /// rotates the seed by a fixed angle this app applied, so the angle is
  /// known outright. The playful styles and expressive land somewhere else by
  /// a route of their own -- a table, or by abandoning the seed's hue
  /// entirely -- so the only way to know how far is to measure: compare the
  /// palette's own hue against the picture's.
  ///
  /// That measurement is only meaningful when the palette came *from* the
  /// picture. With a fixed accent it would say how far the artwork sits from
  /// the Windows accent, and turning a red sleeve blue to match a blue
  /// interface would throw away the one thing the backdrop is there for.
  double _shiftFor(WidgetRef ref, BuildContext context) {
    final preference = ref.watch(themeSettingsProvider);
    if (preference.variant.hueShift != 0) return preference.variant.hueShift;
    if (!preference.variant.movesHueItself) return 0;
    if (preference.accent != AccentSource.adaptive) return 0;

    final path = storedPath;
    if (path == null) return 0;
    final pictureHue = ref.watch(artworkHueProvider(path)).value;
    if (pictureHue == null) return 0;

    final palette = HSLColor.fromColor(Theme.of(context).colorScheme.primary);
    // A palette with no hue of its own -- monochrome, or near it -- is not
    // somewhere to turn a picture towards.
    if (palette.saturation < 0.05) return 0;

    // The short way round, so a 350-degree difference reads as -10 and the
    // filter turns the picture the way the eye expects.
    final delta = (palette.hue - pictureHue + 540) % 360 - 180;
    return delta;
  }
}
