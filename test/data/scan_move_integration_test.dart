import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/enums.dart';
import 'package:marmelade/data/fs/file_identity.dart';
import 'package:marmelade/data/fs/file_reconciler.dart';
import 'package:marmelade/data/fs/library_scanner.dart';
import 'package:path/path.dart' as p;

/// End-to-end check of scan -> hash -> reconcile against a real directory
/// tree, with real files being really moved.
///
/// The unit tests use fake identities to pin down the decision logic; this one
/// exists to prove the hashing actually distinguishes and matches real audio.
String get _fixtureDir =>
    Platform.environment['MARMELADE_FIXTURES'] ??
    r'C:\Users\makrofon\Music\testZiks\_marmelade_fixtures';

void main() {
  final fixtures = Directory(_fixtureDir);
  final available = fixtures.existsSync();

  late Directory root;
  final scanner = LibraryScanner();
  const hasher = FileHasher();
  final reconciler = FileReconciler();

  setUp(() {
    root = Directory.systemTemp.createTempSync('marmelade_scan_');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Copies a fixture into the temp tree at [relativePath].
  File place(String fixtureName, String relativePath) {
    final target = File(p.join(root.path, relativePath));
    target.parent.createSync(recursive: true);
    File(p.join(_fixtureDir, fixtureName)).copySync(target.path);
    return target;
  }

  /// Turns a scan into the "known" rows a database would hold after indexing.
  List<KnownFile> indexAll(List<ScannedFile> files) {
    var id = 0;
    return [
      for (final f in files)
        () {
          final identity = hasher.fullyIdentify(f.file);
          return KnownFile(
            id: ++id,
            relativePath: f.relativePath,
            fileName: f.fileName,
            sizeBytes: f.sizeBytes,
            modifiedAt: f.modifiedAt,
            status: FileStatus.present,
            quickKey: identity.quickKey,
            contentKey: identity.contentKey,
          );
        }(),
    ];
  }

  group('scanner', () {
    test('finds audio and ignores everything else', () {
      place('01 multi-x.mp3', 'Album/01.mp3');
      place('20 flac-tagged.flac', 'Album/02.flac');
      place('22 wav-16bit.wav', 'Album/03.wav');
      // The junk that really turns up in music folders.
      File(p.join(root.path, 'Album', 'cover.jpg')).writeAsBytesSync([1, 2, 3]);
      File(p.join(root.path, 'Album', 'booklet.pdf')).writeAsBytesSync([1]);
      File(p.join(root.path, 'Album', 'desktop.ini')).writeAsStringSync('x');
      File(p.join(root.path, 'Album', 'partial.download'))
          .writeAsBytesSync([1]);

      final result = scanner.scan(root.path);
      expect(result.files.map((f) => f.relativePath),
          ['Album/01.mp3', 'Album/02.flac', 'Album/03.wav']);
      expect(result.skippedExtensions.keys,
          containsAll(['jpg', 'pdf', 'ini', 'download']));
      expect(result.unreadable, isEmpty);
    });

    test('skips saved-webpage sidecar folders', () {
      place('01 multi-x.mp3', 'keep.mp3');
      place('01 multi-x.mp3', 'Page_files/hidden.mp3');
      final result = scanner.scan(root.path);
      expect(result.files.map((f) => f.relativePath), ['keep.mp3']);
    });

    test('reports an empty file as unreadable rather than indexing it', () {
      File(p.join(root.path, 'failed.mp3')).writeAsBytesSync(const []);
      final result = scanner.scan(root.path);
      expect(result.files, isEmpty);
      expect(result.unreadable.values.single, contains('empty'));
    });

    test('honours exclude globs', () {
      place('01 multi-x.mp3', 'keep/a.mp3');
      place('01 multi-x.mp3', 'skipme/b.mp3');
      final result =
          LibraryScanner(excludeGlobs: ['skipme/**']).scan(root.path);
      expect(result.files.map((f) => f.relativePath), ['keep/a.mp3']);
    });

    test('uses forward slashes regardless of platform', () {
      place('01 multi-x.mp3', 'deep/nested/path/song.mp3');
      final result = scanner.scan(root.path);
      expect(result.files.single.relativePath, 'deep/nested/path/song.mp3');
      expect(result.files.single.relativePath, isNot(contains(r'\')));
    });

    test('non-recursive mode stays at the top level', () {
      place('01 multi-x.mp3', 'top.mp3');
      place('01 multi-x.mp3', 'sub/deeper.mp3');
      final result = scanner.scan(root.path, recursive: false);
      expect(result.files.map((f) => f.relativePath), ['top.mp3']);
    });
  }, skip: available ? null : 'fixtures not present at $_fixtureDir');

  group('real moves on disk', () {
    test('reorganising folders is detected as moves, not churn', () {
      // Index a flat dump of three tracks.
      place('01 multi-x.mp3', 'dump/a.mp3');
      place('20 flac-tagged.flac', 'dump/b.flac');
      place('22 wav-16bit.wav', 'dump/c.wav');
      final known = indexAll(scanner.scan(root.path).files);
      expect(known, hasLength(3));

      // Now the user tidies up: new folders, new filenames.
      Directory(p.join(root.path, 'Artist', 'Album')).createSync(recursive: true);
      File(p.join(root.path, 'dump', 'a.mp3'))
          .renameSync(p.join(root.path, 'Artist', 'Album', '01 First.mp3'));
      File(p.join(root.path, 'dump', 'b.flac'))
          .renameSync(p.join(root.path, 'Artist', 'Album', '02 Second.flac'));
      File(p.join(root.path, 'dump', 'c.wav'))
          .renameSync(p.join(root.path, 'Artist', 'Album', '03 Third.wav'));

      final plan = reconciler.reconcile(
        scanned: scanner.scan(root.path).files,
        known: known,
      );

      expect(plan.moves, hasLength(3), reason: 'all three are moves');
      expect(plan.adds, isEmpty, reason: 'no duplicate rows created');
      expect(plan.missing, isEmpty, reason: 'no tracks orphaned');
      // Confirmed by full payload hash, since the known rows recorded one.
      expect(plan.moves.every((m) => m.confirmedByContentKey), isTrue);
    });

    test('a retagged file that also moved is still one move', () {
      place('30 retag-a.mp3', 'before/song.mp3');
      final known = indexAll(scanner.scan(root.path).files);

      // Replace with the differently-tagged twin at a different path: same
      // audio, different bytes on disk.
      Directory(p.join(root.path, 'after')).createSync();
      File(p.join(root.path, 'before', 'song.mp3')).deleteSync();
      place('30 retag-b.mp3', 'after/renamed.mp3');

      final plan = reconciler.reconcile(
        scanned: scanner.scan(root.path).files,
        known: known,
      );

      expect(plan.moves, hasLength(1),
          reason: 'the payload hash ignores the changed tag block');
      expect(plan.moves.single.confirmedByContentKey, isTrue);
      expect(plan.adds, isEmpty);
      expect(plan.missing, isEmpty);
    });

    test('a genuinely different file is added, and the old one goes missing',
        () {
      place('01 multi-x.mp3', 'song.mp3');
      final known = indexAll(scanner.scan(root.path).files);

      File(p.join(root.path, 'song.mp3')).deleteSync();
      place('20 flac-tagged.flac', 'other.flac');

      final plan = reconciler.reconcile(
        scanned: scanner.scan(root.path).files,
        known: known,
      );
      expect(plan.moves, isEmpty);
      expect(plan.adds, hasLength(1));
      expect(plan.missing, hasLength(1));
    });

    test('a deleted file is marked missing and restored when it returns', () {
      place('01 multi-x.mp3', 'song.mp3');
      final known = indexAll(scanner.scan(root.path).files);

      File(p.join(root.path, 'song.mp3')).deleteSync();
      var plan = reconciler.reconcile(
        scanned: scanner.scan(root.path).files,
        known: known,
      );
      expect(plan.missing, hasLength(1));

      // The drive comes back.
      place('01 multi-x.mp3', 'song.mp3');
      final nowMissing = [
        KnownFile(
          id: known.single.id,
          relativePath: known.single.relativePath,
          sizeBytes: known.single.sizeBytes,
          modifiedAt: known.single.modifiedAt,
          status: FileStatus.missing,
          quickKey: known.single.quickKey,
          contentKey: known.single.contentKey,
        ),
      ];
      plan = reconciler.reconcile(
        scanned: scanner.scan(root.path).files,
        known: nowMissing,
      );
      expect(plan.adds, isEmpty);
      expect(plan.update.single.wasMissing, isTrue);
    });

    test('duplicate content in two places keeps two rows', () {
      place('01 multi-x.mp3', 'one/song.mp3');
      place('01 multi-x.mp3', 'two/song.mp3');
      final known = indexAll(scanner.scan(root.path).files);
      expect(known, hasLength(2));
      // Identical audio, so identical keys - the library must still hold both.
      expect(known.first.contentKey, known.last.contentKey);

      final plan = reconciler.reconcile(
        scanned: scanner.scan(root.path).files,
        known: known,
      );
      expect(plan.keep, hasLength(2));
      expect(plan.changeCount, 0);
    });

    test('a rescan with no changes does no work', () {
      place('01 multi-x.mp3', 'Album/01.mp3');
      place('20 flac-tagged.flac', 'Album/02.flac');
      final known = indexAll(scanner.scan(root.path).files);

      final plan = reconciler.reconcile(
        scanned: scanner.scan(root.path).files,
        known: known,
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.hashedFiles, 0, reason: 'unchanged files are never hashed');
    });
  }, skip: available ? null : 'fixtures not present at $_fixtureDir');
}
