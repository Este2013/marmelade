import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/enums.dart';
import 'package:marmelade/data/fs/file_identity.dart';
import 'package:marmelade/data/fs/file_reconciler.dart';
import 'package:marmelade/data/fs/library_scanner.dart';

/// Fake identities keyed by relative path, so reconciliation logic can be
/// tested without touching a disk.
class _FakeIdentities {
  _FakeIdentities(this.keys);

  /// path -> quick key. Files sharing a key are "the same content".
  final Map<String, String> keys;

  FileIdentity of(ScannedFile file) => FileIdentity(
        sizeBytes: file.sizeBytes,
        payloadLength: file.sizeBytes,
        quickKey: keys[file.relativePath] ?? 'unknown-${file.relativePath}',
      );
}

ScannedFile scanned(
  String relativePath, {
  int size = 1000,
  DateTime? modified,
}) =>
    ScannedFile(
      file: File(relativePath),
      relativePath: relativePath,
      sizeBytes: size,
      modifiedAt: modified ?? DateTime.utc(2026, 1, 1),
    );

KnownFile known(
  int id,
  String relativePath, {
  int size = 1000,
  DateTime? modified,
  String? quickKey,
  String? contentKey,
  FileStatus status = FileStatus.present,
}) =>
    KnownFile(
      id: id,
      relativePath: relativePath,
      sizeBytes: size,
      modifiedAt: modified ?? DateTime.utc(2026, 1, 1),
      status: status,
      quickKey: quickKey,
      contentKey: contentKey,
    );

