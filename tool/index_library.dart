// Runs the real indexer against a folder and reports what landed in the
// database. Unlike index_dry_run.dart this writes: it creates a database and an
// artwork store, so it exercises the whole pipeline.
//
//   dart run tool/index_library.dart "C:/path/to/music" [--db out.db] [--keep]
//
// By default it works in a temporary directory and cleans up afterwards.
import 'dart:io';

import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/library_indexer.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('usage: dart run tool/index_library.dart <folder> '
        '[--db <path>] [--keep] [--content-keys]');
    exitCode = 64;
    return;
  }

  final musicPath = positional.first;
  if (!Directory(musicPath).existsSync()) {
    stderr.writeln('no such folder: $musicPath');
    exitCode = 66;
    return;
  }

  final keep = args.contains('--keep');
  final contentKeys = args.contains('--content-keys');
  final dbIndex = args.indexOf('--db');
  final workdir = Directory.systemTemp.createTempSync('marmelade_index_');
  final dbPath = dbIndex >= 0 && dbIndex + 1 < args.length
      ? args[dbIndex + 1]
      : p.join(workdir.path, 'marmelade.db');

  final db = await MarmeladeDatabase.open(dbPath);
  final artStore = ArtStore(Directory(p.join(workdir.path, 'artwork')));
  await artStore.root.create(recursive: true);

  final indexer = LibraryIndexer(
    db: db,
    artStore: artStore,
    computeContentKeys: contentKeys,
  );

  final started = DateTime.now();
  var lastPhase = '';
  final folderId = await indexer.addFolder(musicPath);
  final outcome = await indexer.indexFolder(
    folderId,
    onProgress: (progress) {
      if (progress.phase.name != lastPhase) {
        lastPhase = progress.phase.name;
        stdout.writeln('  [${progress.phase.name}]');
      } else if (progress.total > 0 && progress.completed % 100 == 0) {
        stdout.writeln('      ${progress.completed}/${progress.total}');
      }
    },
  );
  final wall = DateTime.now().difference(started);

  final out = StringBuffer();
  void h(String title) => out.writeln('\n=== $title '
      '${'=' * (66 - title.length).clamp(0, 66)}');

  h('OUTCOME');
  out.writeln('files seen     : ${outcome.filesSeen}');
  out.writeln('added          : ${outcome.filesAdded}');
  out.writeln('updated        : ${outcome.filesUpdated}');
  out.writeln('moved          : ${outcome.filesMoved}');
  out.writeln('missing        : ${outcome.filesMissing}');
  out.writeln('unreadable     : ${outcome.filesUnreadable}');
  out.writeln('tracks created : ${outcome.tracksCreated}');
  out.writeln('artists created: ${outcome.artistsCreated}');
  out.writeln('albums created : ${outcome.albumsCreated}');
  out.writeln('images stored  : ${outcome.imagesStored}');
  out.writeln('credits written: ${outcome.creditsWritten}');
  out.writeln('aliases learned: ${outcome.aliasesLearned}');
  out.writeln('needs review   : ${outcome.pendingCredits}');
  out.writeln('elapsed        : ${wall.inMilliseconds} ms '
      '(${(outcome.filesSeen / (wall.inMilliseconds / 1000)).round()} '
      'files/sec)');

  Future<int> count(String table) async => (await db
          .customSelect('SELECT COUNT(*) AS c FROM $table')
          .getSingle())
      .read<int>('c');

  h('DATABASE');
  for (final table in const [
    'media_files', 'tracks', 'artists', 'artist_aliases', 'albums',
    'track_credits', 'tags', 'track_tags', 'images', 'pending_credits',
    'scan_issues',
  ]) {
    out.writeln('${table.padRight(16)} ${await count(table)}');
  }
  final search = await indexer.searchIndexer.counts();
  out.writeln('${'search_tokens'.padRight(16)} ${search.tokens}');
  out.writeln('${'search_trigrams'.padRight(16)} ${search.trigrams}');
  out.writeln('artwork on disk  ${await artStore.totalBytes()} bytes');

  h('TOP ARTISTS BY TRACK COUNT');
  final top = await db.customSelect('''
    SELECT a.name, COUNT(DISTINCT tc.track_id) AS n,
           (a.image_id IS NOT NULL) AS has_art,
           (SELECT COUNT(*) FROM artist_aliases al WHERE al.artist_id = a.id)
             AS aliases
    FROM artists a
    JOIN track_credits tc ON tc.artist_id = a.id
    GROUP BY a.id ORDER BY n DESC LIMIT 20
  ''').get();
  for (final row in top) {
    out.writeln('  ${row.read<int>('n').toString().padLeft(4)}  '
        '${row.read<String>('name').padRight(34)} '
        '${row.read<int>('has_art') == 1 ? 'art' : '   '} '
        '${row.read<int>('aliases') > 0 ? "+${row.read<int>('aliases')} alias" : ''}');
  }

  h('ALBUMS');
  final albums = await db.customSelect('''
    SELECT al.title, COALESCE(ar.name, '(various)') AS artist,
           (SELECT COUNT(*) FROM tracks t WHERE t.album_id = al.id) AS n,
           (al.image_id IS NOT NULL) AS has_art
    FROM albums al LEFT JOIN artists ar ON ar.id = al.album_artist_id
    ORDER BY n DESC LIMIT 15
  ''').get();
  for (final row in albums) {
    out.writeln('  ${row.read<int>('n').toString().padLeft(3)} '
        '${row.read<int>('has_art') == 1 ? '[art]' : '[   ]'} '
        '${row.read<String>('title')}  --  ${row.read<String>('artist')}');
  }

  h('ARTWORK COVERAGE');
  final coverage = await db.customSelect('''
    SELECT
      (SELECT COUNT(*) FROM tracks) AS tracks,
      (SELECT COUNT(*) FROM v_track_artwork WHERE image_id IS NOT NULL)
        AS tracks_with_art,
      (SELECT COUNT(*) FROM albums) AS albums,
      (SELECT COUNT(*) FROM v_album_artwork WHERE image_id IS NOT NULL)
        AS albums_with_art
  ''').getSingle();
  out.writeln('  tracks resolving to artwork: '
      '${coverage.read<int>('tracks_with_art')} / '
      '${coverage.read<int>('tracks')}');
  out.writeln('  albums resolving to artwork: '
      '${coverage.read<int>('albums_with_art')} / '
      '${coverage.read<int>('albums')}');

  h('NEEDS REVIEW');
  final pending = await db.customSelect(
    'SELECT raw_credit, COUNT(*) AS n FROM pending_credits '
    'WHERE resolved_at IS NULL GROUP BY raw_credit ORDER BY n DESC',
  ).get();
  if (pending.isEmpty) {
    out.writeln('  nothing');
  }
  for (final row in pending) {
    out.writeln('  ${row.read<int>('n').toString().padLeft(3)}x  '
        '"${row.read<String>('raw_credit')}"');
  }

  h('MULTI-ARTIST TRACKS (a sample)');
  final multi = await db.customSelect('''
    SELECT t.title,
           group_concat(a.name || ' [' || tc.role || ']', ' + ') AS credits
    FROM tracks t
    JOIN track_credits tc ON tc.track_id = t.id
    JOIN artists a ON a.id = tc.artist_id
    GROUP BY t.id HAVING COUNT(*) > 1
    ORDER BY COUNT(*) DESC LIMIT 12
  ''').get();
  for (final row in multi) {
    out.writeln('  ${row.read<String>('title')}');
    out.writeln('      ${row.read<String>('credits')}');
  }

  h('SCAN ISSUES');
  final issues = await db.customSelect(
    'SELECT kind, COUNT(*) AS n FROM scan_issues GROUP BY kind',
  ).get();
  if (issues.isEmpty) out.writeln('  none');
  for (final row in issues) {
    out.writeln('  ${row.read<String>('kind')}: ${row.read<int>('n')}');
  }

  stdout.write(out.toString());
  stdout.writeln();

  await db.close();
  if (keep) {
    stdout.writeln('database kept at $dbPath');
  } else {
    workdir.deleteSync(recursive: true);
  }
}
