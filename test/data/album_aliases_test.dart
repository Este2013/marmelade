import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/library_repository.dart';

/// Finding a release by the other titles it is known under.
///
/// The gap this covers: an album filed under its native title with a
/// romanization alias was found by the Search view, which indexes aliases,
/// and not by the albums grid's filter box, whose cards never carried them.
/// Matching happens in the view, so the card has to arrive with the aliases
/// already on it.
void main() {
  late MarmeladeDatabase db;
  late LibraryRepository library;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    library = LibraryRepository(db);
  });
  tearDown(() => db.close());

  Future<int> album(String title) =>
      db.into(db.albums).insert(AlbumsCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
          ));

  Future<void> albumAlias(int albumId, String text) =>
      db.into(db.albumAliases).insert(AlbumAliasesCompanion.insert(
            albumId: albumId,
            alias: text,
            aliasKey: text.toLowerCase(),
          ));

  Future<int> track(String title, {int? albumId}) =>
      db.into(db.tracks).insert(TracksCompanion.insert(
            title: title,
            nameKey: title.toLowerCase(),
            albumId: Value(albumId),
          ));

  Future<void> trackAlias(int trackId, String text) =>
      db.into(db.trackAliases).insert(TrackAliasesCompanion.insert(
            trackId: trackId,
            alias: text,
            aliasKey: text.toLowerCase(),
          ));

  group('what an album card carries', () {
    test('every title it goes by, so a filter can match one', () async {
      final id = await album('ウェザーステーション');
      await albumAlias(id, 'Weather Station');
      await track('Song', albumId: id);

      final cards = await library.watchAlbums().first;

      expect(cards.single.aliases, ['Weather Station']);
    });

    test('a title holding a comma survives being carried', () async {
      // group_concat joins on a separator, and a comma would split a title
      // in two halves that match nothing. The unit separator is the point.
      final id = await album('Some Album');
      await albumAlias(id, 'Hello, Goodbye');
      await track('Song', albumId: id);

      final cards = await library.watchAlbums().first;

      expect(cards.single.aliases, ['Hello, Goodbye']);
    });

    test('its artist aliases too, which it always did', () async {
      final artistId = await db.into(db.artists).insert(
            ArtistsCompanion.insert(name: 'PinocchioP', nameKey: 'pinocchiop'),
          );
      await db.into(db.artistAliases).insert(ArtistAliasesCompanion.insert(
            artistId: artistId,
            alias: 'ピノキオピー',
            aliasKey: 'ピノキオピー',
          ));
      final id = await db.into(db.albums).insert(AlbumsCompanion.insert(
            title: 'Antenna',
            nameKey: 'antenna',
            albumArtistId: Value(artistId),
          ));
      await track('Song', albumId: id);

      final cards = await library.watchAlbums().first;

      expect(cards.single.artistAliases, ['ピノキオピー']);
    });

    test('a single carries the track\'s own aliases', () async {
      // A loose track is shown in the grid as an album card standing in for
      // it, so "find it by its other title" has to work there too.
      final id = await track('アンノウン・マザーグース');
      await trackAlias(id, 'Unknown Mother Goose');

      final cards = await library.watchAlbums(includeSingles: true).first;

      expect(cards.single.aliases, ['Unknown Mother Goose']);
    });
  });

  test('an alias added later reaches a grid already on screen', () async {
    // The stream has to be told it reads from the alias tables, or the grid
    // keeps filtering on what the aliases were when it first loaded.
    final id = await album('ウェザーステーション');
    await track('Song', albumId: id);

    final cards = library.watchAlbums();
    expect((await cards.first).single.aliases, isEmpty);

    final updated = cards.firstWhere((rows) => rows.single.aliases.isNotEmpty);
    await albumAlias(id, 'Weather Station');

    expect((await updated).single.aliases, ['Weather Station']);
  });
}
