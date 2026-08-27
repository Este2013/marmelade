import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/theme/app_theme.dart';
import 'package:marmelade/app/theme/theme_settings.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/settings_repository.dart';

/// The settings store, and what the appearance settings make of it.
///
/// Settings are read at startup and outlive the version that wrote them, so
/// the cases worth testing are the ones where what is stored is not what this
/// version expects.
void main() {
  late MarmeladeDatabase db;
  late SettingsRepository settings;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    settings = SettingsRepository(db);
  });

  tearDown(() => db.close());

  group('storing', () {
    test('a value survives a round trip, with its type', () async {
      await settings.set('a.bool', true);
      await settings.set('an.int', 42);
      await settings.set('a.string', 'hello');
      await settings.set('a.list', [1, 2, 3]);

      expect(await settings.get('a.bool', false), isTrue);
      expect(await settings.get('an.int', 0), 42);
      expect(await settings.get('a.string', ''), 'hello');
      expect(await settings.get<List<dynamic>>('a.list', const []), [1, 2, 3]);
    });

    test('an absent key is the fallback, not an error', () async {
      expect(await settings.get('never.written', 7), 7);
    });

    test('writing again replaces', () async {
      await settings.set('k', 1);
      await settings.set('k', 2);
      expect(await settings.get('k', 0), 2);
    });

    test('a value stored as the wrong type falls back', () async {
      // A settings file half-upgraded should cost the default, not the app's
      // startup.
      await settings.set('k', 'not a number');
      expect(await settings.get('k', 5), 5);
    });

    test('an int reads as a double, because JSON does that', () async {
      await settings.set('k', 1.0);
      expect(await settings.get('k', 0.0), 1.0);
    });

    test('a change reaches a watcher', () async {
      final seen = <String>[];
      final subscription =
          settings.watch('k', 'default').listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      await settings.set('k', 'changed');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      expect(seen.first, 'default');
      expect(seen.last, 'changed');
    });

    test('removing brings the fallback back', () async {
      await settings.set('k', 'value');
      await settings.remove('k');
      expect(await settings.get('k', 'gone'), 'gone');
    });
  });

  group('the appearance preference', () {
    test('system means the OS accent, or the brand when there is none', () {
      const preference = ThemePreference();
      expect(preference.seed(const Color(0xFF00FF00)), const Color(0xFF00FF00));
      // No accent set, a remote session, an older Windows: null happens.
      expect(preference.seed(null), marmeladeSeed);
    });

    test('brand ignores the OS entirely', () {
      const preference = ThemePreference(accent: AccentSource.brand);
      expect(preference.seed(const Color(0xFF00FF00)), marmeladeSeed);
    });

    test('custom uses the chosen colour', () {
      const chosen = Color(0xFF123456);
      const preference = ThemePreference(
        accent: AccentSource.custom,
        customAccent: chosen,
      );
      expect(preference.seed(const Color(0xFF00FF00)), chosen);
    });

    test('an unknown stored source reads as system', () {
      // Rather than throwing on a value written by a later version.
      expect(AccentSource.of('from-the-album-art'), AccentSource.system);
    });

    test('every offered colour builds a readable scheme in both modes', () {
      // The reason the picker is a set and not a wheel. "Readable" here is
      // Material's own contrast guarantee between a role and its "on" colour.
      for (final choice in accentChoices) {
        for (final brightness in Brightness.values) {
          final scheme = buildTheme(
            seed: choice.color,
            brightness: brightness,
          ).colorScheme;
          expect(
            _contrast(scheme.onSurface, scheme.surface),
            greaterThan(4.5),
            reason: '${choice.name} on ${brightness.name}',
          );
          expect(
            _contrast(scheme.onPrimary, scheme.primary),
            greaterThan(4.5),
            reason: '${choice.name} primary on ${brightness.name}',
          );
        }
      }
    });
  });
}

/// WCAG contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final lighter = [_luminance(a), _luminance(b)]..sort();
  return (lighter[1] + 0.05) / (lighter[0] + 0.05);
}

double _luminance(Color color) => color.computeLuminance();
