import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/theme/app_theme.dart';
import 'package:marmelade/app/theme/theme_settings.dart';

/// Where the palette's seed colour comes from.
///
/// One small function decides the whole app's colour, and each of its
/// branches has a fallback that only matters on somebody's machine: a Windows
/// that will not report an accent, a queue with nothing in it.
void main() {
  const windows = Color(0xFF0078D4);
  const artwork = Color(0xFF00E5FF);
  const picked = Color(0xFF7C4DFF);

  test('the Windows accent, when that is what was asked for', () {
    const preference = ThemePreference(accent: AccentSource.system);

    expect(preference.seed(windows), windows);
  });

  test('and the brand colour when Windows will not say', () {
    // Null often enough -- no accent set, a remote session, an older Windows
    // -- that "system" has to mean "system, or ours".
    const preference = ThemePreference(accent: AccentSource.system);

    expect(preference.seed(null), marmeladeSeed);
  });

  test('a colour picked by hand', () {
    const preference = ThemePreference(
      accent: AccentSource.custom,
      customAccent: picked,
    );

    expect(preference.seed(windows), picked);
  });

  group('taken from what is playing', () {
    const preference = ThemePreference(accent: AccentSource.adaptive);

    test('the artwork wins over everything else', () {
      expect(preference.seed(windows, nowPlaying: artwork), artwork);
    });

    test('falls back the way "system" does with nothing loaded', () {
      // An empty queue has no colour to offer, and the app still has to be
      // some colour.
      expect(preference.seed(windows), windows);
      expect(preference.seed(null), marmeladeSeed);
    });

    test('is not what the other sources use', () {
      // A track's colours must not leak into a palette somebody pinned.
      for (final source in const [
        AccentSource.system,
        AccentSource.custom,
      ]) {
        expect(
          ThemePreference(accent: source, customAccent: picked)
              .seed(windows, nowPlaying: artwork),
          isNot(artwork),
          reason: source.name,
        );
      }
    });
  });

  test('every source is offered and named', () {
    // The settings page lists them by hand; a new one added here without a
    // chip there would be unreachable. Three now: the brand colour stopped
    // being a source of its own -- it is the fallback, and the first swatch.
    expect(AccentSource.values, hasLength(3));
    for (final source in AccentSource.values) {
      expect(source.label, isNotEmpty, reason: source.name);
    }
  });

  contrastTests();
  variantTests();

  test('an unknown stored value reads as the default, not a crash', () {
    // Downgrading after picking "adaptive" leaves this in the database.
    expect(AccentSource.of('adaptive'), AccentSource.adaptive);
    expect(AccentSource.of('something-else-entirely'), AccentSource.system);
    // Anyone who had picked the brand colour lands on the Windows accent,
    // and the same orange is still one swatch away.
    expect(AccentSource.of('brand'), AccentSource.system);
  });
}

/// The contrast setting.
///
/// Material's own `contrastLevel`, so what is worth testing here is not the
/// algorithm but the two things this project decided: that the levels really
/// are ordered, and that the softest one stays readable. Measured rather than
/// asserted from the parameter, because the numbers are the whole point.
void contrastTests() {
  double ratio(Color a, Color b) {
    final l1 = a.computeLuminance(), l2 = b.computeLuminance();
    final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
    return (hi + 0.05) / (lo + 0.05);
  }

  ColorScheme schemeFor(ContrastLevel level, Brightness brightness) =>
      ColorScheme.fromSeed(
        seedColor: marmeladeSeed,
        brightness: brightness,
        contrastLevel: level.value,
      );

  group('contrast', () {
    test('each level really is a step up on the one below', () {
      for (final brightness in Brightness.values) {
        double weakest(ContrastLevel level) {
          final s = schemeFor(level, brightness);
          final pairs = [
            ratio(s.onSurface, s.surface),
            ratio(s.onSurfaceVariant, s.surface),
            ratio(s.onPrimary, s.primary),
          ];
          return pairs.reduce((a, b) => a < b ? a : b);
        }

        var previous = 0.0;
        for (final level in ContrastLevel.values) {
          final measured = weakest(level);
          expect(measured, greaterThan(previous),
              reason: '${level.name} in ${brightness.name}');
          previous = measured;
        }
      }
    });

    test('even the softest keeps body text above the accessibility floor',
        () {
      // Why muted is -0.5 and not the -1.0 the parameter allows: at -1.0
      // secondary text on surface measures 4.07:1 in the light theme, under
      // the 4.5:1 body text is meant to clear.
      for (final brightness in Brightness.values) {
        final s = schemeFor(ContrastLevel.muted, brightness);
        expect(ratio(s.onSurface, s.surface), greaterThan(4.5),
            reason: brightness.name);
        expect(ratio(s.onSurfaceVariant, s.surface), greaterThan(4.5),
            reason: brightness.name);
      }
    });

    test('the default is normal, so nothing moved for anyone who never '
        'touches it', () {
      expect(const ThemePreference().contrast, ContrastLevel.normal);
      expect(ContrastLevel.normal.value, 0);
    });

    test('an unknown stored value reads as the default', () {
      expect(ContrastLevel.of('muted'), ContrastLevel.muted);
      expect(ContrastLevel.of('ludicrous'), ContrastLevel.normal);
    });
  });
}

