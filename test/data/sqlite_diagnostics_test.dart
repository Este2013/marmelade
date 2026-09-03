import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/sqlite_diagnostics.dart';
import 'package:sqlite3/common.dart';

/// Telling `SQLITE_CORRUPT` apart from an ordinary query failure, which is
/// what decides whether `SearchIndexer` tries to self-heal or just rethrows.
///
/// `DriftRemoteException` itself is not covered here -- it only has a
/// private constructor, built by drift's own isolate machinery when a query
/// running on the background isolate throws -- but the unwrapping it needs
/// is a one-line ternary; what matters is getting the classification right
/// once the real [SqliteException] is in hand, which these do cover.
void main() {
  group('isDatabaseCorruption', () {
    test('is true for SQLITE_CORRUPT', () {
      final error = SqliteException(
        extendedResultCode: SqlError.SQLITE_CORRUPT,
        message: 'database disk image is malformed',
        causingStatement: 'INSERT INTO search_trigrams ...',
      );
      expect(isDatabaseCorruption(error), isTrue);
    });

    test('is true for an extended code whose base is SQLITE_CORRUPT', () {
      // SQLITE_CORRUPT_VTAB: an extended result code for SQLITE_CORRUPT
      // specific to virtual tables, e.g. an FTS5 index -- resultCode masks
      // off the low byte, so this should still classify as corruption.
      final error = SqliteException(
        extendedResultCode: 267,
        message: 'malformed virtual table',
      );
      expect(isDatabaseCorruption(error), isTrue);
    });

    test('is false for an unrelated SqliteException', () {
      final error = SqliteException(
        extendedResultCode: SqlError.SQLITE_CONSTRAINT,
        message: 'UNIQUE constraint failed',
      );
      expect(isDatabaseCorruption(error), isFalse);
    });

    test('is false for a non-SQLite error', () {
      expect(isDatabaseCorruption(StateError('unrelated')), isFalse);
    });
  });

  group('describeDatabaseError', () {
    test('surfaces the SQLite code, message and causing statement', () {
      final error = SqliteException(
        extendedResultCode: SqlError.SQLITE_CORRUPT,
        message: 'database disk image is malformed',
        causingStatement: 'INSERT INTO search_trigrams ...',
      );
      final fields = describeDatabaseError(error);
      expect(fields['sqliteCode'], SqlError.SQLITE_CORRUPT);
      expect(fields['sqliteMessage'], 'database disk image is malformed');
      expect(fields['causingStatement'], 'INSERT INTO search_trigrams ...');
    });

    test('omits the causing statement when there is none', () {
      final error = SqliteException(
        extendedResultCode: SqlError.SQLITE_CORRUPT,
        message: 'database disk image is malformed',
      );
      expect(
        describeDatabaseError(error).containsKey('causingStatement'),
        isFalse,
      );
    });

    test('is empty for a non-SQLite error', () {
      expect(describeDatabaseError(StateError('unrelated')), isEmpty);
    });
  });
}
