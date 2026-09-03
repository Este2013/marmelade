import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:sqlite3/common.dart' show SqlError, SqliteException;

/// Whether [error] is, or wraps, `SQLITE_CORRUPT` -- an on-disk structure
/// that no longer parses, rather than a bug in the query that hit it.
///
/// The database runs on drift's background isolate (see
/// `MarmeladeDatabase.open`), so an error raised there arrives back here
/// wrapped in a [DriftRemoteException]; the real [SqliteException] is its
/// [DriftRemoteException.remoteCause].
bool isDatabaseCorruption(Object error) {
  final cause = error is DriftRemoteException ? error.remoteCause : error;
  return cause is SqliteException &&
      cause.resultCode == SqlError.SQLITE_CORRUPT;
}

/// Diagnostic fields worth logging for a database error, unwrapped from
/// whatever isolate boundary it crossed.
Map<String, Object?> describeDatabaseError(Object error) {
  final cause = error is DriftRemoteException ? error.remoteCause : error;
  if (cause is SqliteException) {
    return {
      'sqliteCode': cause.extendedResultCode,
      'sqliteMessage': cause.message,
      if (cause.causingStatement != null)
        'causingStatement': cause.causingStatement,
    };
  }
  return const {};
}