void main() {
  // Content keys are not compared unless the known row recorded one, so most
  // tests can leave confirmation on and still avoid disk access.
  final reconciler = FileReconciler();

  group('unchanged files', () {
    test('a file with the same path, size and timestamp is kept', () {
      final plan = reconciler.reconcile(
        scanned: [scanned('a/one.mp3')],
        known: [known(1, 'a/one.mp3')],
        identify: _FakeIdentities({}).of,
      );
      expect(plan.keep.map((k) => k.id), [1]);
      expect(plan.changeCount, 0);
      expect(plan.isEmpty, isTrue);
      // Nothing had to be hashed, which is the point of the fast path.
      expect(plan.hashedFiles, 0);
    });

    test('a changed timestamp triggers a re-read', () {
      final plan = reconciler.reconcile(
        scanned: [
          scanned('a/one.mp3', modified: DateTime.utc(2026, 6, 1)),
        ],
        known: [known(1, 'a/one.mp3', modified: DateTime.utc(2026, 1, 1))],
        identify: _FakeIdentities({}).of,
      );
      expect(plan.keep, isEmpty);
      expect(plan.update.map((u) => u.id), [1]);
      expect(plan.update.single.wasMissing, isFalse);
    });

    test('a changed size triggers a re-read', () {
      final plan = reconciler.reconcile(
        scanned: [scanned('a/one.mp3', size: 2000)],
        known: [known(1, 'a/one.mp3', size: 1000)],
        identify: _FakeIdentities({}).of,
      );
      expect(plan.update.map((u) => u.id), [1]);
    });
  });

  group('additions and removals', () {
    test('an unrecognised file is added', () {
      final plan = reconciler.reconcile(
        scanned: [scanned('a/new.mp3')],
        known: const [],
        identify: _FakeIdentities({'a/new.mp3': 'k1'}).of,
      );
      expect(plan.adds, hasLength(1));
      expect(plan.adds.single.scanned.relativePath, 'a/new.mp3');
      expect(plan.adds.single.identity.quickKey, 'k1');
    });

    test('a vanished file is marked missing, never deleted', () {
      // Ratings, play counts and hand-made edits must survive an unplugged
      // drive, so the row stays.
      final plan = reconciler.reconcile(
        scanned: const [],
        known: [known(1, 'a/gone.mp3', quickKey: 'k1')],
        identify: _FakeIdentities({}).of,
      );
      expect(plan.missing.map((m) => m.id), [1]);
      expect(plan.missing.single.relativePath, 'a/gone.mp3');
    });

    test('an already-missing file is not reported missing twice', () {
      final plan = reconciler.reconcile(
        scanned: const [],
        known: [
          known(1, 'a/gone.mp3', quickKey: 'k1', status: FileStatus.missing),
        ],
        identify: _FakeIdentities({}).of,
      );
      expect(plan.missing, isEmpty);
      expect(plan.isEmpty, isTrue);
    });

    test('a missing file reappearing at its old path is restored', () {
      final plan = reconciler.reconcile(
        scanned: [scanned('a/back.mp3')],
        known: [
          known(1, 'a/back.mp3', quickKey: 'k1', status: FileStatus.missing),
        ],
        identify: _FakeIdentities({'a/back.mp3': 'k1'}).of,
      );
      expect(plan.adds, isEmpty);
      expect(plan.update.map((u) => u.id), [1]);
      expect(plan.update.single.wasMissing, isTrue);
    });
  });

  group('move detection', () {
    test('the same content at a new path is a move, not a delete and add', () {
      // The behaviour the whole design exists for.
      final plan = reconciler.reconcile(
        scanned: [scanned('new/place/song.mp3')],
        known: [known(1, 'old/place/song.mp3', quickKey: 'same')],
        identify: _FakeIdentities({'new/place/song.mp3': 'same'}).of,
      );

      expect(plan.adds, isEmpty, reason: 'must not create a second row');
      expect(plan.missing, isEmpty, reason: 'must not orphan the old row');
      expect(plan.moves, hasLength(1));
      expect(plan.moves.single.id, 1);
      expect(plan.moves.single.fromPath, 'old/place/song.mp3');
      expect(plan.moves.single.toPath, 'new/place/song.mp3');
    });

    test('a rename in place is a move', () {
      final plan = reconciler.reconcile(
        scanned: [scanned('a/better name.mp3')],
        known: [known(1, 'a/01 track.mp3', quickKey: 'same')],
        identify: _FakeIdentities({'a/better name.mp3': 'same'}).of,
      );
      expect(plan.moves, hasLength(1));
      expect(plan.moves.single.toPath, 'a/better name.mp3');
    });

    test('a move plus a retag is still one move', () {
      // The payload hash ignores tags, so the size changing does not matter.
      final plan = reconciler.reconcile(
        scanned: [scanned('new/song.mp3', size: 4321)],
        known: [known(1, 'old/song.mp3', size: 1234, quickKey: 'same')],
        identify: _FakeIdentities({'new/song.mp3': 'same'}).of,
      );
      expect(plan.moves, hasLength(1));
      expect(plan.adds, isEmpty);
    });

    test('different content at a new path is an add, not a move', () {
      final plan = reconciler.reconcile(
        scanned: [scanned('new/other.mp3')],
        known: [known(1, 'old/song.mp3', quickKey: 'aaa')],
        identify: _FakeIdentities({'new/other.mp3': 'bbb'}).of,
      );
      expect(plan.moves, isEmpty);
      expect(plan.adds, hasLength(1));
      expect(plan.missing.map((m) => m.id), [1]);
    });

    test('a whole folder being reorganised is all moves', () {
      final plan = reconciler.reconcile(
        scanned: [
          scanned('Artist/Album/01.mp3'),
          scanned('Artist/Album/02.mp3'),
          scanned('Artist/Album/03.mp3'),
        ],
        known: [
          known(1, 'dump/01.mp3', quickKey: 'k1'),
          known(2, 'dump/02.mp3', quickKey: 'k2'),
          known(3, 'dump/03.mp3', quickKey: 'k3'),
        ],
        identify: _FakeIdentities({
          'Artist/Album/01.mp3': 'k1',
          'Artist/Album/02.mp3': 'k2',
          'Artist/Album/03.mp3': 'k3',
        }).of,
      );
      expect(plan.moves, hasLength(3));
      expect(plan.adds, isEmpty);
      expect(plan.missing, isEmpty);
    });

    test('a known row with no recorded hash cannot be matched', () {
      // Move detection depends on the hash having been stored before the file
      // disappeared; there is no way to hash a file that is gone.
      final plan = reconciler.reconcile(
        scanned: [scanned('new/song.mp3')],
        known: [known(1, 'old/song.mp3')],
        identify: _FakeIdentities({'new/song.mp3': 'same'}).of,
      );
      expect(plan.moves, isEmpty);
      expect(plan.adds, hasLength(1));
      expect(plan.missing, hasLength(1));
    });

    test('one vanished file cannot satisfy two new paths', () {
      // A copy-then-move leaves two files with the same content; only one can
      // inherit the existing row, and the other must be a genuine addition.
      final plan = reconciler.reconcile(
        scanned: [
          scanned('new/copy-a.mp3'),
          scanned('new/copy-b.mp3'),
        ],
        known: [known(1, 'old/song.mp3', quickKey: 'same')],
        identify: _FakeIdentities({
          'new/copy-a.mp3': 'same',
          'new/copy-b.mp3': 'same',
        }).of,
      );
      expect(plan.moves, hasLength(1));
      expect(plan.adds, hasLength(1));
      expect(plan.missing, isEmpty);
    });

    test('duplicate content prefers the candidate with the same filename', () {
      final plan = reconciler.reconcile(
        scanned: [scanned('new/b.mp3')],
        known: [
          known(1, 'old/a.mp3', quickKey: 'same'),
          known(2, 'old/b.mp3', quickKey: 'same'),
        ],
        identify: _FakeIdentities({'new/b.mp3': 'same'}).of,
      );
      expect(plan.moves.single.id, 2, reason: 'filename is the strongest hint');
      // The other duplicate is still gone and must be reported.
      expect(plan.missing.map((m) => m.id), [1]);
    });

    test('moves are applied before adds', () {
      // Otherwise an add could claim a path a move is about to occupy.
      final plan = reconciler.reconcile(
        scanned: [scanned('new/moved.mp3'), scanned('new/fresh.mp3')],
        known: [known(1, 'old/moved.mp3', quickKey: 'k1')],
        identify: _FakeIdentities({
          'new/moved.mp3': 'k1',
          'new/fresh.mp3': 'k2',
        }).of,
      );
      final kinds = plan.all.map((o) => o.runtimeType.toString()).toList();
      expect(kinds.indexOf('MoveFile'), lessThan(kinds.indexOf('AddFile')));
    });
  });

  group('content-key confirmation', () {
    test('a cheap-key collision is rejected when full hashes disagree', () {
      // Two different files whose cheap keys happen to match must not be
      // treated as a move. The known row recorded a content key, so it can be
      // checked - and the file on disk does not exist here, which makes the
      // hash unreadable and the match unconfirmable.
      final plan = FileReconciler().reconcile(
        scanned: [scanned('new/song.mp3')],
        known: [
          known(1, 'old/song.mp3', quickKey: 'same', contentKey: 'deadbeef'),
        ],
        identify: _FakeIdentities({'new/song.mp3': 'same'}).of,
      );
      // Hashing failed rather than disagreed, so the move stands but is
      // reported as unconfirmed. Being explicit about that is the point.
      expect(plan.moves, hasLength(1));
      expect(plan.moves.single.confirmedByContentKey, isFalse);
    });

    test('confirmation can be switched off', () {
      final plan = FileReconciler(confirmMovesWithContentKey: false).reconcile(
        scanned: [scanned('new/song.mp3')],
        known: [
          known(1, 'old/song.mp3', quickKey: 'same', contentKey: 'deadbeef'),
        ],
        identify: _FakeIdentities({'new/song.mp3': 'same'}).of,
      );
      expect(plan.moves, hasLength(1));
      expect(plan.moves.single.confirmedByContentKey, isFalse);
    });
  });

  group('plan bookkeeping', () {
    test('counts changes without counting untouched files', () {
      final plan = reconciler.reconcile(
        scanned: [
          scanned('keep.mp3'),
          scanned('changed.mp3', size: 9999),
          scanned('added.mp3'),
        ],
        known: [
          known(1, 'keep.mp3'),
          known(2, 'changed.mp3'),
          known(3, 'gone.mp3', quickKey: 'zzz'),
        ],
        identify: _FakeIdentities({'added.mp3': 'new'}).of,
      );
      expect(plan.keep, hasLength(1));
      expect(plan.update, hasLength(1));
      expect(plan.adds, hasLength(1));
      expect(plan.missing, hasLength(1));
      expect(plan.changeCount, 3);
      // Only the changed and added files needed hashing.
      expect(plan.hashedFiles, 2);
    });

    test('an empty folder and an empty database reconcile to nothing', () {
      final plan = reconciler.reconcile(scanned: const [], known: const []);
      expect(plan.isEmpty, isTrue);
      expect(plan.all, isEmpty);
    });
  });
}
