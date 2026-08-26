import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/enums.dart';
import 'package:marmelade/data/fs/art_sidecar.dart';
import 'package:marmelade/data/fs/image_probe.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:path/path.dart' as p;

/// Builds a minimal but valid PNG of the requested size.
///
/// Only the IHDR header has to be truthful for the probe, which is the point:
/// dimensions are read without decoding pixels.
Uint8List fakePng(int width, int height, {int noise = 0}) {
  final bytes = BytesBuilder();
  bytes.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final ihdr = Uint8List(25);
  final view = ByteData.view(ihdr.buffer);
  view.setUint32(0, 13); // chunk length
  ihdr.setRange(4, 8, 'IHDR'.codeUnits);
  view.setUint32(8, width);
  view.setUint32(12, height);
  ihdr[16] = 8; // bit depth
  ihdr[17] = 6; // colour type
  bytes.add(ihdr);
  // Padding so different "images" of the same size get different digests.
  bytes.add(List.filled(64 + noise, noise & 0xFF));
  return bytes.toBytes();
}

/// Builds a JPEG whose SOF0 segment carries the requested dimensions.
Uint8List fakeJpeg(int width, int height) {
  final bytes = BytesBuilder();
  bytes.add([0xFF, 0xD8]); // SOI
  // An APP0 segment first, so the probe has to walk the chain rather than
  // assuming the first segment is the frame header.
  bytes.add([0xFF, 0xE0, 0x00, 0x10]);
  bytes.add(List.filled(14, 0));
  // SOF0: length, precision, height, width, components.
  bytes.add([0xFF, 0xC0, 0x00, 0x11, 0x08]);
  bytes.add([(height >> 8) & 0xFF, height & 0xFF]);
  bytes.add([(width >> 8) & 0xFF, width & 0xFF]);
  bytes.add(List.filled(10, 0));
  bytes.add([0xFF, 0xD9]); // EOI
  return bytes.toBytes();
}

