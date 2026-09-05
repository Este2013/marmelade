import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/missing_files_repository.dart';

/// Songs the library still lists but can no longer play.
///
/// The database cannot tell an unplugged drive from a deleted folder, so a
/// scan keeps the row either way -- which is right, and which is also how a
/// library quietly fills with songs that do nothing when clicked. These are
/// the rules for saying how much of that there is, and for clearing it out
/// when it really is gone.
void main() {
  late MarmeladeDatabase db;
  late MissingFilesRepository missing;
  int? folderId;
  var counter = 0;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    missing = MissingFilesRepository(db);
    folderId = null;
    counter = 0;
  });
  tearDown(() => db.close());

  Future<int> track(String title, {int? albumId}) =>
      db.into(db.tracks).insert(TracksCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            albumId: Value(albumId),
          ));

  Future<int> album(String title) =>
      db.into(db.albums).insert(AlbumsCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
          ));

  Future<int> file(int trackId, {required FileStatus status}) async {
    folderId ??= await db
        .into(db.libraryFolders)
        .insert(LibraryFoldersCompanion.insert(path: r'C:\Music'));
    final name = 'song${counter++}.flac';
    return db.into(db.mediaFiles).insert(MediaFilesCompanion.insert(
          folderId: folderId!,
          relativePath: 'Artist/Album/$name',
          fileName: name,
          extension: 'flac',
          sizeBytes: 5000000,
          modifiedAt: DateTime.utc(2026),
          trackId: Value(trackId),
          status: Value(status),
        ));
  }

  group('counting what is gone', () {
    test('a library with every file in place has nothing to report', () async {
      final id = await track('Viyella');
      await file(id, status: FileStatus.present);

      expect((await missing.watch().first).any, isFalse);
    });

    test('counts a track whose only file has gone', () async {
      final id = await track('Viyella');
      await file(id, status: FileStatus.missing);

      final summary = await missing.watch().first;

      expect(summary.tracks, 1);
      expect(summary.files, 1);
    });

    test('a song still held in another format has not gone anywhere',
        () async {
      // The unit is the track, not the file: a FLAC that vanished while the
      // MP3 is still here plays perfectly well.
      final id = await track('Viyella');
      await file(id, status: FileStatus.missing);
      await file(id, status: FileStatus.present);

      final summary = await missing.watch().first;

      expect(summary.tracks, 0, reason: 'it still plays');
      expect(summary.files, 1, reason: 'but a file really is gone');
    });

    test('an album counts as gone only when all of it is', () async {
      final albumId = await album('Sound Chimera');
      final one = await track('Viyella', albumId: albumId);
      final two = await track('Ascension', albumId: albumId);
      await file(one, status: FileStatus.missing);
      await file(two, status: FileStatus.present);

      expect((await missing.watch().first).albums, 0,
          reason: 'a gap in a record is not a missing record');

      // Through drift's own API rather than a raw statement: a raw one writes
      // the rows without telling drift which tables moved, and the stream
      // would still be serving the value it cached a moment ago.
      await db.update(db.mediaFiles).write(
            const MediaFilesCompanion(status: Value(FileStatus.missing)),
          );

      expect((await missing.watch().first).albums, 1);
    });

    test('lists them with where the file used to be', () async {
      // A title alone does not identify a song; the folder says which drive
      // it was on, which is what makes the list worth reading.
      final id = await track('Viyella');
      await file(id, status: FileStatus.missing);

      final listed = await missing.list();

      expect(listed, hasLength(1));
      expect(listed.single.title, 'Viyella');
      expect(listed.single.path, contains('Artist/Album'));
    });
  });

  group('removing them', () {
    test('takes the tracks and the albums they empty', () async {
      final albumId = await album('Sound Chimera');
      final id = await track('Viyella', albumId: albumId);
      await file(id, status: FileStatus.missing);

      final removed = await missing.removeMissing();

      expect(removed.tracks, 1);
      expect(removed.albums, 1);
      expect(await db.select(db.tracks).get(), isEmpty);
      expect(await db.select(db.albums).get(), isEmpty);
    });

    test('leaves the file rows behind nothing to puzzle over later',
        () async {
      // The foreign key only nulls `track_id`, which would leave rows
      // pointing at a file nobody claims -- for the next scan to adopt.
      final id = await track('Viyella');
      await file(id, status: FileStatus.missing);

      await missing.removeMissing();

      expect(await db.select(db.mediaFiles).get(), isEmpty);
    });

    test('does not touch a song that still has a file', () async {
      final keep = await track('Ascension');
      await file(keep, status: FileStatus.present);
      final lose = await track('Viyella');
      await file(lose, status: FileStatus.missing);

      final removed = await missing.removeMissing();

      expect(removed.tracks, 1);
      final left = await db.select(db.tracks).get();
      expect(left.map((t) => t.title), ['Ascension']);
    });

    test('keeps an album that still has something on it', () async {
      final albumId = await album('Sound Chimera');
      final gone = await track('Viyella', albumId: albumId);
      final here = await track('Ascension', albumId: albumId);
      await file(gone, status: FileStatus.missing);
      await file(here, status: FileStatus.present);

      final removed = await missing.removeMissing();

      expect(removed.albums, 0);
      expect(await db.select(db.albums).get(), hasLength(1));
    });

    test('with nothing missing it does nothing at all', () async {
      final id = await track('Viyella');
      await file(id, status: FileStatus.present);

      final removed = await missing.removeMissing();

      expect(removed.tracks, 0);
      expect(await db.select(db.tracks).get(), hasLength(1));
    });
  });
}
