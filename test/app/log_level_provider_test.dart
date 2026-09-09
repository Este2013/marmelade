import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/core/logging/app_log.dart';

/// The "Session log" level setting: what backs the dropdown in Settings.
///
/// Persistence itself is [StoredString] (see app/providers.dart), the same
/// mechanism every other simple setting already uses and is already
/// exercised elsewhere. What is specific to this setting is [LogLevel.of]:
/// a stored value has to round-trip, and an unrecognised or missing one has
/// to fall back rather than throw, since it is read once at startup before
/// there is any way to correct a bad value short of editing the database.
void main() {
  test('every level round-trips through its own name', () {
    for (final level in LogLevel.values) {
      expect(LogLevel.of(level.name), level);
    }
  });

  test('an unrecognised value falls back to debug by default', () {
    expect(LogLevel.of('made-up-level'), LogLevel.debug);
  });

  test('a caller can choose a different fallback', () {
    expect(LogLevel.of('made-up-level', fallback: LogLevel.error), LogLevel.error);
  });

  test('an empty string falls back rather than matching nothing badly', () {
    expect(LogLevel.of(''), LogLevel.debug);
  });
}
