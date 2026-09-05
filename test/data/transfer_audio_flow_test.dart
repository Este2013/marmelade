import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/library_indexer.dart';
import 'package:marmelade/data/transfer/bundle_audio.dart';
import 'package:marmelade/data/transfer/library_exporter.dart';
import 'package:marmelade/data/transfer/transfer_report.dart';
import 'package:marmelade/data/transfer/library_importer.dart';
import 'package:marmelade/data/transfer/transfer_bundle.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:path/path.dart' as p;

String get _fixtureDir =>
    Platform.environment['MARMELADE_FIXTURES'] ??
    r'C:\Users\makrofon\Music\testZiks\_marmelade_fixtures';

/// Moving music *and* what is known about it, in one go.
///
/// The end-to-end shape of what a person actually does: new songs at one
/// desk, both machines wanted in step. Every earlier test in this area starts
/// from "the files are already on both computers", which is precisely the
/// assumption that made the missing copy step invisible -- an import that
/// carried the audio still reported every track missing, because nothing ever
/// took the files out of the bundle.
void main() {
  final available = Directory(_fixtureDir).existsSync();

  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('marmelade_flow_'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows sometimes holds a handle briefly after a copy.
    }
  });

  /// One machine: a database, a music folder, and an indexer over it.
  Future<({MarmeladeDatabase db, Directory music, LibraryIndexer indexer})>
      machine(String name) async {
    final db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    final music = Directory(p.join(root.path, name))..createSync();
    final art = Directory(p.join(root.path, '$name-art'))..createSync();
    return (db: db, music: music, indexer: LibraryIndexer(db: db, artStore: ArtStore(art)));
  }

  test(
    'music travels with its metadata and lands on the right tracks',
    () async {
      final work = await machine('work');
      addTearDown(work.db.close);
      final laptop = await machine('laptop');
      addTearDown(laptop.db.close);

      // At the desk: two new songs, indexed, one of them rated.
      for (final entry in const {
        '01 multi-x.mp3': 'Album/01.mp3',
        '05 cjk.mp3': 'Album/02.mp3',
      }.entries) {
        final target = File(p.join(work.music.path, entry.value));
        target.parent.createSync(recursive: true);
        File(p.join(_fixtureDir, entry.key)).copySync(target.path);
      }
      final workFolder = await work.indexer.addFolder(work.music.path);
      await work.indexer.indexFolder(workFolder);
      await work.db.customStatement('UPDATE tracks SET rating = 5, is_favorite = 1');
      final tracksThere = await work.db.select(work.db.tracks).get();
      expect(tracksThere, hasLength(2), reason: 'the desk has the music');

      // Export, music included -- the deliberate step.
      final bundleDir = Directory(p.join(root.path, 'bundle'))..createSync();
      await LibraryExporter(db: work.db).exportTo(
        bundleDir,
        origin: const TransferOrigin(machineId: 'work', machineName: 'Work PC'),
        options: const TransferExportOptions(includeAudio: true),
      );
      expect((await BundleAudio.inspect(bundleDir)).files, 2);

      // At home: a library folder, and nothing in it.
      final laptopFolder = await laptop.indexer.addFolder(laptop.music.path);
      await laptop.indexer.indexFolder(laptopFolder);
      expect(await laptop.db.select(laptop.db.tracks).get(), isEmpty);

      // What an import now does, in order: copy, index, then merge.
      final installed = await BundleAudio.installInto(bundleDir, laptop.music);
      expect(installed.copied, 2);
      await laptop.indexer.indexFolder(laptopFolder);

      final bundle = TransferBundle.decode(
        await File(p.join(bundleDir.path, transferBundleFileName)).readAsString(),
      );
      final report = await LibraryImporter(db: laptop.db).import(
        bundle,
        bundleDirectory: bundleDir,
      );

      // The point of the whole exercise: the songs are here, playable, and
      // wearing what was said about them at the other desk.
      final arrived = await laptop.db.select(laptop.db.tracks).get();
      expect(arrived, hasLength(2));
      expect(arrived.every((t) => t.rating == 5), isTrue,
          reason: 'the ratings found the copied files');
      expect(arrived.every((t) => t.isFavorite), isTrue);
      expect(report.missingTracks, isEmpty,
          reason: 'nothing is missing once the files came too');

      final files = await laptop.db.select(laptop.db.mediaFiles).get();
      expect(files, hasLength(2));
      expect(files.every((f) => f.trackId != null), isTrue);
    },
    skip: available ? false : 'needs the audio fixtures in $_fixtureDir',
  );
}