/// The palette styles.
///
/// Nine ways to turn one seed into a scheme, eight of them Material's own and
/// one this project added. What is worth asserting is the one we built and
/// the promise the others make: that choosing a style changes the palette
/// without breaking the contrast floor underneath it.
void variantTests() {
  ColorScheme schemeFor(PaletteVariant style, Brightness brightness) =>
      buildTheme(
        seed: const Color(0xFFE8730C),
        brightness: brightness,
        variant: style.variant,
        swapAccents: style.swapsAccents,
      ).colorScheme;

  group('palette style', () {
    test('swapped really does trade the two accent groups', () {
      // What was asked for: the roles change places, group for group.
      final plain = schemeFor(PaletteVariant.tonalSpot, Brightness.dark);
      final swapped = schemeFor(PaletteVariant.swapped, Brightness.dark);

      expect(swapped.primary, plain.tertiary);
      expect(swapped.tertiary, plain.primary);
      expect(swapped.onPrimary, plain.onTertiary);
      expect(swapped.primaryContainer, plain.tertiaryContainer);
      expect(swapped.onPrimaryContainer, plain.onTertiaryContainer);
      expect(swapped.tertiaryFixed, plain.primaryFixed);
    });

    test('and leaves everything else where it was', () {
      // Only the accents trade. Surfaces moving too would be a different
      // theme, not a swap.
      final plain = schemeFor(PaletteVariant.tonalSpot, Brightness.dark);
      final swapped = schemeFor(PaletteVariant.swapped, Brightness.dark);

      expect(swapped.surface, plain.surface);
      expect(swapped.onSurface, plain.onSurface);
      expect(swapped.secondary, plain.secondary);
      expect(swapped.error, plain.error);
      expect(swapped.inversePrimary, plain.inversePrimary);
    });

    test('a swapped accent still reads against what sits on it', () {
      // The reason the groups move together: a swapped primary with an
      // unswapped onPrimary is text on the wrong colour.
      for (final brightness in Brightness.values) {
        final s = schemeFor(PaletteVariant.swapped, brightness);
        expect(_ratio(s.onPrimary, s.primary), greaterThan(4.5),
            reason: brightness.name);
        expect(_ratio(s.onTertiary, s.tertiary), greaterThan(4.5),
            reason: brightness.name);
      }
    });

    test('every style keeps body text readable', () {
      // Including the playful ones, and monochrome, which has no colour to
      // hide behind.
      for (final style in PaletteVariant.values) {
        for (final brightness in Brightness.values) {
          final s = schemeFor(style, brightness);
          expect(_ratio(s.onSurface, s.surface), greaterThan(4.5),
              reason: '${style.name} in ${brightness.name}');
        }
      }
    });

    test('faithful keeps a muted accent muted, where the default boosts it',
        () {
      // The whole reason that style is offered, and it only shows on a muted
      // colour: the default clamps chroma to a fixed value, so a washed-out
      // grey-blue comes out a confident blue. Measured on this seed, the
      // default gives #a1c9fd and faithful #b8c8df.
      //
      // Which also means the two are *identical* for a saturated accent --
      // the seed's own chroma is already past the clamp. Asserting they
      // always differ would be asserting something untrue.
      const muted = Color(0xFF6B7A8F);
      ColorScheme of(PaletteVariant style) => buildTheme(
            seed: muted,
            brightness: Brightness.dark,
            variant: style.variant,
            swapAccents: style.swapsAccents,
          ).colorScheme;

      final byDefault = of(PaletteVariant.tonalSpot).primary;
      final faithful = of(PaletteVariant.fidelity).primary;
      expect(faithful, isNot(byDefault));

      double chroma(Color c) {
        final hsl = HSLColor.fromColor(c);
        return hsl.saturation;
      }

      expect(chroma(faithful), lessThan(chroma(byDefault)),
          reason: 'faithful is the less saturated of the two');
    });

    test('an unknown stored style reads as the default', () {
      expect(PaletteVariant.of('swapped'), PaletteVariant.swapped);
      expect(PaletteVariant.of('content'), PaletteVariant.tonalSpot);
    });
  });
}

double _ratio(Color a, Color b) {
  final l1 = a.computeLuminance(), l2 = b.computeLuminance();
  final hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}
