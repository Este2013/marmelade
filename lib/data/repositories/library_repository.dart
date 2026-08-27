import 'package:drift/drift.dart';

import '../../domain/models/library_views.dart';
import '../db/database.dart';

/// Reads the library for the screens that display it.
///
/// Queries are written by hand rather than composed from the generated query
/// builder, because these are the hot paths: an albums grid must be one query
/// for the whole grid, not one per card, and the artwork fallback chain has to
/// resolve inside SQL rather than by walking rows in Dart.
class LibraryRepository {
  LibraryRepository(this.db);

  final MarmeladeDatabase db;

  /// Album artwork joined through the fallback chain, as a path in the store.
  static const _albumArtJoin = '''
    LEFT JOIN v_album_artwork va ON va.album_id = al.id
    LEFT JOIN images ai ON ai.id = va.image_id
  ''';

  // ------------------------------------------------------------------ albums

  /// Watches the albums grid.
  ///
  /// [includeSingles] adds a synthetic entry for each track that belongs to no
  /// album, so loose singles are browsable rather than invisible. They are
  /// given negative ids to keep them distinguishable from real albums.
  Stream<List<AlbumCard>> watchAlbums({
    LibrarySort sort = LibrarySort.nameAscending,
    bool includeSingles = false,
    bool favouritesOnly = false,
  }) {
    final order = switch (sort) {
      LibrarySort.nameAscending => 'al.sort_title, al.title',
      LibrarySort.nameDescending => 'al.sort_title DESC, al.title DESC',
      LibrarySort.recentlyAdded => 'al.created_at DESC',
      LibrarySort.releaseYear => 'al.release_year DESC, al.title',
      LibrarySort.trackCount => 'track_count DESC, al.title',
      LibrarySort.duration => 'total_ms DESC, al.title',
      LibrarySort.random => 'RANDOM()',
      _ => 'al.sort_title, al.title',
    };

    final favouriteFilter = favouritesOnly ? 'WHERE al.is_favorite = 1' : '';

    return db.customSelect(
      '''
      SELECT
        al.id AS id,
        al.title AS title,
        al.release_year AS release_year,
        al.is_various_artists AS is_various_artists,
        al.is_favorite AS is_favorite,
        ar.id AS artist_id,
        ar.name AS artist_name,
        ai.stored_path AS image_path,
        (SELECT COUNT(*) FROM tracks t WHERE t.album_id = al.id) AS track_count,
        (SELECT COALESCE(SUM(t.duration_ms), 0) FROM tracks t
          WHERE t.album_id = al.id) AS total_ms
      FROM albums al
      LEFT JOIN artists ar ON ar.id = al.album_artist_id
      $_albumArtJoin
      $favouriteFilter
      ORDER BY $order
      ''',
      readsFrom: {db.albums, db.artists, db.tracks, db.images},
    ).watch().asyncMap((rows) async {
      final albums = [
        for (final row in rows)
          AlbumCard(
            id: row.read<int>('id'),
            title: row.read<String>('title'),
            artistName: row.read<String?>('artist_name') ??
                (row.read<int>('is_various_artists') == 1
                    ? 'Various Artists'
                    : 'Unknown artist'),
            artistId: row.read<int?>('artist_id'),
            trackCount: row.read<int>('track_count'),
            imagePath: row.read<String?>('image_path'),
            releaseYear: row.read<int?>('release_year'),
            isVariousArtists: row.read<int>('is_various_artists') == 1,
            isFavorite: row.read<int>('is_favorite') == 1,
            totalDurationMs: row.read<int>('total_ms'),
          ),
      ];
      if (!includeSingles) return albums;
      return [...albums, ...await _singlesAsCards(sort)];
    });
  }

