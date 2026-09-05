import 'package:drift/drift.dart';

import '../../core/logging/app_log.dart';
import '../db/database.dart';

/// What the library still lists but can no longer play.
///
/// A file goes missing for two very different reasons and the database cannot
/// tell them apart: a drive is unplugged, or the music was deleted. So a scan
/// marks the file missing and keeps the row -- ratings, tags and play counts
/// survive a disconnected drive, which is the common case and the one where
/// throwing anything away would be unforgivable.
///
/// The cost of that caution is a library quietly filling with songs that do
/// not play. This is the other half: say plainly how much of it there is, and
/// offer the two honest answers -- put it out of sight until the drive is
/// back, or accept that it is gone and remove it.
class MissingFilesRepository {
  MissingFilesRepository(this.db);

  final MarmeladeDatabase db;

  /// A track counts as missing when it has files and none of them are here.
  static const _missingTracks = '''
    SELECT t.id FROM tracks t
     WHERE EXISTS (SELECT 1 FROM media_files mf WHERE mf.track_id = t.id)
       AND NOT EXISTS (SELECT 1 FROM media_files mf
                        WHERE mf.track_id = t.id AND mf.status = 'present')
  ''';

  /// Watches how much is missing, so a banner can appear and disappear on its
  /// own as drives come and go.
  Stream<MissingSummary> watch() {
    return db
        .customSelect(
          '''
          SELECT
            (SELECT COUNT(*) FROM ($_missingTracks)) AS tracks,
            (SELECT COUNT(*) FROM media_files WHERE status = 'missing')
              AS files,
            (SELECT COUNT(*) FROM albums al
              WHERE EXISTS (SELECT 1 FROM tracks t WHERE t.album_id = al.id)
                AND NOT EXISTS (
                  SELECT 1 FROM tracks t
                   WHERE t.album_id = al.id
                     AND EXISTS (SELECT 1 FROM media_files mf
                                  WHERE mf.track_id = t.id
                                    AND mf.status = 'present'))) AS albums
          ''',
          readsFrom: {db.tracks, db.mediaFiles, db.albums},
        )
        .watchSingle()
        .map((row) => MissingSummary(
              tracks: row.read<int>('tracks'),
              albums: row.read<int>('albums'),
              files: row.read<int>('files'),
            ));
  }

  /// The tracks themselves, for a list worth looking at before deciding.
  ///
  /// Capped: the decision is the same whether it is eighty songs or eight
  /// thousand, and a dialog that tries to render eight thousand rows helps
  /// nobody.
  Future<List<MissingTrack>> list({int limit = 200}) async {
    final rows = await db.customSelect(
      '''
      SELECT t.id AS id, t.title AS title, al.title AS album,
             (SELECT mf.relative_path FROM media_files mf
               WHERE mf.track_id = t.id ORDER BY mf.id LIMIT 1) AS path
        FROM tracks t
        LEFT JOIN albums al ON al.id = t.album_id
       WHERE t.id IN ($_missingTracks)
       ORDER BY al.title, t.sort_title, t.title
       LIMIT ?1
      ''',
      variables: [Variable(limit)],
      readsFrom: {db.tracks, db.albums, db.mediaFiles},
    ).get();

    return [
      for (final row in rows)
        MissingTrack(
          id: row.read<int>('id'),
          title: row.read<String>('title'),
          album: row.readNullable<String>('album'),
          path: row.readNullable<String>('path'),
        ),
    ];
  }

  /// Removes every track whose files are all gone, and the albums that empties.
  ///
  /// Deliberately not "delete anything marked missing": the unit is the
  /// track, because a song held as both FLAC and MP3 with one of the two
  /// still present has not gone anywhere.
  ///
  /// Artists are left alone even when nothing of theirs remains. An artist row
  /// carries links, aliases, a picture and tags that somebody chose by hand,
  /// none of which came from the files, and none of which is helped by being
  /// deleted along with them.
  Future<MissingRemoved> removeMissing() async {
    return db.transaction(() async {
      final ids = (await db.customSelect(_missingTracks, readsFrom: {
        db.tracks,
        db.mediaFiles,
      }).get())
          .map((row) => row.read<int>('id'))
          .toList();

      if (ids.isEmpty) return const MissingRemoved(tracks: 0, albums: 0);

      final list = ids.join(',');
      // The file rows go first and by hand: the foreign key nulls them out
      // rather than removing them, which would leave rows pointing at
      // nothing for a later scan to puzzle over.
      //
      // customUpdate rather than customStatement so drift is told which
      // tables changed. A plain statement writes the rows and announces
      // nothing, which leaves every open stream showing the library as it was
      // -- the warning would sit there naming songs that had just been
      // deleted.
      await db.customUpdate(
        'DELETE FROM media_files WHERE track_id IN ($list)',
        updates: {db.mediaFiles},
        updateKind: UpdateKind.delete,
      );
      await db.customUpdate(
        'DELETE FROM tracks WHERE id IN ($list)',
        updates: {db.tracks},
        updateKind: UpdateKind.delete,
      );

      // An album with nothing left in it is not a record any more.
      final albums = await db.customUpdate(
        'DELETE FROM albums WHERE NOT EXISTS '
        '(SELECT 1 FROM tracks t WHERE t.album_id = albums.id)',
        updates: {db.albums},
        updateKind: UpdateKind.delete,
      );

      AppLog.instance.warn('removed tracks whose files are gone', tag: 'library', fields: {
        'tracks': ids.length,
        'albums': albums,
      });
      return MissingRemoved(tracks: ids.length, albums: albums);
    });
  }
}

/// How much of the library has lost its files.
class MissingSummary {
  const MissingSummary({
    required this.tracks,
    required this.albums,
    required this.files,
  });

  static const none = MissingSummary(tracks: 0, albums: 0, files: 0);

  /// Tracks with no playable file left.
  final int tracks;

  /// Albums where that is true of every track.
  final int albums;

  /// Individual files, which can outnumber the tracks.
  final int files;

  bool get any => tracks > 0;
}

/// One song that cannot be played.
class MissingTrack {
  const MissingTrack({
    required this.id,
    required this.title,
    this.album,
    this.path,
  });

  final int id;
  final String title;
  final String? album;

  /// Where the file used to be, which is usually what identifies it.
  final String? path;
}

/// What removing them did.
class MissingRemoved {
  const MissingRemoved({required this.tracks, required this.albums});

  final int tracks;
  final int albums;
}
