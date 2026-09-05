import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/transfer/bundle_audio.dart';
import 'package:marmelade/data/transfer/transfer_bundle.dart';
import 'package:path/path.dart' as p;

/// Putting a bundle's music into the library.
///
/// The step that was missing: metadata only ever attaches to files this
/// machine already has, so music that travelled in the bundle sat in it while
/// every track it described was reported missing -- and the person was
/// expected to move gigabytes by hand in between.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('marmelade_audio_'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows can hold a handle a moment longer; temp outlives the run.
    }
  });

  Directory bundleWith(Map<String, String> files) {
    final bundle = Directory(p.join(root.path, 'bundle'))..createSync();
    for (final entry in files.entries) {
      final file = File(p.join(bundle.path, transferAudioDirName, entry.key));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    return bundle;
  }

  Directory library() => Directory(p.join(root.path, 'Music'));

  test('reports what a bundle is carrying without copying it', () async {
    final bundle = bundleWith({'Laur/Sound Chimera/01 Viyella.flac': 'aaaa'});

    final size = await BundleAudio.inspect(bundle);

    expect(size.files, 1);
    expect(size.bytes, 4);
    expect(size.isEmpty, isFalse);
  });

  test('a bundle with no music says so rather than looking broken', () async {
    final bundle = Directory(p.join(root.path, 'bundle'))..createSync();

    final size = await BundleAudio.inspect(bundle);

    expect(size.isEmpty, isTrue);
    expect(size.files, 0);
  });

  test('lays the files down under the tree they had', () async {
    // The exporter writes each file under its path inside its own library
    // folder, so Artist/Album/Track has to come out the other end intact --
    // otherwise a library arrives as one flat heap.
    final bundle = bundleWith({
      'Laur/Sound Chimera/01 Viyella.flac': 'one',
      'Xomu/Nightfall/03 Dusk.mp3': 'two',
    });

    final done = await BundleAudio.installInto(bundle, library());

    expect(done.copied, 2);
    expect(
      File(p.join(library().path, 'Laur', 'Sound Chimera', '01 Viyella.flac'))
          .readAsStringSync(),
      'one',
    );
    expect(
      File(p.join(library().path, 'Xomu', 'Nightfall', '03 Dusk.mp3'))
          .existsSync(),
      isTrue,
    );
  });

  test('never overwrites a file that is already there', () async {
    // Nothing in a transfer deletes or replaces. A file of the same name here
    // is either the same file, or this machine's own copy -- and neither is
    // the bundle's to overwrite.
    final bundle = bundleWith({'Laur/Track.flac': 'from the bundle'});
    final existing = File(p.join(library().path, 'Laur', 'Track.flac'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('mine, and different');

    final done = await BundleAudio.installInto(bundle, library());

    expect(done.copied, 0);
    expect(done.alreadyHere, 1);
    expect(existing.readAsStringSync(), 'mine, and different');
  });

  test('running it twice copies nothing the second time', () async {
    final bundle = bundleWith({'a/b.flac': 'x'});

    await BundleAudio.installInto(bundle, library());
    final again = await BundleAudio.installInto(bundle, library());

    expect(again.copied, 0);
    expect(again.alreadyHere, 1);
  });

  test('a bundle without an audio folder installs nothing, quietly', () async {
    final bundle = Directory(p.join(root.path, 'bundle'))..createSync();

    final done = await BundleAudio.installInto(bundle, library());

    expect(done.copied, 0);
    expect(library().existsSync(), isFalse, reason: 'nothing to make room for');
  });

  test('reports progress so a long copy is not a frozen dialog', () async {
    final bundle = bundleWith({'a.flac': 'x', 'b.flac': 'y', 'c.flac': 'z'});
    final seen = <int>[];

    await BundleAudio.installInto(
      bundle,
      library(),
      onProgress: (progress) => seen.add(progress.completed),
    );

    expect(seen, [1, 2, 3]);
  });
}