  /// Tracks with no album, presented as one-track album cards.
  Future<List<AlbumCard>> _singlesAsCards(LibrarySort sort) async {
    final rows = await db.customSelect(
      '''
      SELECT
        t.id AS id,
        t.title AS title,
        t.release_year AS release_year,
        t.is_favorite AS is_favorite,
        COALESCE(t.duration_ms, 0) AS total_ms,
        ti.stored_path AS image_path,
        (SELECT ar.id FROM track_credits tc
          JOIN artists ar ON ar.id = tc.artist_id
         WHERE tc.track_id = t.id AND tc.role = 'mainArtist'
         ORDER BY tc.sort_order LIMIT 1) AS artist_id,
        (SELECT ar.name FROM track_credits tc
          JOIN artists ar ON ar.id = tc.artist_id
         WHERE tc.track_id = t.id AND tc.role = 'mainArtist'
         ORDER BY tc.sort_order LIMIT 1) AS artist_name
      FROM tracks t
      LEFT JOIN v_track_artwork vt ON vt.track_id = t.id
      LEFT JOIN images ti ON ti.id = vt.image_id
      WHERE t.album_id IS NULL
      ORDER BY t.sort_title, t.title
      ''',
    ).get();

    return [
      for (final row in rows)
        AlbumCard(
          // Negative ids mark synthetic single entries, so a tap can be routed
          // to the track rather than to a non-existent album.
          id: -row.read<int>('id'),
          title: row.read<String>('title'),
          artistName: row.read<String?>('artist_name') ?? 'Unknown artist',
          artistId: row.read<int?>('artist_id'),
          trackCount: 1,
          imagePath: row.read<String?>('image_path'),
          releaseYear: row.read<int?>('release_year'),
          isFavorite: row.read<int>('is_favorite') == 1,
          totalDurationMs: row.read<int>('total_ms'),
        ),
    ];
  }

  /// Loads one album card.
  Future<AlbumCard?> album(int albumId) async {
    final row = await db.customSelect(
      '''
      SELECT al.id AS id, al.title AS title, al.release_year AS release_year,
             al.is_various_artists AS is_various_artists,
             al.is_favorite AS is_favorite,
             ar.id AS artist_id, ar.name AS artist_name,
             ai.stored_path AS image_path,
             (SELECT COUNT(*) FROM tracks t WHERE t.album_id = al.id)
               AS track_count,
             (SELECT COALESCE(SUM(t.duration_ms), 0) FROM tracks t
               WHERE t.album_id = al.id) AS total_ms
      FROM albums al
      LEFT JOIN artists ar ON ar.id = al.album_artist_id
      $_albumArtJoin
      WHERE al.id = ?
      ''',
      variables: [Variable(albumId)],
    ).getSingleOrNull();
    if (row == null) return null;

    return AlbumCard(
      id: row.read<int>('id'),
      title: row.read<String>('title'),
      artistName: row.read<String?>('artist_name') ??
          (row.read<int>('is_various_artists') == 1
              ? 'Various Artists'
              : 'Unknown artist'),
      artistId: row.read<int?>('artist_id'),
      trackCount: row.read<int>('track_count'),
      imagePath: row.read<String?>('image_path'),
      releaseYear: row.read<int?>('release_year'),
      isVariousArtists: row.read<int>('is_various_artists') == 1,
      isFavorite: row.read<int>('is_favorite') == 1,
      totalDurationMs: row.read<int>('total_ms'),
    );
  }

  // ------------------------------------------------------------------ tracks

