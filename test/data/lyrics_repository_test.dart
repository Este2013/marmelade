import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/lyrics_repository.dart';
import 'package:path/path.dart' as p;

/// Lyrics storage, against a real schema and real files.
///
/// The interesting half is the linked-file workflow: the file is the source of
/// truth, the stored text is a cache, and the two have to stay honest about
/// which one won.
void main() {
  late MarmeladeDatabase db;
  late LyricsRepository lyrics;
  late Directory folder;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    lyrics = LyricsRepository(db);
    folder = Directory.systemTemp.createTempSync('marmelade_lyrics_');
  });

  tearDown(() async {
    await db.close();
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  });

  Future<int> track(String title, {String? audioName}) async {
    final id = await db.into(db.tracks).insert(TracksCompanion.insert(
          title: title,
          nameKey: title.toLowerCase(),
        ));
    if (audioName != null) {
      final audio = File(p.join(folder.path, audioName))
        ..writeAsBytesSync(const [0]);
      final folderId = await db.into(db.libraryFolders).insert(
            LibraryFoldersCompanion.insert(path: folder.path),
          );
      await db.into(db.mediaFiles).insert(MediaFilesCompanion.insert(
            folderId: folderId,
            relativePath: audioName,
            fileName: audioName,
            extension: p.extension(audioName).replaceFirst('.', ''),
            sizeBytes: audio.lengthSync(),
            modifiedAt: audio.lastModifiedSync(),
            trackId: Value(id),
            status: const Value(FileStatus.present),
          ));
    }
    return id;
  }

  File write(String name, String content) {
    final file = File(p.join(folder.path, name));
    file.writeAsStringSync(content);
    return file;
  }

  group('storing text', () {
    test('saved lyrics come back parsed', () async {
      final id = await track('Song');
      await lyrics.save(id, content: '[00:10]\nWords here');

      final stored = await lyrics.watch(id).first;
      expect(stored.original, isNotNull);
      expect(stored.original!.document.blocks.single.text, 'Words here');
      expect(stored.original!.document.isSynced, isTrue);
    });

    test('the synced flag is stored, not guessed at read time', () async {
      final id = await track('Song');
      await lyrics.save(id, content: 'No timestamps here');

      final row = await db
          .customSelect('SELECT is_synced FROM lyrics WHERE track_id = ?1',
              variables: [Variable(id)])
          .getSingle();
      expect(row.read<bool>('is_synced'), isFalse);
    });

    test('saving again replaces rather than duplicating', () async {
      final id = await track('Song');
      await lyrics.save(id, content: 'first');
      await lyrics.save(id, content: 'second');

      final stored = await lyrics.watch(id).first;
      expect(stored.all, hasLength(1));
      expect(stored.original!.raw, 'second');
    });

    test('saving nothing removes the document', () async {
      // Rather than storing an empty one, which would show as "lyrics exist"
      // everywhere that checks.
      final id = await track('Song');
      await lyrics.save(id, content: 'words');
      await lyrics.save(id, content: '   ');

      expect((await lyrics.watch(id).first).isEmpty, isTrue);
    });

    test('a translation sits beside the original', () async {
      final id = await track('Song');
      await lyrics.save(id, content: '星');
      await lyrics.save(id, language: 'en', content: 'star');

      final stored = await lyrics.watch(id).first;
      expect(stored.original!.raw, '星');
      expect(stored.translations.single.language, 'en');
      expect(stored.forLanguage('en')!.raw, 'star');
      expect(stored.all, hasLength(2));
    });

    test('removing one language leaves the other', () async {
      final id = await track('Song');
      await lyrics.save(id, content: 'original');
      await lyrics.save(id, language: 'en', content: 'translated');
      await lyrics.remove(id, language: 'en');

      final stored = await lyrics.watch(id).first;
      expect(stored.original, isNotNull);
      expect(stored.translations, isEmpty);
    });
  });

  group('linked files', () {
    test('linking caches the text and remembers the path', () async {
      final id = await track('Song');
      final file = write('song.md', '# Verse\n[00:05]\nFrom a file');

      expect(await lyrics.link(id, path: file.path), isTrue);
      final entry = (await lyrics.watch(id).first).original!;
      expect(entry.isLinked, isTrue);
      expect(entry.filePath, file.path);
      expect(entry.document.blocks.single.heading, 'Verse');
    });

    test('the extension picks the format', () async {
      final id = await track('Song');
      await lyrics.link(id, path: write('a.lrc', '[00:01]x').path);
      expect((await lyrics.watch(id).first).original!.format,
          LyricsFormat.lrc);

      await lyrics.link(id, path: write('a.txt', 'plain').path);
      expect((await lyrics.watch(id).first).original!.format,
          LyricsFormat.plainText);
    });

    test('a newer file wins on refresh', () async {
      final id = await track('Song');
      final file = write('song.md', 'old words');
      await lyrics.link(id, path: file.path);

      // Stored a moment ago; the file is edited after that.
      file.writeAsStringSync('new words');
      file.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));

      final before = (await lyrics.watch(id).first).original!;
      expect(await lyrics.refreshIfStale(before), isTrue);
      expect((await lyrics.watch(id).first).original!.raw, 'new words');
    });

    test('an unchanged file is left alone', () async {
      final id = await track('Song');
      final file = write('song.md', 'words');
      await lyrics.link(id, path: file.path);

      final entry = (await lyrics.watch(id).first).original!;
      expect(await lyrics.refreshIfStale(entry), isFalse);
    });

    test('a missing file does not wipe what was cached', () async {
      // The drive being unplugged is not a reason to lose the lyrics.
      final id = await track('Song');
      final file = write('song.md', 'words');
      await lyrics.link(id, path: file.path);
      file.deleteSync();

      final entry = (await lyrics.watch(id).first).original!;
      expect(await lyrics.refreshIfStale(entry), isFalse);
      expect((await lyrics.watch(id).first).original!.raw, 'words');
    });

    test('typing over a linked document unlinks it', () async {
      // A document cannot be both typed here and owned by a file; one of the
      // two would silently win on the next refresh.
      final id = await track('Song');
      await lyrics.link(id, path: write('song.md', 'from file').path);
      await lyrics.save(id, content: 'typed here');

      final entry = (await lyrics.watch(id).first).original!;
      expect(entry.isLinked, isFalse);
      expect(entry.raw, 'typed here');
    });

    test('linking a file that is not there fails without storing', () async {
      final id = await track('Song');
      expect(
        await lyrics.link(id, path: p.join(folder.path, 'nope.md')),
        isFalse,
      );
      expect((await lyrics.watch(id).first).isEmpty, isTrue);
    });
  });

  group('sidecars next to the audio', () {
    test('a file named after the track is the original', () async {
      final id = await track('Song', audioName: 'song.mp3');
      write('song.lrc', '[00:01]x');

      final found = await lyrics.findSidecars(id);
      expect(found, hasLength(1));
      expect(found.single.language, isNull);
    });

    test('a language suffix makes it a translation', () async {
      final id = await track('Song', audioName: 'song.mp3');
      write('song.md', 'original');
      write('song.en.md', 'english');
      write('song.pt-br.md', 'brasileiro');

      final found = await lyrics.findSidecars(id);
      expect(found.map((f) => f.language), [null, 'en', 'pt-br']);
    });

    test('a word that is not a language is not treated as one', () async {
      // "song.instrumental.md" is somebody's notes, and filing it as
      // Indonesian would be a confident mistake.
      final id = await track('Song', audioName: 'song.mp3');
      write('song.instrumental.md', 'notes');
      write('unrelated.md', 'other song');

      expect(await lyrics.findSidecars(id), isEmpty);
    });

    test('importing links everything found', () async {
      final id = await track('Song', audioName: 'song.mp3');
      write('song.md', 'original');
      write('song.fr.md', 'francais');

      expect(await lyrics.importSidecars(id), 2);
      final stored = await lyrics.watch(id).first;
      expect(stored.original!.raw, 'original');
      expect(stored.forLanguage('fr')!.raw, 'francais');
    });

    test('a track with no present file finds nothing', () async {
      final id = await track('Song');
      expect(await lyrics.findSidecars(id), isEmpty);
    });
  });

  group('timing', () {
    test('the stored offset is what the viewer applies', () async {
      final id = await track('Song');
      await lyrics.save(id, content: '[00:10]\nwords');
      final entry = (await lyrics.watch(id).first).original!;

      await lyrics.setOffset(entry.id, const Duration(milliseconds: -400));
      final shifted = (await lyrics.watch(id).first).original!;
      expect(shifted.offset, const Duration(milliseconds: -400));
    });
  });
}