void main() {
  group('image probe', () {
    test('reads PNG dimensions', () {
      final info = ImageProbe.probeBytes(fakePng(1400, 1400));
      expect(info, isNotNull);
      expect(info!.mimeType, 'image/png');
      expect(info.width, 1400);
      expect(info.height, 1400);
      expect(info.isPlausibleArtwork, isTrue);
    });

    test('reads JPEG dimensions by walking the segment chain', () {
      final info = ImageProbe.probeBytes(fakeJpeg(640, 480));
      expect(info, isNotNull);
      expect(info!.mimeType, 'image/jpeg');
      expect(info.width, 640);
      expect(info.height, 480);
    });

    test('reads GIF and BMP', () {
      final gif = BytesBuilder()
        ..add('GIF89a'.codeUnits)
        ..add([0x20, 0x00, 0x10, 0x00])
        ..add(List.filled(8, 0));
      final gifInfo = ImageProbe.probeBytes(gif.toBytes());
      expect(gifInfo?.mimeType, 'image/gif');
      expect(gifInfo?.width, 32);
      expect(gifInfo?.height, 16);

      final bmp = Uint8List(64);
      bmp.setRange(0, 2, 'BM'.codeUnits);
      final bmpView = ByteData.view(bmp.buffer);
      bmpView.setUint32(18, 800, Endian.little);
      bmpView.setUint32(22, 600, Endian.little);
      final bmpInfo = ImageProbe.probeBytes(bmp);
      expect(bmpInfo?.mimeType, 'image/bmp');
      expect(bmpInfo?.width, 800);
      expect(bmpInfo?.height, 600);
    });

    test('rejects non-images without throwing', () {
      expect(ImageProbe.probeBytes(Uint8List.fromList(List.filled(64, 9))),
          isNull);
      expect(ImageProbe.probeBytes(Uint8List(0)), isNull);
      expect(ImageProbe.probeBytes(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('flags small images as implausible artwork', () {
      // Icons and thumbnails should not be adopted as cover art.
      expect(ImageProbe.probeBytes(fakePng(48, 48))!.isPlausibleArtwork,
          isFalse);
      expect(ImageProbe.probeBytes(fakePng(500, 500))!.isPlausibleArtwork,
          isTrue);
    });

    test('probeFile returns null for a missing file', () {
      expect(ImageProbe.probeFile(File('nope.png')), isNull);
    });
  });

  group('sidecar discovery', () {
    late Directory dir;
    const finder = ArtSidecarFinder();

    setUp(() => dir = Directory.systemTemp.createTempSync('marmelade_art_'));
    tearDown(() => dir.deleteSync(recursive: true));

    void write(String name, Uint8List bytes) =>
        File(p.join(dir.path, name)).writeAsBytesSync(bytes);

    test('prefers cover.jpg over an arbitrary image', () {
      write('cover.jpg', fakeJpeg(1000, 1000));
      write('screenshot.png', fakePng(1000, 1000, noise: 1));
      final best = finder.forAlbumFolder(dir).first;
      expect(p.basename(best.file.path), 'cover.jpg');
      expect(best.role, ImageRole.front);
      expect(best.reason, contains('cover'));
    });

    test('honours the conventional ordering of cover names', () {
      write('album.png', fakePng(1000, 1000, noise: 1));
      write('folder.png', fakePng(1000, 1000, noise: 2));
      write('cover.png', fakePng(1000, 1000, noise: 3));
      final ordered = finder
          .forAlbumFolder(dir)
          .map((c) => p.basenameWithoutExtension(c.file.path))
          .toList();
      expect(ordered.take(3), ['cover', 'folder', 'album']);
    });

    test('a per-track image beats every folder convention', () {
      write('cover.jpg', fakeJpeg(1000, 1000));
      write('01 My Song.png', fakePng(1000, 1000, noise: 5));
      final audio = File(p.join(dir.path, '01 My Song.mp3'))
        ..writeAsBytesSync([0]);
      final best = finder.forAudioFile(audio).first;
      expect(p.basename(best.file.path), '01 My Song.png');
      expect(best.reason, contains('audio file name'));
    });

    test('recognises both artist naming conventions', () {
      // Taken from a real library: bare "artist.jpg" and "<Name>_artist.jpg".
      write('artist.jpg', fakeJpeg(800, 800));
      final bare = finder.forArtistFolder(dir);
      expect(bare, hasLength(1));
      expect(bare.single.role, ImageRole.artist);

      final other = Directory.systemTemp.createTempSync('marmelade_art2_');
      addTearDown(() => other.deleteSync(recursive: true));
      File(p.join(other.path, 'PYKAMIA_artist.jpg'))
          .writeAsBytesSync(fakeJpeg(800, 800));
      final suffixed = finder.forArtistFolder(other);
      expect(suffixed, hasLength(1));
      expect(suffixed.single.role, ImageRole.artist);
    });

    test('ignores .ico files sitting beside the artwork', () {
      // The real library keeps an .ico next to every artist.jpg, for folder
      // icons. It is not artwork.
      write('artist.jpg', fakeJpeg(800, 800));
      File(p.join(dir.path, 'artist.ico')).writeAsBytesSync([0, 0, 1, 0]);
      final found = finder.forAlbumFolder(dir);
      expect(found, hasLength(1));
      expect(p.extension(found.single.file.path), '.jpg');
    });

    test('ignores icons and extreme aspect ratios', () {
      write('tiny.png', fakePng(32, 32));
      write('banner.png', fakePng(2000, 200, noise: 1));
      expect(finder.forAlbumFolder(dir), isEmpty);
    });

    test('classifies back and disc images', () {
      write('cover.jpg', fakeJpeg(1000, 1000));
      write('back.png', fakePng(1000, 1000, noise: 1));
      write('disc.png', fakePng(1000, 1000, noise: 2));
      final byRole = {
        for (final c in finder.forAlbumFolder(dir)) c.role: c,
      };
      expect(byRole[ImageRole.front], isNotNull);
      expect(byRole[ImageRole.back], isNotNull);
      expect(byRole[ImageRole.disc], isNotNull);
    });

    test('picks the larger image when names are equally convincing', () {
      write('shot-a.png', fakePng(600, 600, noise: 1));
      write('shot-b.png', fakePng(1400, 1400, noise: 2));
      final best = finder.forAlbumFolder(dir).first;
      expect(best.info.width, 1400);
    });

    test('an empty or missing folder yields nothing', () {
      expect(finder.forAlbumFolder(dir), isEmpty);
      expect(finder.forAlbumFolder(Directory('nowhere')), isEmpty);
    });

    test('extracts an artist name from a collection folder', () {
      expect(ArtSidecarFinder.artistNameFromFolder('[Collection] PinocchioP'),
          'PinocchioP');
      expect(ArtSidecarFinder.artistNameFromFolder('[collection]  Rigel  '),
          'Rigel');
      expect(ArtSidecarFinder.artistNameFromFolder('(Artist) Camellia'),
          'Camellia');
      // An ordinary folder name must not be mistaken for an artist.
      expect(ArtSidecarFinder.artistNameFromFolder('Greatest Hits'), isNull);
      expect(ArtSidecarFinder.artistNameFromFolder('[Collection]'), isNull);
    });
  });

  group('art store', () {
    late Directory root;
    late ArtStore store;

    setUp(() {
      root = Directory.systemTemp.createTempSync('marmelade_store_');
      store = ArtStore(root);
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('stores an image and reports its dimensions', () async {
      final stored = await store.putBytes(fakePng(1200, 1200));
      expect(stored, isNotNull);
      expect(stored!.width, 1200);
      expect(stored.mimeType, 'image/png');
      expect(stored.wasAlreadyStored, isFalse);
      expect(await store.exists(stored.storedPath), isTrue);
      // Content-addressed: the path is derived from the digest.
      expect(stored.storedPath, contains(stored.sha256));
      expect(p.split(stored.storedPath).first, stored.sha256.substring(0, 2));
    });

    test('deduplicates identical images', () async {
      // The whole reason for content addressing: one cover embedded in fifty
      // tracks must occupy one file.
      final first = await store.putBytes(fakePng(1200, 1200));
      final second = await store.putBytes(fakePng(1200, 1200));
      expect(second!.sha256, first!.sha256);
      expect(second.storedPath, first.storedPath);
      expect(second.wasAlreadyStored, isTrue);

      var files = 0;
      await for (final e in root.list(recursive: true)) {
        if (e is File) files++;
      }
      expect(files, 1);
    });

    test('different images get different paths', () async {
      final a = await store.putBytes(fakePng(1200, 1200, noise: 1));
      final b = await store.putBytes(fakePng(1200, 1200, noise: 2));
      expect(a!.sha256, isNot(b!.sha256));
      expect(a.storedPath, isNot(b.storedPath));
    });

    test('rejects bytes that are not an image', () async {
      expect(await store.putBytes(Uint8List.fromList(List.filled(99, 3))),
          isNull);
      expect(await store.putBytes(Uint8List(0)), isNull);
    });

    test('stores from a file and survives a missing one', () async {
      final source = File(p.join(root.path, 'source.png'))
        ..writeAsBytesSync(fakePng(900, 900));
      final stored = await store.putFile(source);
      expect(stored?.width, 900);
      expect(await store.putFile(File('nope.png')), isNull);
    });

    test('leaves no temporary file behind', () async {
      await store.putBytes(fakePng(1000, 1000));
      final names = <String>[];
      await for (final e in root.list(recursive: true)) {
        if (e is File) names.add(p.basename(e.path));
      }
      expect(names.where((n) => n.endsWith('.tmp')), isEmpty);
    });

    test('reports total size', () async {
      expect(await store.totalBytes(), 0);
      final stored = await store.putBytes(fakePng(1000, 1000));
      expect(await store.totalBytes(), stored!.byteSize);
    });

    test('prunes only unreferenced images', () async {
      final keep = await store.putBytes(fakePng(1000, 1000, noise: 1));
      final drop = await store.putBytes(fakePng(1000, 1000, noise: 2));

      final deleted = await store.pruneUnreferenced({keep!.sha256});
      expect(deleted, 1);
      expect(await store.exists(keep.storedPath), isTrue);
      expect(await store.exists(drop!.storedPath), isFalse);
    });

    test('delete removes a stored image', () async {
      final stored = await store.putBytes(fakePng(1000, 1000));
      await store.delete(stored!.storedPath);
      expect(await store.exists(stored.storedPath), isFalse);
      // Deleting twice is not an error.
      await store.delete(stored.storedPath);
    });
  });
}
