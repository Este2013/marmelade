import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:path/path.dart' as p;

/// Closing the app down.
///
/// This has teeth because of what the alternative cost: `dispose()` was two
/// plain awaits, an audio device that never finished deinitialising meant the
/// database was never closed, the window then never closed either -- the app
/// "would not close" -- and killing it left the write-ahead log unfolded,
/// which is how this library ended up with a page claimed by two b-trees at
/// once. A hang on the way out is not a slow shutdown; it is data loss with a
/// delay on it.
void main() {
  group('closeQuietly', () {
    test('gives up on a step that never finishes', () async {
      // The actual bug: no timeout, so `await` meant forever.
      final started = DateTime.now();
      await closeQuietly(
        'something stuck',
        () => Completer<void>().future,
        within: const Duration(milliseconds: 100),
      );

      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 2)),
        reason: 'it returned instead of waiting forever',
      );
    });

    test('swallows a step that throws', () async {
      // On the way out there is nothing left to show an error to.
      await expectLater(
        closeQuietly('something broken', () async => throw StateError('nope')),
        completes,
      );
    });

    test('lets a step that works simply finish', () async {
      var ran = false;
      await closeQuietly('something fine', () async => ran = true);
      expect(ran, isTrue);
    });

    test('a step that hangs does not strand the one after it', () async {
      // The whole point. The database close is last, and it is the step that
      // protects the file -- it has to run even when the audio engine is
      // wedged.
      var reachedTheNextStep = false;

      await closeQuietly(
        'the wedged one',
        () => Completer<void>().future,
        within: const Duration(milliseconds: 50),
      );
      await closeQuietly('the important one', () async {
        reachedTheNextStep = true;
      });

      expect(reachedTheNextStep, isTrue);
    });
  });

  group('checkpoint', () {
    late Directory directory;

    setUp(() => directory = Directory.systemTemp.createTempSync('marmelade_wal_'));
    tearDown(() {
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can still hold the file briefly; the temp directory
        // outlives the run either way.
      }
    });

    test('folds the write-ahead log back into the database file', () async {
      final path = p.join(directory.path, 'library.db');
      final db = await MarmeladeDatabase.open(path);
      addTearDown(db.close);

      // Enough writes to put something in the log rather than the file.
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (var i = 0; i < 200; i++) {
        await db.customStatement(
          'INSERT INTO settings (key, value, value_type, updated_at) '
          'VALUES (?, ?, ?, ?)',
          ['k$i', 'v$i', 'string', now],
        );
      }
      final wal = File('$path-wal');
      expect(wal.existsSync(), isTrue, reason: 'WAL mode is on');
      expect(wal.lengthSync(), greaterThan(0));

      await db.checkpoint();

      // The log the app was leaving behind had grown to 8.8 MB across a
      // session that was killed rather than closed; emptied here, the writes
      // are in the database file itself and nothing depends on a sidecar.
      expect(wal.lengthSync(), 0, reason: 'the log was folded back and emptied');
    });
  });
}
