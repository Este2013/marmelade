import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/library_indexer.dart';
import 'package:marmelade/data/metadata/tag_reader.dart';
import 'package:marmelade/data/metadata/track_metadata.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:path/path.dart' as p;

/// Where a file's own embedded picture ends up.
///
/// The artwork pass is built around the fact that artwork usually belongs to
/// a folder: one `cover.jpg` serves a whole album, and reading an APIC frame
/// out of every track instead would make a scan crawl. A track with no album
/// is the case that reasoning does not cover -- nothing hands it the folder
/// cover, so without its own picture it falls all the way through to its
/// artist's portrait, which is a photograph of a person rather than art for
/// a song.
///
/// The tag reader is faked here rather than driven with real files: what is
/// being tested is which *target* a picture is attached to, and that decision
/// does not depend on whether a real APIC frame was parsed to reach it.
void main() {
  late MarmeladeDatabase db;
  late Directory music;
  late Directory artRoot;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    music = Directory.systemTemp.createTempSync('marmelade_art_lib_');
    artRoot = Directory.systemTemp.createTempSync('marmelade_art_store_');
  });

  tearDown(() async {
    await db.close();
    // A still-running probe can hold a handle briefly; a locked temp folder
    // is not a reason to fail a test about artwork.
    try {
      if (music.existsSync()) music.deleteSync(recursive: true);
      if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the OS to clean up.
    }
  });

  /// Writes a file the scanner will pick up. Its bytes never matter: the tag
  /// reader is faked, and nothing else parses them.
  File place(String relativePath) {
    final file = File(p.join(music.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(Uint8List.fromList(List.filled(2048, 7)));
    return file;
  }

  /// A one-pixel PNG. Real bytes, because the art store probes what it is
  /// given and refuses anything it cannot decode.
  Uint8List pixel() => Uint8List.fromList(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
      ]);

  /// Indexes the fake library, registering it the first time.
  ///
  /// Registered once rather than per call: the tests that scan twice are
  /// about what a *rescan* does, and a second folder row would make the
  /// second run a first run of something else.
  Future<void> scan() async {
    final existing = await db.customSelect(
      'SELECT id FROM library_folders WHERE path = ?1',
      variables: [Variable(music.path)],
    ).getSingleOrNull();
    final folderId = existing?.read<int>('id') ??
        await db.into(db.libraryFolders).insert(
              LibraryFoldersCompanion.insert(path: music.path),
            );
    await LibraryIndexer(
      db: db,
      artStore: ArtStore(artRoot),
      tagReader: _FakeTagReader(pixel()),
    ).indexFolder(folderId);
  }

  /// The stored path the artwork view resolves for a track, which is what a
  /// tile actually draws.
  Future<String?> artworkOf(String title) async {
    final row = await db.customSelect(
      'SELECT im.stored_path AS path FROM tracks t '
      'LEFT JOIN v_track_artwork vt ON vt.track_id = t.id '
      'LEFT JOIN images im ON im.id = vt.image_id '
      'WHERE t.title = ?1',
      variables: [Variable(title)],
    ).getSingleOrNull();
    return row?.read<String?>('path');
  }

  Future<int?> trackImageOf(String title) async {
    final row = await db.customSelect(
      'SELECT image_id FROM tracks WHERE title = ?1',
      variables: [Variable(title)],
    ).getSingleOrNull();
    return row?.read<int?>('image_id');
  }

  test('a track with no album keeps the picture inside its own file',
      () async {
    // The report this covers: a loose single showed its artist's portrait
    // even though the file carried its own cover.
    place('Abyss.mp3');

    await scan();

    expect(await trackImageOf('Abyss'), isNotNull);
    expect(await artworkOf('Abyss'), isNotNull);
  });

  test('it keeps it even when the folder has a cover of its own', () async {
    // The case that was actually broken. A folder cover is only ever handed
    // to an album, so a loose single beside one came away with nothing --
    // and the old rule skipped reading its file precisely because a cover
    // file existed.
    place('Abyss.mp3');
    File(p.join(music.path, 'cover.jpg')).writeAsBytesSync(pixel());

    await scan();

    expect(
      await trackImageOf('Abyss'),
      isNotNull,
      reason: 'the folder cover is not for a track that has no album',
    );
  });

  test('its own picture beats the artist portrait it used to fall back to',
      () async {
    place('Abyss.mp3');
    // Give the artist a portrait, which is what the view reached for before.
    final artistImage = await db.into(db.images).insert(
          ImagesCompanion.insert(
            sha256: 'portrait',
            storedPath: 'po/portrait.jpg',
            mimeType: 'image/jpeg',
            byteSize: 10,
            kind: ImageKind.userProvided,
          ),
        );

    await scan();

    await (db.update(db.artists)..where((a) => a.name.equals('Kirara Magic')))
        .write(ArtistsCompanion(imageId: Value(artistImage)));

    expect(
      await artworkOf('Abyss'),
      isNot('po/portrait.jpg'),
      reason: 'a photo of a person is not art for a song',
    );
  });

  test('a loose track scanned before the rule existed is caught on a rescan',
      () async {
    // The pass that places artwork only ever sees files a scan added or
    // changed, so a fix to where artwork goes would otherwise apply only to
    // music indexed afterwards -- and the library already full of loose
    // singles would stay wrong forever.
    place('Abyss.mp3');
    await scan();

    // Put it back the way an older version would have left it.
    await (db.update(db.tracks)..where((t) => t.title.equals('Abyss')))
        .write(const TracksCompanion(imageId: Value(null)));
    expect(await trackImageOf('Abyss'), isNull);

    await scan();

    expect(await trackImageOf('Abyss'), isNotNull);
  });

  test('the repair reaches every loose track, not just the first few',
      () async {
    // The bug this covers: the pass was capped, and a LIMIT with no cursor
    // returns the *same* rows every scan -- so a library with more
    // candidates than the cap re-read its first batch forever and never once
    // reached the rest. The tracks it never reached were the ones added
    // last, which is exactly where a newly noticed problem lives.
    for (var i = 0; i < 40; i++) {
      place('Loose $i.mp3');
    }
    await scan();

    // Put them all back the way an older version left them.
    await db.customUpdate('UPDATE tracks SET image_id = NULL');
    expect(await trackImageOf('Loose 39'), isNull);

    await scan();

    // The last one added is the one a capped pass would never have got to.
    expect(await trackImageOf('Loose 0'), isNotNull);
    expect(
      await trackImageOf('Loose 39'),
      isNotNull,
      reason: 'the end of the list is reached too',
    );
  });

  test('a track on an album still leaves its picture on the album', () async {
    // Unchanged, and deliberately so: one cover serves the whole release,
    // and reading an APIC frame out of every track is what this pass exists
    // to avoid.
    place(p.join('Some Album', 'One.mp3'));
    place(p.join('Some Album', 'Two.mp3'));

    await scan();

    final album = await db
        .customSelect('SELECT image_id FROM albums WHERE title = ?1',
            variables: [Variable('Some Album')])
        .getSingleOrNull();
    expect(album?.read<int?>('image_id'), isNotNull);
    // The tracks lean on the album rather than each carrying a copy.
    expect(await trackImageOf('One'), isNull);
    expect(await artworkOf('One'), isNotNull);
  });
}

/// Returns the same metadata for every file, with a picture in it.
///
/// The album is taken from the folder name, so a file at the library root is
/// a loose single and one inside a folder belongs to a release -- which is
/// the only distinction any of these tests turns on.
class _FakeTagReader extends TagReader {
  const _FakeTagReader(this.picture);

  final Uint8List picture;

  @override
  TrackFileMetadata read(File file, {bool includePictures = false}) {
    final folder = p.basename(file.parent.path);
    final atRoot = folder.startsWith('marmelade_art_lib_');
    return TrackFileMetadata(
      title: p.basenameWithoutExtension(file.path),
      albumTitle: atRoot ? null : folder,
      credits: const [
        RawCredit(value: 'Kirara Magic', role: CreditRole.mainArtist),
      ],
      duration: const Duration(minutes: 3),
      codec: 'mp3',
      pictures: includePictures
          ? [
              EmbeddedPicture(
                bytes: picture,
                mimeType: 'image/png',
                role: ImageRole.front,
              ),
            ]
          : const [],
    );
  }
}
