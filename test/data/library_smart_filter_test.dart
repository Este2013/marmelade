import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/features/library/albums_view.dart';
import 'package:marmelade/features/library/artists_view.dart';
import 'package:marmelade/features/library/songs_view.dart';

/// The Albums/Songs/Artists filter boxes, once a query written in field
/// syntax is typed into one.
///
/// The bug this closes: following a search's "N more" link into one of these
/// views hands the raw search text straight into the filter box (see
/// `AppShell._seeMoreFromSearch`), and that text may already be
/// `artist:Camellia` rather than a bare word. Before this, the filter took it
/// completely literally -- looking for the substring "artist:camellia" in a
/// title -- and found nothing. Now a field-syntax filter is answered through
/// the same [SmartPlaylistResolver] a smart playlist uses.
void main() {
  late MarmeladeDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
  });

  tearDown(() => db.close());

  Future<int> artist(String name) => db.into(db.artists).insert(
        ArtistsCompanion.insert(name: name, nameKey: name.toLowerCase()),
      );

  Future<int> album(String title) => db.into(db.albums).insert(
        AlbumsCompanion.insert(title: title, nameKey: title.toLowerCase()),
      );

  Future<int> track(
    String title, {
    List<int> credits = const [],
    int? albumId,
    bool isFavorite = false,
  }) async {
    final id = await db.into(db.tracks).insert(TracksCompanion.insert(
          title: title,
          nameKey: title.toLowerCase(),
          albumId: Value(albumId),
          isFavorite: Value(isFavorite),
        ));
    for (final artistId in credits) {
      await db.into(db.trackCredits).insert(
            TrackCreditsCompanion.insert(trackId: id, artistId: artistId),
          );
    }
    return id;
  }

  /// Waits past the filter's debounce and the resolver's own round trip.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 400));

  test('songs: a field query is answered by the resolver, not a substring',
      () async {
    final camellia = await artist('Camellia');
    final wanted = await track('Ghost', credits: [camellia]);
    await track('Unrelated');

    container.listen(songsShownProvider, (_, _) {});
    container.read(songFilterProvider.notifier).set('artist:camellia');
    await settle();

    expect(
      container.read(songsShownProvider).shown.map((t) => t.id),
      [wanted],
    );
  });

  test('songs: a bare word still filters by substring as before', () async {
    await track('Ghost');
    await track('Unrelated');

    container.listen(songsShownProvider, (_, _) {});
    container.read(songFilterProvider.notifier).set('ghost');
    await settle();

    expect(
      container.read(songsShownProvider).shown.map((t) => t.title),
      ['Ghost'],
    );
  });

  test('albums: matches when any of its tracks does', () async {
    final camellia = await artist('Camellia');
    final wantedAlbum = await album('Wanted');
    await track('Ghost', credits: [camellia], albumId: wantedAlbum);
    final otherAlbum = await album('Other');
    await track('Something else', albumId: otherAlbum);

    container.listen(albumsShownProvider, (_, _) {});
    container.read(albumFilterProvider.notifier).set('artist:camellia');
    await settle();

    expect(
      container.read(albumsShownProvider).shown.map((a) => a.title),
      ['Wanted'],
    );
  });

  test('albums: a standalone favourite track surfaces as a single',
      () async {
    final loose = await track('Loose track', isFavorite: true);
    await track('Not favourited');

    container.listen(albumsShownProvider, (_, _) {});
    container.read(showSinglesProvider.notifier).set(true);
    container.read(albumFilterProvider.notifier).set('is:Favourite');
    await settle();

    // Negative id: a synthetic single card for that one track.
    expect(
      container.read(albumsShownProvider).shown.map((a) => a.id),
      [-loose],
    );
  });

  test('artists: matches when credited on a track the query finds',
      () async {
    final camellia = await artist('Camellia');
    final nanahira = await artist('Nanahira');
    await track('Ghost', credits: [camellia]);
    await track('Song', credits: [nanahira]);

    container.listen(artistsShownProvider, (_, _) {});
    container.read(artistFilterProvider.notifier).set('artist:camellia');
    await settle();

    expect(
      container.read(artistsShownProvider).shown.map((a) => a.name),
      ['Camellia'],
    );
  });

  test('an empty filter never goes through the resolver at all', () async {
    final camellia = await artist('Camellia');
    await track('Ghost', credits: [camellia]);

    container.listen(songsShownProvider, (_, _) {});
    container.listen(artistsShownProvider, (_, _) {});
    await settle();

    expect(container.read(songsShownProvider).shown, hasLength(1));
    expect(container.read(artistsShownProvider).shown, hasLength(1));
  });
}