  /// Watches every track, or the tracks of one album, artist or tag.
  Stream<List<TrackRow>> watchTracks({
    int? albumId,
    int? artistId,
    int? tagId,
    int? trackId,
    LibrarySort sort = LibrarySort.nameAscending,
    int? limit,
  }) {
    final where = <String>[];
    final variables = <Variable<Object>>[];

    if (trackId != null) {
      where.add('t.id = ?');
      variables.add(Variable(trackId));
    }
    if (albumId != null) {
      where.add('t.album_id = ?');
      variables.add(Variable(albumId));
    }
    if (artistId != null) {
      // Any credit counts, not just the main one, so an artist's page shows the
      // work they guested on too.
      where.add('EXISTS (SELECT 1 FROM track_credits tc '
          'WHERE tc.track_id = t.id AND tc.artist_id = ?)');
      variables.add(Variable(artistId));
    }
    if (tagId != null) {
      where.add('EXISTS (SELECT 1 FROM track_tags tt '
          'WHERE tt.track_id = t.id AND tt.tag_id = ?)');
      variables.add(Variable(tagId));
    }

    final order = switch (sort) {
      LibrarySort.nameAscending => 't.sort_title, t.title',
      LibrarySort.nameDescending => 't.sort_title DESC',
      LibrarySort.recentlyAdded => 't.added_at DESC',
      LibrarySort.recentlyPlayed => 't.last_played_at DESC',
      LibrarySort.mostPlayed => 't.play_count DESC, t.title',
      LibrarySort.releaseYear => 't.release_year DESC, t.title',
      LibrarySort.duration => 't.duration_ms DESC',
      LibrarySort.random => 'RANDOM()',
      // Disc and track order. Tracks with no number sort last rather than
      // first, since a NULL track number means "unknown", not "track zero".
      LibrarySort.trackNumber =>
        'COALESCE(t.disc_no, 1), t.track_no IS NULL, t.track_no, t.title',
      _ => 't.sort_title, t.title',
    };

    return db.customSelect(
      '''
      SELECT
        t.id AS id, t.title AS title, COALESCE(t.duration_ms, 0) AS duration_ms,
        t.album_id AS album_id, t.track_no AS track_no, t.disc_no AS disc_no,
        t.rating AS rating, t.is_favorite AS is_favorite,
        t.play_count AS play_count,
        alb.title AS album_title,
        ti.stored_path AS image_path,
        (SELECT MAX(mf.lossless) FROM media_files mf WHERE mf.track_id = t.id)
          AS lossless,
        (SELECT COUNT(*) FROM media_files mf
          WHERE mf.track_id = t.id AND mf.status = 'present') AS present_files
      FROM tracks t
      LEFT JOIN albums alb ON alb.id = t.album_id
      LEFT JOIN v_track_artwork vt ON vt.track_id = t.id
      LEFT JOIN images ti ON ti.id = vt.image_id
      ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY $order
      ${limit == null ? '' : 'LIMIT $limit'}
      ''',
      variables: variables,
      readsFrom: {
        db.tracks,
        db.albums,
        db.images,
        db.mediaFiles,
        db.trackCredits,
        db.trackTags,
      },
    ).watch().asyncMap((rows) async {
      if (rows.isEmpty) return const <TrackRow>[];
      final ids = rows.map((r) => r.read<int>('id')).toList();
      final credits = await _creditsFor(ids);

      return [
        for (final row in rows)
          TrackRow(
            id: row.read<int>('id'),
            title: row.read<String>('title'),
            credits: credits[row.read<int>('id')] ?? const [],
            durationMs: row.read<int>('duration_ms'),
            albumId: row.read<int?>('album_id'),
            albumTitle: row.read<String?>('album_title'),
            trackNo: row.read<int?>('track_no'),
            discNo: row.read<int?>('disc_no'),
            imagePath: row.read<String?>('image_path'),
            rating: row.read<int?>('rating'),
            isFavorite: row.read<int>('is_favorite') == 1,
            playCount: row.read<int>('play_count'),
            isMissing: row.read<int>('present_files') == 0,
            lossless: (row.read<int?>('lossless') ?? 0) == 1,
          ),
      ];
    });
  }

