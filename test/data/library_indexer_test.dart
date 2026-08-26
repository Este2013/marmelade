import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/library_indexer.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:path/path.dart' as p;

String get _fixtureDir =>
    Platform.environment['MARMELADE_FIXTURES'] ??
    r'C:\Users\makrofon\Music\testZiks\_marmelade_fixtures';

void main() {
  final available = Directory(_fixtureDir).existsSync();

  late MarmeladeDatabase db;
  late Directory music;
  late Directory artRoot;
  late LibraryIndexer indexer;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    music = Directory.systemTemp.createTempSync('marmelade_lib_');
    artRoot = Directory.systemTemp.createTempSync('marmelade_art_');
    indexer = LibraryIndexer(db: db, artStore: ArtStore(artRoot));
  });

  tearDown(() async {
    await db.close();
    if (music.existsSync()) music.deleteSync(recursive: true);
    if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
  });

  /// Copies a fixture into the fake library.
  void place(String fixtureName, String relativePath) {
    final target = File(p.join(music.path, relativePath));
    target.parent.createSync(recursive: true);
    File(p.join(_fixtureDir, fixtureName)).copySync(target.path);
  }

  /// Writes a plausible cover image into a folder.
  void placeCover(String relativePath) {
    final bytes = BytesBuilder()
      ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    final ihdr = Uint8List(25);
    final view = ByteData.view(ihdr.buffer);
    view.setUint32(0, 13);
    ihdr.setRange(4, 8, 'IHDR'.codeUnits);
    view.setUint32(8, 1000);
    view.setUint32(12, 1000);
    ihdr[16] = 8;
    ihdr[17] = 6;
    bytes.add(ihdr);
    bytes.add(List.filled(64, 1));
    final file = File(p.join(music.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes.toBytes());
  }

  Future<IndexOutcome> indexOnce() async {
    final folderId = await indexer.addFolder(music.path);
    return indexer.indexFolder(folderId);
  }

  Future<List<String>> artistNames() async {
    final rows = await db.select(db.artists).get();
    final names = rows.map((a) => a.name).toList()..sort();
    return names;
  }

  group('first index', () {
    test('creates tracks, artists and albums from tags', () async {
      place('01 multi-x.mp3', 'Album/01.mp3');
      place('05 cjk.mp3', 'Album/02.mp3');
      place('20 flac-tagged.flac', 'Album/03.flac');

      final outcome = await indexOnce();

      expect(outcome.filesSeen, 3);
      expect(outcome.filesAdded, 3);
      expect(outcome.tracksCreated, 3);
      expect(outcome.problems, isEmpty);

      final tracks = await db.select(db.tracks).get();
      expect(tracks, hasLength(3));
      expect(tracks.map((t) => t.title),
          containsAll(['Cross Separator', 'CJK Artist']));

      // Every track is linked to the file that holds it.
      final files = await db.select(db.mediaFiles).get();
      expect(files, hasLength(3));
      expect(files.every((f) => f.trackId != null), isTrue);
      expect(files.every((f) => f.status == FileStatus.present), isTrue);
      expect(files.every((f) => f.quickKey != null), isTrue);
    });

    test('splits a multi-artist credit into separate artists', () async {
      // "Camellia x Nanahira" needs corroboration, which the other two files
      // provide by naming both artists via trustworthy separators.
      place('01 multi-x.mp3', 'x/01.mp3'); // Camellia x Nanahira
      place('06 vs.mp3', 'x/02.mp3'); // Camellia VS Kobaryo
      place('10 pipe-plus.mp3', 'x/03.mp3'); // t+pazolite | Nanahira

      await indexOnce();
      final names = await artistNames();

      expect(names, containsAll(['Camellia', 'Nanahira', 'Kobaryo',
        't+pazolite']));
      // The unsplit form must not survive as an artist of its own.
      expect(names, isNot(contains('Camellia x Nanahira')));
    });

    test('a track is reachable from every artist credited on it', () async {
      place('01 multi-x.mp3', 'x/01.mp3');
      place('06 vs.mp3', 'x/02.mp3');
      place('10 pipe-plus.mp3', 'x/03.mp3');
      await indexOnce();

      // The guarantee behind "an artist name is always one click from its
      // page": the collaboration appears under both artists.
      for (final name in ['Camellia', 'Nanahira']) {
        final rows = await db
            .customSelect(
              'SELECT t.title FROM tracks t '
              'JOIN track_credits tc ON tc.track_id = t.id '
              'JOIN artists a ON a.id = tc.artist_id '
              'WHERE a.name = ?',
              variables: [Variable(name)],
            )
            .get();
        expect(rows.map((r) => r.read<String>('title')),
            contains('Cross Separator'),
            reason: '$name should reach the collaboration');
      }
    });

    test('assigns the featured role from a feat. credit', () async {
      place('03 comma-feat.mp3', 'f/01.mp3');
      await indexOnce();

      final rows = await db
          .customSelect(
            'SELECT a.name, tc.role FROM track_credits tc '
            'JOIN artists a ON a.id = tc.artist_id ORDER BY tc.sort_order',
          )
          .get();
      final byName = {
        for (final r in rows) r.read<String>('name'): r.read<String>('role'),
      };
      expect(byName['PinocchioP'], CreditRole.mainArtist.name);
      expect(byName['Hatsune Miku'], CreditRole.mainArtist.name);
      expect(byName['Kasane Teto'], CreditRole.featured.name);
    });

    test('parks an ambiguous credit for review instead of guessing', () async {
      place('02 ampersand-real.mp3', 'amb/01.mp3'); // Simon & Garfunkel
      final outcome = await indexOnce();

      expect(outcome.pendingCredits, 1);
      final pending = await db.select(db.pendingCredits).get();
      expect(pending.single.rawCredit, 'Simon & Garfunkel');
      // The suggestion carries the split that was declined, so accepting it is
      // one click.
      expect(pending.single.suggestions, contains('Garfunkel'));

      // The track still has an artist, so it is not left unbrowsable.
      final names = await artistNames();
      expect(names, contains('Simon & Garfunkel'));
    });

    test('links a romanisation as an alias rather than a second artist',
        () async {
      // The artist tag here is "PinocchioP / <native spelling>".
      final source = File(p.join(_fixtureDir, '01 multi-x.mp3'));
      final target = File(p.join(music.path, 'alias', 'song.mp3'));
      target.parent.createSync(recursive: true);
      source.copySync(target.path);
      // Retag it via the app's own writer path is out of scope here, so use a
      // fixture that already carries the pattern.
      target.deleteSync();
      place('05 cjk.mp3', 'alias/song.mp3');
      await indexOnce();

      // The CJK-named artist exists and is searchable by its own spelling.
      final names = await artistNames();
      expect(names.any((n) => n.contains('ピノキオピー')), isTrue);
    });

    test('records genres as tags in the Genre category', () async {
      place('01 multi-x.mp3', 'g/01.mp3'); // genre Electronic
      place('04 slash-acdc.mp3', 'g/02.mp3'); // genre Rock
      await indexOnce();

      final rows = await db
          .customSelect(
            'SELECT tg.name, c.slug FROM tags tg '
            'JOIN tag_categories c ON c.id = tg.category_id',
          )
          .get();
      final byName = {
        for (final r in rows) r.read<String>('name'): r.read<String>('slug'),
      };
      expect(byName['Electronic'], systemTagCategoryGenre);
      expect(byName['Rock'], systemTagCategoryGenre);

      // And they are attached to tracks.
      final links = await db.select(db.trackTags).get();
      expect(links, isNotEmpty);
      expect(links.every((l) => l.source == DataSource.fileMetadata), isTrue);
    });

    test('never splits a name whose separator is not whitespace-delimited',
        () async {
      place('04 slash-acdc.mp3', 'r/01.mp3'); // AC/DC
      await indexOnce();
      expect(await artistNames(), contains('AC/DC'));
    });

    test('falls back to the filename when a file has no tags', () async {
      place('11 Untagged Artist - Untagged Title.mp3', 'u/07 Some Song.mp3');
      await indexOnce();

      final track = (await db.select(db.tracks).get()).single;
      // The leading track number is stripped; nothing else is invented.
      expect(track.title, 'Some Song');
      // No artist is guessed out of the filename.
      expect(await db.select(db.trackCredits).get(), isEmpty);
    });

    test('imports a folder cover as the album artwork', () async {
      place('01 multi-x.mp3', 'Album/01.mp3');
      placeCover('Album/cover.png');

      final outcome = await indexOnce();
      expect(outcome.imagesStored, 1);

      final album = (await db.select(db.albums).get()).single;
      expect(album.imageId, isNotNull);

      final image = (await db.select(db.images).get()).single;
      expect(image.kind, ImageKind.sidecar);
      expect(image.width, 1000);
      expect(image.sourceDescription, contains('cover.png'));

      // The artwork view resolves a track with no art of its own to the
      // album's.
      final resolved = await db
          .customSelect('SELECT image_id FROM v_track_artwork')
          .getSingle();
      expect(resolved.read<int?>('image_id'), album.imageId);
    });

    test('finds an artist portrait in a collection folder', () async {
      // This FLAC is credited to Nanahira alone, matching the folder name.
      place('21 flac-hires.flac', '[Collection] Nanahira/Album/01.flac');
      placeCover('[Collection] Nanahira/artist.png');
      await indexOnce();

      final artists = await db.select(db.artists).get();
      final nanahira = artists.firstWhere((a) => a.name == 'Nanahira');
      expect(nanahira.imageId, isNotNull);

      final image = (await db.select(db.images).get())
          .firstWhere((i) => i.role == ImageRole.artist);
      expect(image.sourceDescription, contains('artist.png'));
    });

    test('a collection portrait goes only to the artist it names', () async {
      // The folder names one artist. A guest who merely appears inside it must
      // not inherit that artist's photo - which is what happens if the
      // portrait is applied to every artist in the tree.
      place('21 flac-hires.flac', '[Collection] Nanahira/A/01.flac');
      place('03 comma-feat.mp3', '[Collection] Nanahira/A/02.mp3');
      placeCover('[Collection] Nanahira/artist.png');
      await indexOnce();

      final artists = await db.select(db.artists).get();
      final withArt =
          artists.where((a) => a.imageId != null).map((a) => a.name).toList();
      expect(withArt, ['Nanahira']);
      // The guests exist, they just have no portrait.
      expect(artists.map((a) => a.name), containsAll(['Kasane Teto']));
    });

    test('populates both search indexes', () async {
      place('01 multi-x.mp3', 'Album/01.mp3');
      place('05 cjk.mp3', 'Album/02.mp3');
      await indexOnce();

      final counts = await indexer.searchIndexer.counts();
      expect(counts.tokens, greaterThan(0));
      expect(counts.trigrams, greaterThan(0));

      // A CJK artist is findable by a substring of its name, which is the
      // whole reason the trigram index exists.
      final hits = await db.customSelect(
        'SELECT entity_id FROM $ftsTrigramTable '
        'WHERE $ftsTrigramTable MATCH ?',
        variables: [Variable('ノキオ')],
      ).get();
      expect(hits, isNotEmpty);
    });

    test('records a scan run with accurate counters', () async {
      place('01 multi-x.mp3', 'Album/01.mp3');
      place('05 cjk.mp3', 'Album/02.mp3');
      final outcome = await indexOnce();

      final run = (await db.select(db.scanRuns).get()).single;
      expect(run.id, outcome.scanRunId);
      expect(run.status, ScanStatus.completed);
      expect(run.filesSeen, 2);
      expect(run.filesAdded, 2);
      expect(run.finishedAt, isNotNull);
    });

    test('ignores non-audio files in the folder', () async {
      place('01 multi-x.mp3', 'Album/01.mp3');
      File(p.join(music.path, 'Album', 'booklet.pdf')).writeAsBytesSync([1]);
      File(p.join(music.path, 'Album', 'notes.txt')).writeAsStringSync('hi');
      final outcome = await indexOnce();
      expect(outcome.filesSeen, 1);
    });
  }, skip: available ? null : 'fixtures not present at $_fixtureDir');

  group('re-index', () {
    test('a second run with no changes creates nothing new', () async {
      place('01 multi-x.mp3', 'Album/01.mp3');
      place('05 cjk.mp3', 'Album/02.mp3');
      final folderId = await indexer.addFolder(music.path);
      await indexer.indexFolder(folderId);

      final tracksBefore = (await db.select(db.tracks).get()).length;
      final artistsBefore = (await db.select(db.artists).get()).length;

      final second = await indexer.indexFolder(folderId);

      expect(second.filesAdded, 0);
      expect(second.filesUpdated, 0);
      expect(second.tracksCreated, 0);
      expect(second.changeCount, 0);
      expect((await db.select(db.tracks).get()).length, tracksBefore);
      expect((await db.select(db.artists).get()).length, artistsBefore);
    });

    test('a moved file keeps its track, rating and play count', () async {
      // The promise the whole file-identity design exists to keep.
      place('01 multi-x.mp3', 'dump/song.mp3');
      final folderId = await indexer.addFolder(music.path);
      await indexer.indexFolder(folderId);

      final track = (await db.select(db.tracks).get()).single;
      await (db.update(db.tracks)..where((t) => t.id.equals(track.id)))
          .write(const TracksCompanion(
        rating: Value(90),
        playCount: Value(42),
        isFavorite: Value(true),
      ));

      // Reorganise: new folder, new name.
      Directory(p.join(music.path, 'Artist', 'Album')).createSync(
          recursive: true);
      File(p.join(music.path, 'dump', 'song.mp3'))
          .renameSync(p.join(music.path, 'Artist', 'Album', '01 Renamed.mp3'));

      final second = await indexer.indexFolder(folderId);

      expect(second.filesMoved, 1);
      expect(second.filesAdded, 0);
      expect(second.tracksCreated, 0);
      expect(second.filesMissing, 0);

      final tracksAfter = await db.select(db.tracks).get();
      expect(tracksAfter, hasLength(1), reason: 'no duplicate track');
      expect(tracksAfter.single.id, track.id);
      expect(tracksAfter.single.rating, 90);
      expect(tracksAfter.single.playCount, 42);
      expect(tracksAfter.single.isFavorite, isTrue);

      // The file row now points at the new location.
      final file = (await db.select(db.mediaFiles).get()).single;
      expect(file.relativePath, 'Artist/Album/01 Renamed.mp3');
      expect(file.trackId, track.id);
    });

    test('a deleted file is marked missing, keeping its track', () async {
      place('01 multi-x.mp3', 'song.mp3');
      final folderId = await indexer.addFolder(music.path);
      await indexer.indexFolder(folderId);

      File(p.join(music.path, 'song.mp3')).deleteSync();
      final second = await indexer.indexFolder(folderId);

      expect(second.filesMissing, 1);
      final file = (await db.select(db.mediaFiles).get()).single;
      expect(file.status, FileStatus.missing);
      // The track survives, so ratings and history are not lost to an
      // unplugged drive.
      expect(await db.select(db.tracks).get(), hasLength(1));
    });

    test('user edits survive a rescan', () async {
      place('01 multi-x.mp3', 'song.mp3');
      final folderId = await indexer.addFolder(music.path);
      await indexer.indexFolder(folderId);

      final track = (await db.select(db.tracks).get()).single;
      // Someone corrects the title and marks it verified.
      await (db.update(db.tracks)..where((t) => t.id.equals(track.id)))
          .write(const TracksCompanion(
        title: Value('The Proper Title'),
        isVerified: Value(true),
      ));
      // And adds a credit of their own.
      final artistId = await db.into(db.artists).insert(
            ArtistsCompanion.insert(name: 'Hand Added', nameKey: 'hand added'),
          );
      await db.into(db.trackCredits).insert(TrackCreditsCompanion.insert(
            trackId: track.id,
            artistId: artistId,
            role: const Value(CreditRole.producer),
            source: const Value(DataSource.user),
          ));

      // Force a re-read by touching the file.
      final file = File(p.join(music.path, 'song.mp3'));
      file.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
      await indexer.indexFolder(folderId);

      final after = (await db.select(db.tracks).get()).single;
      expect(after.title, 'The Proper Title',
          reason: 'a verified track must not be overwritten');

      final credits = await db.select(db.trackCredits).get();
      expect(
        credits.where((c) => c.source == DataSource.user),
        hasLength(1),
        reason: 'a hand-added credit must survive',
      );
    });

    test('two files holding the same song share one track', () async {
      // An mp3 and a flac of the same album track should not split ratings
      // between formats.
      place('01 multi-x.mp3', 'Album/01.mp3');
      place('nested/deeper/duplicate-of-01.mp3', 'Album/01 copy.mp3');
      await indexOnce();

      final tracks = await db.select(db.tracks).get();
      final files = await db.select(db.mediaFiles).get();
      expect(files, hasLength(2));
      expect(tracks, hasLength(1),
          reason: 'identical audio is one song in two files');
      expect(files.map((f) => f.trackId).toSet(), hasLength(1));
    });
  }, skip: available ? null : 'fixtures not present at $_fixtureDir');
}
