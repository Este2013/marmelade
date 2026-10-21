// Reports why a track shows the artwork it does.
//
// Read-only, and meant to be pointed at a *copy* of a library: it answers
// "what does the database actually say" for one track, which is the question
// every artwork report turns into once the obvious explanation is ruled out.
//
//   dart run tool/inspect_track_art.dart <database> <title fragment>
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart run tool/inspect_track_art.dart <database> <title>',
    );
    exit(64);
  }

  final db = sqlite3.open(args[0], mode: OpenMode.readOnly);
  final like = '%${args[1]}%';

  final rows = db.select(
    '''
    SELECT t.id, t.title, t.album_id, t.image_id,
      al.title AS album_title, al.image_id AS album_image,
      lf.path AS folder_path, mf.relative_path AS relative_path,
      mf.status AS status, mf.folder_id AS folder_id,
      im.stored_path AS own_path,
      (SELECT im2.stored_path FROM v_track_artwork vt
        JOIN images im2 ON im2.id = vt.image_id
        WHERE vt.track_id = t.id) AS shown_path
    FROM tracks t
    LEFT JOIN albums al ON al.id = t.album_id
    LEFT JOIN media_files mf ON mf.track_id = t.id
    LEFT JOIN library_folders lf ON lf.id = mf.folder_id
    LEFT JOIN images im ON im.id = t.image_id
    WHERE t.title LIKE ?
    ''',
    [like],
  );

  if (rows.isEmpty) {
    stdout.writeln('no track matching "${args[1]}"');
    return;
  }

  for (final row in rows) {
    stdout
      ..writeln('--- ${row['title']} (track ${row['id']})')
      ..writeln('  album_id      : ${row['album_id']} ${row['album_title'] ?? ''}')
      ..writeln('  album image   : ${row['album_image']}')
      ..writeln('  track image_id: ${row['image_id']}  ${row['own_path'] ?? ''}')
      ..writeln('  view shows    : ${row['shown_path']}')
      ..writeln('  file status   : ${row['status']}  folder ${row['folder_id']}')
      ..writeln('  path          : ${row['folder_path']}/${row['relative_path']}');

    // The exact population the repair pass works on.
    final candidate = db.select(
      '''
      SELECT COUNT(*) AS n FROM tracks t
      JOIN media_files mf ON mf.track_id = t.id
      WHERE t.id = ? AND t.album_id IS NULL AND t.image_id IS NULL
        AND mf.status = 'present'
      ''',
      [row['id']],
    ).first['n'];
    stdout.writeln('  repair would see it: ${candidate == 1}');
  }

  final totals = db.select('''
    SELECT
      (SELECT COUNT(*) FROM tracks WHERE album_id IS NULL) AS loose,
      (SELECT COUNT(*) FROM tracks WHERE album_id IS NULL AND image_id IS NULL)
        AS loose_without_art,
      (SELECT COUNT(*) FROM tracks WHERE image_id IS NULL) AS no_track_image
  ''').first;
  stdout
    ..writeln()
    ..writeln('library: ${totals['loose']} tracks with no album, '
        '${totals['loose_without_art']} of those with no picture, '
        '${totals['no_track_image']} tracks with no picture of their own');

  db.close();
}
