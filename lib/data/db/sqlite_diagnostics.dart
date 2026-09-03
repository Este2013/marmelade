import 'package:drift/drift.dart' show CouldNotRollBackException;
import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:sqlite3/common.dart' show SqlError, SqliteException;

/// Peels off the wrapper layers a database error can arrive in, down to
/// whatever sqlite3 itself threw.
///
/// Two layers, and either can be absent: the database runs on drift's
/// background isolate (see `MarmeladeDatabase.open`), so an error raised
/// there usually arrives back here as a [DriftRemoteException] around the
/// real thing. And when a statement fails mid-transaction, drift's own
/// rollback can *itself* fail -- SQLite considers the transaction already
/// gone once a COMMIT fails corrupt, so the ROLLBACK it automatically tries
/// next has nothing left to roll back. That second failure is what actually
/// gets thrown, as a [CouldNotRollBackException] whose `cause` is the
/// original error -- not its `exception`, which is the unrelated "no
/// transaction is active" complaint from the rollback attempt. Checking only
/// the outer exception here previously meant a corrupted commit inside a
/// transaction was never recognised as corruption at all.
Object _unwrap(Object error) {
  var current = error;
  while (true) {
    if (current is DriftRemoteException) {
      current = current.remoteCause;
    } else if (current is CouldNotRollBackException) {
      current = current.cause;
    } else {
      return current;
    }
  }
}

/// Whether [error] is, or wraps, `SQLITE_CORRUPT` -- an on-disk structure
/// that no longer parses, rather than a bug in the query that hit it.
bool isDatabaseCorruption(Object error) {
  final cause = _unwrap(error);
  return cause is SqliteException &&
      cause.resultCode == SqlError.SQLITE_CORRUPT;
}

/// Diagnostic fields worth logging for a database error, unwrapped from
/// whatever isolate boundary or failed rollback it came through.
Map<String, Object?> describeDatabaseError(Object error) {
  final cause = _unwrap(error);
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
