import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/domain/models/library_views.dart';

/// Ordering, which is not cosmetic: the visible list is what gets queued, so a
/// sort that scatters an album's running order scatters playback with it.
void main() {
  late MarmeladeDatabase db;
  late LibraryRepository repository;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    repository = LibraryRepository(db);
  });

  tearDown(() async => db.close());

  Future<int> album(String title, {String? sortTitle}) =>
      db.into(db.albums).insert(
            AlbumsCompanion.insert(
              title: title,
              nameKey: title.toLowerCase(),
              sortTitle: Value(sortTitle ?? title),
            ),
          );

  Future<int> artist(String name) => db.into(db.artists).insert(
        ArtistsCompanion.insert(name: name, nameKey: name.toLowerCase()),
      );

  Future<int> track(
    String title, {
    int? albumId,
    int? discNo,
    int? trackNo,
    required int artistId,
  }) async {
    final id = await db.into(db.tracks).insert(
          TracksCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            albumId: Value(albumId),
            discNo: Value(discNo),
            trackNo: Value(trackNo),
          ),
        );
    await db.into(db.trackCredits).insert(
          TrackCreditsCompanion.insert(trackId: id, artistId: artistId),
        );
    return id;
  }

  group('watchTracks ordering', () {
    test('albumThenTrack groups by release, in running order', () async {
      final artistId = await artist('LukHash');
      // Deliberately inserted out of order, and with an album whose title
      // sorts before the other, to prove the ordering is doing the work.
      final zebra = await album('Zebra');
      final antenna = await album('Antenna');

      await track('Z second', albumId: zebra, trackNo: 2, artistId: artistId);
      await track('A third', albumId: antenna, trackNo: 3, artistId: artistId);
      await track('Z first', albumId: zebra, trackNo: 1, artistId: artistId);
      await track('A first', albumId: antenna, trackNo: 1, artistId: artistId);

      final rows = await repository
          .watchTracks(
            artistId: artistId,
            sort: LibrarySort.albumThenTrack,
          )
          .first;

      expect(rows.map((r) => r.title), [
        'A first',
        'A third',
        'Z first',
        'Z second',
      ]);
    });

    test('a track belonging to no album sorts after the albums', () async {
      // A blank heading at the top of an artist page is worse than one at the
      // bottom, and a loose single is genuinely the odd one out.
      final artistId = await artist('Creo');
      final antenna = await album('Antenna');
      await track('Loose single', artistId: artistId);
      await track('On a release', albumId: antenna, trackNo: 1, artistId: artistId);

      final rows = await repository
          .watchTracks(artistId: artistId, sort: LibrarySort.albumThenTrack)
          .first;

      expect(rows.map((r) => r.title), ['On a release', 'Loose single']);
    });

    test('discs order before track numbers', () async {
      final artistId = await artist('Epic Mountain');
      final id = await album('Two Discs');
      await track('d2t1', albumId: id, discNo: 2, trackNo: 1, artistId: artistId);
      await track('d1t2', albumId: id, discNo: 1, trackNo: 2, artistId: artistId);
      await track('d1t1', albumId: id, discNo: 1, trackNo: 1, artistId: artistId);

      final rows = await repository
          .watchTracks(artistId: artistId, sort: LibrarySort.albumThenTrack)
          .first;

      expect(rows.map((r) => r.title), ['d1t1', 'd1t2', 'd2t1']);
    });

    test('trackNumber puts unnumbered tracks last, not first', () async {
      // A NULL track number means "unknown", not "track zero".
      final artistId = await artist('Yooh');
      final id = await album('Mixed');
      await track('unnumbered', albumId: id, artistId: artistId);
      await track('second', albumId: id, trackNo: 2, artistId: artistId);
      await track('first', albumId: id, trackNo: 1, artistId: artistId);

      final rows = await repository
          .watchTracks(albumId: id, sort: LibrarySort.trackNumber)
          .first;

      expect(rows.map((r) => r.title), ['first', 'second', 'unnumbered']);
    });
  });

  group('watchTracks filtering', () {
    test('a single track can be fetched with its credits', () async {
      // What the now-playing view needs: the credits as separate artists, not
      // the pre-joined line the player snapshot carries.
      final camellia = await artist('Camellia');
      final nanahira = await artist('Nanahira');
      final id = await track('Cross Separator', artistId: camellia);
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(trackId: id, artistId: nanahira),
          );

      final rows = await repository.watchTracks(trackId: id).first;
      expect(rows, hasLength(1));
      expect(
        rows.single.credits.map((c) => c.name),
        containsAll(['Camellia', 'Nanahira']),
      );
    });
  });
}
