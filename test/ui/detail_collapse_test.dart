import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/playlist_repository.dart'
    show PlaylistEntry;
import 'package:marmelade/data/repositories/tag_repository.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/features/library/album_detail_view.dart';
import 'package:marmelade/features/library/artist_detail_view.dart';
import 'package:marmelade/features/playlists/playlist_detail_view.dart';

import '../support/silent_player.dart';

/// The collapsing header, on every page that has one.
///
/// Proven first on a tag (see tag_detail_test.dart), then extended: an album,
/// an artist and a playlist are all pages you scroll a long way down, and on
/// all of them the name you are looking at and the button that plays it have
/// to stay reachable once the header has gone. The tests drag rather than
/// drive a controller, because the whole mechanic is a scroll notification
/// crossing from the page to the window's caption strip.
void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  TrackRow track(int id, {int? albumId}) => TrackRow(
        id: id,
        title: 'Track $id',
        credits: const [],
        durationMs: 200000,
        albumId: albumId,
        albumTitle: albumId == null ? null : 'Comic and Cosmic',
      );

  final tracks = [for (var i = 1; i <= 40; i++) track(i, albumId: 3)];

  /// Stands the page up beside its chrome, the way AppShell does.
  Future<void> pump(
    WidgetTester tester, {
    required List<Override> overrides,
    required Widget chrome,
    required Widget page,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playbackEngineProvider.overrideWithValue(SilentEngine()),
          playerProvider.overrideWith(() => IdlePlayer(db)),
          taggedProvider.overrideWith((ref) => Stream.value(const <TagCard>[])),
          tagCategoriesProvider
              .overrideWith((ref) => Stream.value(const <TagCategoryRow>[])),
          // Faked for the reason every other stream here is: cancelling a
          // real drift stream posts a zero-duration cleanup timer the test
          // binding's clock never drains, so the scope tears down with a
          // timer still pending.
          attachedTagsProvider
              .overrideWith((ref, key) => Stream.value(const <AttachedTag>[])),
          ...overrides,
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [chrome, Expanded(child: page)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Scrolls the page itself, wherever its list happens to be.
  Future<void> scroll(WidgetTester tester, double dy) async {
    await tester.drag(find.byType(Scrollable).last, Offset(0, dy));
    await tester.pumpAndSettle();
  }

  Finder inStrip(Type chrome, Finder what) =>
      find.descendant(of: find.byType(chrome), matching: what);

  void expectTakenOver(Type chrome, String title) {
    expect(inStrip(chrome, find.text(title)), findsOne);
    expect(inStrip(chrome, find.byTooltip('Play')), findsOne);
    expect(inStrip(chrome, find.byTooltip('Shuffle')), findsOne);
  }

  group('an album page', () {
    const album = AlbumCard(
      id: 3,
      title: 'Comic and Cosmic',
      artistName: 'Camellia',
      artistId: 2,
      trackCount: 40,
      imagePath: null,
    );

    Future<void> open(WidgetTester tester) => pump(
          tester,
          overrides: [
            albumDetailProvider(3).overrideWith((ref) async => album),
            albumTracksProvider(3).overrideWith((ref) => Stream.value(tracks)),
          ],
          chrome: const AlbumDetailChrome(albumId: 3, onBack: _noop),
          page: AlbumDetailView(albumId: 3, onOpenArtist: _noopId),
        );

    testWidgets('hands its title and controls to the strip', (tester) async {
      await open(tester);
      expect(inStrip(AlbumDetailChrome, find.text(album.title)), findsNothing);

      await scroll(tester, -400);

      expectTakenOver(AlbumDetailChrome, album.title);
    });

    testWidgets('and takes them back on the way up', (tester) async {
      await open(tester);
      await scroll(tester, -400);
      await scroll(tester, 400);

      expect(inStrip(AlbumDetailChrome, find.text(album.title)), findsNothing);
    });
  });

  group('an artist page', () {
    const artist = ArtistCard(
      id: 2,
      name: 'Camellia',
      kind: 'person',
      trackCount: 40,
      albumCount: 1,
    );

    Future<void> open(WidgetTester tester) => pump(
          tester,
          overrides: [
            artistsProvider.overrideWith((ref) => Stream.value(const [artist])),
            artistTracksProvider(2).overrideWith((ref) => Stream.value(tracks)),
            artistAlbumsProvider(2)
                .overrideWith((ref) => Stream.value(const <AlbumCard>[])),
          ],
          chrome: const ArtistDetailChrome(artistId: 2, onBack: _noop),
          page: ArtistDetailView(
            artistId: 2,
            onOpenAlbum: _noopId,
            onOpenArtist: _noopId,
          ),
        );

    testWidgets('hands its name and controls to the strip', (tester) async {
      await open(tester);
      expect(inStrip(ArtistDetailChrome, find.text(artist.name)), findsNothing);

      await scroll(tester, -400);

      expectTakenOver(ArtistDetailChrome, artist.name);
    });

    testWidgets('and takes them back on the way up', (tester) async {
      await open(tester);
      await scroll(tester, -400);
      await scroll(tester, 400);

      expect(inStrip(ArtistDetailChrome, find.text(artist.name)), findsNothing);
    });
  });

  group('a playlist page', () {
    const playlist = PlaylistCard(
      id: 5,
      name: 'Late Night Coding',
      kind: 'manual',
      trackCount: 40,
    );

    Future<void> open(WidgetTester tester) => pump(
          tester,
          overrides: [
            playlistProvider(5).overrideWith((ref) => Stream.value(playlist)),
            playlistTracksProvider(5)
                .overrideWith((ref) => Stream.value(tracks)),
            playlistEntriesProvider(5)
                .overrideWith((ref) => Stream.value(const <PlaylistEntry>[])),
          ],
          chrome: const PlaylistDetailChrome(playlistId: 5, onBack: _noop),
          page: PlaylistDetailView(
            playlistId: 5,
            onBack: _noop,
            onOpenPlaylist: _noopId,
          ),
        );

    testWidgets('hands its name and controls to the strip', (tester) async {
      await open(tester);
      expect(
        inStrip(PlaylistDetailChrome, find.text(playlist.name)),
        findsNothing,
      );

      await scroll(tester, -400);

      expectTakenOver(PlaylistDetailChrome, playlist.name);
    });

    testWidgets('and takes them back on the way up', (tester) async {
      await open(tester);
      await scroll(tester, -400);
      await scroll(tester, 400);

      expect(
        inStrip(PlaylistDetailChrome, find.text(playlist.name)),
        findsNothing,
      );
    });
  });
}

void _noop() {}

void _noopId(int _) {}
