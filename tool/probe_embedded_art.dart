// Reports what the tag reader actually finds inside a file.
//
// Read-only. Written for the case where the scanner says it looked and found
// nothing: this says whether the file is there, whether it parses, and
// whether it carries a picture -- three different failures that look
// identical from the outside.
//
//   dart run tool/probe_embedded_art.dart <file> [more files...]
import 'dart:io';

import 'package:marmelade/data/metadata/tag_reader.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/probe_embedded_art.dart <file>...');
    exit(64);
  }

  const reader = TagReader();
  for (final path in args) {
    final file = File(path);
    stdout.writeln('--- $path');
    if (!file.existsSync()) {
      stdout.writeln('  MISSING on disk');
      continue;
    }
    stdout.writeln('  exists, ${file.lengthSync()} bytes');

    try {
      final plain = reader.read(file);
      stdout.writeln('  parses: title=${plain.title} album=${plain.albumTitle}');
    } catch (error) {
      stdout.writeln('  PARSE FAILED without pictures: $error');
      continue;
    }

    try {
      final withPictures = reader.read(file, includePictures: true);
      if (withPictures.pictures.isEmpty) {
        stdout.writeln('  no pictures reported');
      } else {
        for (final picture in withPictures.pictures) {
          stdout.writeln(
            '  picture: ${picture.mimeType} ${picture.bytes.length} bytes '
            'role=${picture.role}',
          );
        }
      }
    } catch (error) {
      stdout.writeln('  PARSE FAILED with pictures: $error');
    }
  }
}
