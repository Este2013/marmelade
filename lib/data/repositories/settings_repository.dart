import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/logging/app_log.dart';
import '../db/database.dart';

/// The application's settings, as a typed key/value store.
///
/// In the database rather than a preferences file so settings, the library and
/// the debug tooling all read from one place. The value is JSON and the type is
/// recorded next to it, so a setting that changes shape between versions is a
/// decode that fails loudly rather than a string that silently means something
/// else.
class SettingsRepository {
  SettingsRepository(this.db);

  final MarmeladeDatabase db;

  /// Reads a setting, returning [fallback] when it is absent or unreadable.
  ///
  /// A stored value that no longer decodes is a settings file half-upgraded,
  /// which should cost the default rather than the app's startup.
  Future<T> get<T>(String key, T fallback) async {
    final row = await db
        .customSelect(
          'SELECT value, value_type FROM settings WHERE key = ?1',
          variables: [Variable(key)],
          readsFrom: {db.settings},
        )
        .getSingleOrNull();
    if (row == null) return fallback;
    return _decode(key, row.read<String>('value'), fallback);
  }

  /// Watches a setting, so a change reaches every screen at once.
  Stream<T> watch<T>(String key, T fallback) => db
      .customSelect(
        'SELECT value, value_type FROM settings WHERE key = ?1',
        variables: [Variable(key)],
        readsFrom: {db.settings},
      )
      .watch()
      .map((rows) {
        if (rows.isEmpty) return fallback;
        return _decode(key, rows.first.read<String>('value'), fallback);
      });

  Future<void> set<T>(String key, T value) async {
    await db.into(db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(
            key: key,
            value: jsonEncode(value),
            valueType: _typeOf(value),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
  }

  Future<void> remove(String key) async {
    await db.customUpdate(
      'DELETE FROM settings WHERE key = ?1',
      variables: [Variable(key)],
      updates: {db.settings},
      updateKind: UpdateKind.delete,
    );
  }

  /// Every setting, for the diagnostics view.
  Future<Map<String, String>> all() async {
    final rows = await db
        .customSelect('SELECT key, value FROM settings ORDER BY key')
        .get();
    return {
      for (final row in rows) row.read<String>('key'): row.read<String>('value'),
    };
  }

  T _decode<T>(String key, String encoded, T fallback) {
    try {
      final value = jsonDecode(encoded);
      if (value is T) return value;
      // An int written where a double is expected, which JSON does routinely.
      if (fallback is double && value is num) return value.toDouble() as T;
      AppLog.instance.warn(
        'a setting was stored as the wrong type',
        fields: {'key': key, 'stored': '${value.runtimeType}'},
      );
      return fallback;
    } catch (error) {
      AppLog.instance.warn(
        'a setting could not be decoded',
        fields: {'key': key, 'error': '$error'},
      );
      return fallback;
    }
  }

  static String _typeOf(Object? value) => switch (value) {
        bool() => 'bool',
        int() => 'int',
        double() => 'double',
        String() => 'string',
        _ => 'json',
      };
}

/// The keys the app stores, in one place so they cannot drift apart.
abstract final class SettingKeys {
  static const themeMode = 'appearance.themeMode';
  static const accentSource = 'appearance.accentSource';
  static const customAccent = 'appearance.customAccent';
  static const updateChannel = 'updates.channel';
  static const checkForUpdates = 'updates.checkOnStartup';
  static const lastUpdateCheck = 'updates.lastCheck';
  static const skippedVersion = 'updates.skippedVersion';
  static const changelogCache = 'changelog.cache';
  static const lastSeenVersion = 'changelog.lastSeenVersion';
}