  /// Loads the credits for many tracks in one query.
  ///
  /// One query for the whole page rather than one per row; a list of a thousand
  /// tracks would otherwise issue a thousand queries.
  Future<Map<int, List<TrackCreditRef>>> _creditsFor(List<int> trackIds) async {
    if (trackIds.isEmpty) return const {};
    final placeholders = List.filled(trackIds.length, '?').join(',');
    final rows = await db.customSelect(
      '''
      SELECT tc.track_id AS track_id, tc.role AS role,
             tc.credited_as AS credited_as,
             ar.id AS artist_id, ar.name AS name
      FROM track_credits tc
      JOIN artists ar ON ar.id = tc.artist_id
      WHERE tc.track_id IN ($placeholders)
      ORDER BY tc.track_id, tc.sort_order, tc.id
      ''',
      variables: [for (final id in trackIds) Variable(id)],
    ).get();

    final result = <int, List<TrackCreditRef>>{};
    for (final row in rows) {
      (result[row.read<int>('track_id')] ??= []).add(TrackCreditRef(
        artistId: row.read<int>('artist_id'),
        name: row.read<String>('name'),
        role: row.read<String>('role'),
        creditedAs: row.read<String?>('credited_as'),
      ));
    }
    return result;
  }

  // ----------------------------------------------------------------- artists

  /// Watches the artists and groups list.
  Stream<List<ArtistCard>> watchArtists({
    LibrarySort sort = LibrarySort.nameAscending,
    bool groupsOnly = false,
    bool withTracksOnly = true,
  }) {
    final filters = <String>[];
    if (groupsOnly) filters.add("a.kind IN ('group', 'orchestra')");
    if (withTracksOnly) {
      filters.add('EXISTS (SELECT 1 FROM track_credits tc '
          'WHERE tc.artist_id = a.id)');
    }

    final order = switch (sort) {
      LibrarySort.nameDescending => 'a.sort_name DESC, a.name DESC',
      LibrarySort.trackCount => 'track_count DESC, a.name',
      LibrarySort.recentlyAdded => 'a.created_at DESC',
      LibrarySort.random => 'RANDOM()',
      _ => 'a.sort_name, a.name',
    };

    return db.customSelect(
      '''
      SELECT
        a.id AS id, a.name AS name, a.kind AS kind,
        a.is_favorite AS is_favorite,
        im.stored_path AS image_path,
        (SELECT COUNT(DISTINCT tc.track_id) FROM track_credits tc
          WHERE tc.artist_id = a.id) AS track_count,
        (SELECT COUNT(DISTINCT t.album_id) FROM track_credits tc
          JOIN tracks t ON t.id = tc.track_id
         WHERE tc.artist_id = a.id AND t.album_id IS NOT NULL) AS album_count,
        (SELECT COUNT(*) FROM artist_aliases al WHERE al.artist_id = a.id)
          AS alias_count,
        (SELECT COUNT(*) FROM artist_memberships m WHERE m.group_id = a.id)
          AS member_count
      FROM artists a
      LEFT JOIN images im ON im.id = a.image_id
      ${filters.isEmpty ? '' : 'WHERE ${filters.join(' AND ')}'}
      ORDER BY $order
      ''',
      readsFrom: {
        db.artists,
        db.trackCredits,
        db.tracks,
        db.artistAliases,
        db.artistMemberships,
        db.images,
      },
    ).watch().map((rows) => [
          for (final row in rows)
            ArtistCard(
              id: row.read<int>('id'),
              name: row.read<String>('name'),
              kind: row.read<String>('kind'),
              trackCount: row.read<int>('track_count'),
              albumCount: row.read<int>('album_count'),
              imagePath: row.read<String?>('image_path'),
              aliasCount: row.read<int>('alias_count'),
              memberCount: row.read<int>('member_count'),
              isFavorite: row.read<int>('is_favorite') == 1,
            ),
        ]);
  }

