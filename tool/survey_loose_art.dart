// Replays the artwork repair pass's own query and says, for every row, why
// it did or did not produce a picture.
//
// Read-only on the database. Written because the pass logged "checked=200,
// found=0" over files that demonstrably carry cover art: four different
// failures -- file gone, parse threw, no picture, bytes rejected -- all look
// identical from the log line.
//
//   dart run tool/survey_loose_art.dart <database> [folderId] [limit]
import 'dart:io';

import 'package:marmelade/data/db/enums.dart';
import 'package:marmelade/data/fs/image_probe.dart';
import 'package:marmelade/data/metadata/tag_reader.dart';
import 'package:marmelade/data/metadata/track_metadata.dart';
import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/survey_loose_art.dart <db> [folderId] [limit]',
    );
    exit(64);
  }
  final folderId = args.length > 1 ? int.parse(args[1]) : 0;
  final limit = args.length > 2 ? int.parse(args[2]) : 0;
  final db = sqlite3.open(args[0], mode: OpenMode.readOnly);

  final rows = db.select('''
    SELECT t.id AS track_id, t.title AS title,
      lf.path AS folder_path, mf.relative_path AS relative_path
    FROM tracks t
    JOIN media_files mf ON mf.track_id = t.id
    JOIN library_folders lf ON lf.id = mf.folder_id
    WHERE t.album_id IS NULL
      AND t.image_id IS NULL
      AND mf.status = 'present'
      ${folderId == 0 ? '' : 'AND mf.folder_id = $folderId'}
    ${limit == 0 ? '' : 'LIMIT $limit'}
  ''');

  const reader = TagReader();
  var gone = 0;
  var threw = 0;
  var noPicture = 0;
  var rejected = 0;
  var ok = 0;
  final samples = <String>[];
  final started = DateTime.now();

  for (final row in rows) {
    final file = File('${row['folder_path']}/${row['relative_path']}');
    if (!file.existsSync()) {
      gone++;
      continue;
    }

    TrackFileMetadata meta;
    try {
      meta = reader.read(file, includePictures: true);
    } catch (error) {
      threw++;
      if (samples.length < 5) samples.add('threw: ${row['title']}  $error');
      continue;
    }

    if (meta.pictures.isEmpty) {
      noPicture++;
      continue;
    }
    final picture = meta.pictures.firstWhere(
      (pic) => pic.role == ImageRole.front,
      orElse: () => meta.pictures.first,
    );
    if (ImageProbe.probeBytes(picture.bytes) == null) {
      rejected++;
      if (samples.length < 5) {
        samples.add('rejected: ${row['title']}  ${picture.mimeType} '
            '${picture.bytes.length} bytes');
      }
      continue;
    }
    ok++;
  }

  stdout
    ..writeln('rows        : ${rows.length}'
        '${folderId == 0 ? '' : ' (folder $folderId)'}'
        '${limit == 0 ? '' : ' limit $limit'}')
    ..writeln('would store : $ok')
    ..writeln('no picture  : $noPicture')
    ..writeln('parse threw : $threw')
    ..writeln('bytes bad   : $rejected')
    ..writeln('file gone   : $gone')
    ..writeln('took        : '
        '${DateTime.now().difference(started).inMilliseconds} ms');
  for (final sample in samples) {
    stdout.writeln('  $sample');
  }

  db.close();
}
