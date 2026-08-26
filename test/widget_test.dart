import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/theme/app_theme.dart';
import 'package:flutter/material.dart';

void main() {
  test('theme derives a usable scheme from the seed colour', () {
    for (final brightness in Brightness.values) {
      final theme = buildTheme(seed: marmeladeSeed, brightness: brightness);
      expect(theme.useMaterial3, isTrue);
      expect(theme.colorScheme.brightness, brightness);
      // Guard against a scheme that would render text invisible.
      expect(theme.colorScheme.onSurface, isNot(theme.colorScheme.surface));
    }
  });
}