  /// Albums an artist appears on, in any role.
  Stream<List<AlbumCard>> watchArtistAlbums(int artistId) {
    return db.customSelect(
      '''
      SELECT DISTINCT
        al.id AS id, al.title AS title, al.release_year AS release_year,
        al.is_various_artists AS is_various_artists,
        al.is_favorite AS is_favorite,
        ar.id AS artist_id, ar.name AS artist_name,
        ai.stored_path AS image_path,
        (SELECT COUNT(*) FROM tracks t WHERE t.album_id = al.id) AS track_count,
        (SELECT COALESCE(SUM(t.duration_ms), 0) FROM tracks t
          WHERE t.album_id = al.id) AS total_ms
      FROM albums al
      LEFT JOIN artists ar ON ar.id = al.album_artist_id
      $_albumArtJoin
      WHERE al.album_artist_id = ?
         OR EXISTS (SELECT 1 FROM tracks t
                     JOIN track_credits tc ON tc.track_id = t.id
                    WHERE t.album_id = al.id AND tc.artist_id = ?)
      ORDER BY al.release_year DESC, al.sort_title
      ''',
      variables: [Variable(artistId), Variable(artistId)],
      readsFrom: {db.albums, db.artists, db.tracks, db.trackCredits, db.images},
    ).watch().map((rows) => [
          for (final row in rows)
            AlbumCard(
              id: row.read<int>('id'),
              title: row.read<String>('title'),
              artistName:
                  row.read<String?>('artist_name') ?? 'Various Artists',
              artistId: row.read<int?>('artist_id'),
              trackCount: row.read<int>('track_count'),
              imagePath: row.read<String?>('image_path'),
              releaseYear: row.read<int?>('release_year'),
              isVariousArtists: row.read<int>('is_various_artists') == 1,
              isFavorite: row.read<int>('is_favorite') == 1,
              totalDurationMs: row.read<int>('total_ms'),
            ),
        ]);
  }

  // -------------------------------------------------------------------- tags

  /// Watches the tag list, grouped by category.
  Stream<List<TagCard>> watchTags({int? categoryId}) {
    return db.customSelect(
      '''
      SELECT
        tg.id AS id, tg.name AS name, tg.category_id AS category_id,
        COALESCE(tg.color, c.color) AS color,
        c.name AS category_name,
        im.stored_path AS image_path,
        (SELECT COUNT(*) FROM track_tags tt WHERE tt.tag_id = tg.id)
          AS track_count,
        (SELECT COUNT(*) FROM tags child WHERE child.parent_tag_id = tg.id)
          AS child_count
      FROM tags tg
      LEFT JOIN tag_categories c ON c.id = tg.category_id
      LEFT JOIN images im ON im.id = tg.image_id
      ${categoryId == null ? '' : 'WHERE tg.category_id = ?'}
      ORDER BY c.sort_order, c.name, tg.sort_order, tg.name
      ''',
      variables: categoryId == null ? const [] : [Variable(categoryId)],
      readsFrom: {db.tags, db.tagCategories, db.trackTags, db.images},
    ).watch().map((rows) => [
          for (final row in rows)
            TagCard(
              id: row.read<int>('id'),
              name: row.read<String>('name'),
              trackCount: row.read<int>('track_count'),
              categoryId: row.read<int?>('category_id'),
              categoryName: row.read<String?>('category_name'),
              color: row.read<int?>('color'),
              imagePath: row.read<String?>('image_path'),
              childCount: row.read<int>('child_count'),
            ),
        ]);
  }

  // ---------------------------------------------------------------- playback

