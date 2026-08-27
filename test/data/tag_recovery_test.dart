import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/fs/vorbis_comments.dart';
import 'package:marmelade/data/metadata/tag_reader.dart';
import 'package:path/path.dart' as p;

/// Covers reading tags that are legal in the wild but that the underlying
/// metadata package refuses.
///
/// The case that prompted this: a vinyl release tagged `DISCNUMBER=A`. The
/// package calls `int.parse` on it, throws, and the whole file is lost - which
/// on a real library silently removed 46 tracks from one soundtrack folder.
String get _fixtureDir =>
    Platform.environment['MARMELADE_FIXTURES'] ??
    r'C:\Users\makrofon\Music\testZiks\_marmelade_fixtures';

void main() {
  const reader = TagReader();
  final available = Directory(_fixtureDir).existsSync();

  File fixture(String name) => File(p.join(_fixtureDir, name));

  group('FLAC stream info', () {
    test('reads sample rate, channels, depth and duration', () {
      final info = FlacVorbisReader.readStreamInfo(fixture('20 flac-tagged.flac'));
      expect(info, isNotNull);
      expect(info!.sampleRate, 44100);
      expect(info.channels, 2);
      expect(info.bitsPerSample, 24);
      // The fixture is a 12-second clip.
      expect(info.duration!.inSeconds, closeTo(12, 1));
      expect(info.bitrate, greaterThan(0));
    });

    test('reads a hi-res file', () {
      final info = FlacVorbisReader.readStreamInfo(fixture('21 flac-hires.flac'));
      expect(info!.sampleRate, 48000);
    });

    test('returns null for a file that is not FLAC', () {
      expect(FlacVorbisReader.readStreamInfo(fixture('01 multi-x.mp3')), isNull);
      expect(FlacVorbisReader.readStreamInfo(File('nope.flac')), isNull);
    });
  }, skip: available ? null : 'fixtures not present at $_fixtureDir');

  group('recovering a FLAC the package rejects', () {
    test('a non-numeric disc number does not lose the track', () {
      final file = fixture('40 flac-discnumber-letter.flac');
      expect(file.existsSync(), isTrue);

      final metadata = reader.read(file);

      // The whole point: the track survives, with its text intact.
      expect(metadata.title, 'Vinyl Side Label');
      expect(metadata.albumTitle, 'Awkward Tags');
      expect(metadata.credits.map((c) => c.value), ['From Grotto']);
      expect(metadata.trackNo, 1);
      // The offending field is dropped rather than allowed to fail again.
      expect(metadata.discNo, isNull);
      // And it came through the recovery path, not the normal one.
      expect(metadata.tagFormat, contains('recovered'));
    });

    test('recovery still reports real audio properties', () {
      final metadata = reader.read(fixture('40 flac-discnumber-letter.flac'));
      expect(metadata.lossless, isTrue);
      expect(metadata.codec, 'flac');
      expect(metadata.sampleRate, 44100);
      expect(metadata.bitDepth, 24);
      expect(metadata.channels, 2);
      expect(metadata.duration, isNotNull);
      expect(metadata.duration!.inSeconds, closeTo(12, 1));
    });

    test('a well-formed FLAC still takes the normal path', () {
      final metadata = reader.read(fixture('20 flac-tagged.flac'));
      expect(metadata.tagFormat, isNot(contains('recovered')));
      expect(metadata.title, 'Proper Multivalue FLAC');
    });

    test('a file that is not really audio still throws', () {
      // Recovery must not turn genuinely broken files into empty tracks.
      final junk = File(p.join(Directory.systemTemp.path, 'marmelade_junk.flac'))
        ..writeAsBytesSync(List.filled(4096, 3));
      addTearDown(() => junk.deleteSync());
      expect(() => reader.read(junk), throwsA(anything));
      expect(reader.tryRead(junk), isNull);
    });
  }, skip: available ? null : 'fixtures not present at $_fixtureDir');
}
