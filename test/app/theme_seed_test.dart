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

  test('the brand colour, whatever the desktop is doing', () {
    const preference = ThemePreference(accent: AccentSource.brand);

    expect(preference.seed(windows), marmeladeSeed);
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
        AccentSource.brand,
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
    // chip there would be unreachable.
    expect(AccentSource.values, hasLength(4));
    for (final source in AccentSource.values) {
      expect(source.label, isNotEmpty, reason: source.name);
    }
  });

  test('an unknown stored value reads as the default, not a crash', () {
    // Downgrading after picking "adaptive" leaves this in the database.
    expect(AccentSource.of('adaptive'), AccentSource.adaptive);
    expect(AccentSource.of('something-else-entirely'), AccentSource.system);
  });
}