  /// Resolves the file to play for a track.
  ///
  /// When several files hold the same song, lossless wins, then the highest
  /// bitrate. A missing file is skipped, so an unplugged drive falls back to
  /// another copy rather than failing.
  Future<PlayableTrack?> playable(int trackId) async {
    final row = await db.customSelect(
      '''
      SELECT
        t.id AS track_id, t.title AS title,
        COALESCE(t.duration_ms, mf.duration_ms, 0) AS duration_ms,
        t.album_id AS album_id, alb.title AS album_title,
        ti.stored_path AS image_path,
        lf.path AS folder_path, mf.relative_path AS relative_path,
        mf.replay_gain_db AS replay_gain_db, mf.lossless AS lossless,
        mf.codec AS codec, mf.bitrate AS bitrate, mf.sample_rate AS sample_rate,
        (SELECT group_concat(ar.name, ', ') FROM track_credits tc
          JOIN artists ar ON ar.id = tc.artist_id
         WHERE tc.track_id = t.id AND tc.role = 'mainArtist') AS artist_line
      FROM tracks t
      JOIN media_files mf ON mf.track_id = t.id
      JOIN library_folders lf ON lf.id = mf.folder_id
      LEFT JOIN albums alb ON alb.id = t.album_id
      LEFT JOIN v_track_artwork vt ON vt.track_id = t.id
      LEFT JOIN images ti ON ti.id = vt.image_id
      WHERE t.id = ? AND mf.status = 'present'
      ORDER BY
        CASE WHEN t.preferred_file_id = mf.id THEN 0 ELSE 1 END,
        mf.lossless DESC,
        COALESCE(mf.bitrate, 0) DESC
      LIMIT 1
      ''',
      variables: [Variable(trackId)],
    ).getSingleOrNull();
    if (row == null) return null;

    final folder = row.read<String>('folder_path');
    final relative = row.read<String>('relative_path');

    return PlayableTrack(
      trackId: row.read<int>('track_id'),
      // Relative paths are stored with forward slashes; Windows accepts them.
      filePath: '$folder/$relative',
      title: row.read<String>('title'),
      artistLine: row.read<String?>('artist_line') ?? 'Unknown artist',
      durationMs: row.read<int>('duration_ms'),
      albumId: row.read<int?>('album_id'),
      albumTitle: row.read<String?>('album_title'),
      imagePath: row.read<String?>('image_path'),
      replayGainDb: row.read<double?>('replay_gain_db'),
      lossless: row.read<int>('lossless') == 1,
      codec: row.read<String?>('codec'),
      bitrate: row.read<int?>('bitrate'),
      sampleRate: row.read<int?>('sample_rate'),
    );
  }

  // ------------------------------------------------------------------ counts

  /// Headline counts for the settings and empty states.
  Future<LibraryCounts> counts() async {
    final row = await db.customSelect('''
      SELECT
        (SELECT COUNT(*) FROM tracks) AS tracks,
        (SELECT COUNT(*) FROM albums) AS albums,
        (SELECT COUNT(*) FROM artists
          WHERE EXISTS (SELECT 1 FROM track_credits tc
                         WHERE tc.artist_id = artists.id)) AS artists,
        (SELECT COUNT(*) FROM tags) AS tags,
        (SELECT COUNT(*) FROM playlists) AS playlists,
        (SELECT COUNT(*) FROM media_files) AS files,
        (SELECT COUNT(*) FROM media_files WHERE status = 'missing')
          AS missing_files,
        (SELECT COUNT(*) FROM pending_credits WHERE resolved_at IS NULL)
          AS pending_credits,
        (SELECT COALESCE(SUM(duration_ms), 0) FROM tracks) AS total_ms
    ''').getSingle();

    return LibraryCounts(
      tracks: row.read<int>('tracks'),
      albums: row.read<int>('albums'),
      artists: row.read<int>('artists'),
      tags: row.read<int>('tags'),
      playlists: row.read<int>('playlists'),
      files: row.read<int>('files'),
      missingFiles: row.read<int>('missing_files'),
      pendingCredits: row.read<int>('pending_credits'),
      totalDurationMs: row.read<int>('total_ms'),
    );
  }
}

/// Headline library statistics.
class LibraryCounts {
  const LibraryCounts({
    required this.tracks,
    required this.albums,
    required this.artists,
    required this.tags,
    required this.playlists,
    required this.files,
    required this.missingFiles,
    required this.pendingCredits,
    required this.totalDurationMs,
  });

  final int tracks;
  final int albums;
  final int artists;
  final int tags;
  final int playlists;
  final int files;
  final int missingFiles;
  final int pendingCredits;
  final int totalDurationMs;

  Duration get totalDuration => Duration(milliseconds: totalDurationMs);
  bool get isEmpty => tracks == 0;

  static const empty = LibraryCounts(
    tracks: 0,
    albums: 0,
    artists: 0,
    tags: 0,
    playlists: 0,
    files: 0,
    missingFiles: 0,
    pendingCredits: 0,
    totalDurationMs: 0,
  );
}
