import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/app/shell.dart';
import 'package:marmelade/app/theme/app_theme.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/repositories/queue_repository.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:marmelade/services/audio/playback_engine.dart';
import 'package:marmelade/services/audio/player_controller.dart';
import 'package:path/path.dart' as p;

/// Renders the real app shell and checks it builds, lays out and paints.
///
/// The list providers are overridden with fixed data rather than backed by a
/// database. That is the right shape for a widget test - the repositories have
/// their own coverage - and it sidesteps a real incompatibility: cancelling a
/// drift query stream schedules a cleanup timer that the test binding's fake
/// clock never drains, tripping the "a Timer is still pending" invariant no
/// matter how many frames are pumped.
///
/// Set MARMELADE_UI_SHOTS to a directory to keep the rendered PNGs. That is
/// the only way to actually look at this UI from a headless environment: the
/// Windows engine composites through ANGLE, and every OS-level capture of the
/// real window comes back blank - including for a trivial app that cannot fail.

/// A playback engine that does nothing, so the UI runs without an audio device.
class _SilentEngine implements PlaybackEngine {
  @override
  bool get isInitialized => true;
  @override
  Object? get lastError => null;
  @override
  PlaybackStatus get status => PlaybackStatus.idle;
  @override
  String? get loadedPath => null;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => Duration.zero;
  @override
  double get volume => 0.7;
  @override
  double get speed => 1;
  @override
  EqualizerSettings get equalizer => EqualizerSettings.flat;
  @override
  bool get spectrumEnabled => false;
  @override
  AudioOutputDevice? get currentOutputDevice => null;
  @override
  Stream<void> get onCompleted => const Stream.empty();

  @override
  Future<void> initialize() async {}
  @override
  Future<void> shutdown() async {}
  @override
  Future<Duration> load(String filePath, {AudioLoadMode? mode}) async =>
      Duration.zero;
  @override
  Future<void> play() async {}
  @override
  void pause() {}
  @override
  Future<void> stop() async {}
  @override
  void seek(Duration position) {}
  @override
  void setVolume(double value) {}
  @override
  void fadeVolume(double value, Duration duration) {}
  @override
  void setSpeed(double value) {}
  @override
  void setGainOffset(double db) {}
  @override
  List<AudioOutputDevice> outputDevices() => const [];
  @override
  Future<void> setOutputDevice(AudioOutputDevice? device) async {}
  @override
  void setEqualizer(EqualizerSettings settings) {}
  @override
  void setSpectrumEnabled(bool enabled) {}
  @override
  SpectrumFrame? readSpectrum() => null;
}

/// A player stuck in its idle state, so the UI renders without storage.
class _IdlePlayer extends PlayerController {
  _IdlePlayer(MarmeladeDatabase db)
      : super(
          engine: _SilentEngine(),
          queueRepository: QueueRepository(db),
          libraryRepository: LibraryRepository(db),
          db: db,
        );

  @override
  PlayerSnapshot build() => const PlayerSnapshot();
}

// ---------------------------------------------------------------- fixtures

const _antenna = AlbumCard(
  id: 1,
  title: 'Antenna',
  artistName: 'PinocchioP',
  artistId: 1,
  trackCount: 2,
  imagePath: null,
  releaseYear: 2023,
  totalDurationMs: 402000,
);

const _comic = AlbumCard(
  id: 2,
  title: 'Comic and Cosmic',
  artistName: 'PinocchioP',
  artistId: 1,
  trackCount: 2,
  imagePath: null,
  releaseYear: 2020,
  totalDurationMs: 404000,
);

const _pinocchioCredit = TrackCreditRef(
  artistId: 1,
  name: 'PinocchioP',
  role: 'mainArtist',
);

/// A collaboration, so the credits UI has two separate links to render.
const _crossSeparator = TrackRow(
  id: 4,
  title: 'Cross Separator',
  credits: [
    TrackCreditRef(artistId: 2, name: 'Camellia', role: 'mainArtist'),
    TrackCreditRef(artistId: 3, name: 'Nanahira', role: 'mainArtist'),
  ],
  durationMs: 202000,
  albumId: 2,
  albumTitle: 'Comic and Cosmic',
  trackNo: 2,
);

const _antennaTracks = [
  TrackRow(
    id: 1,
    title: 'Tokyo Mannequin',
    credits: [_pinocchioCredit],
    durationMs: 201000,
    albumId: 1,
    albumTitle: 'Antenna',
    trackNo: 1,
  ),
  TrackRow(
    id: 2,
    title: 'Motivation is Dead',
    credits: [_pinocchioCredit],
    durationMs: 202000,
    albumId: 1,
    albumTitle: 'Antenna',
    trackNo: 2,
    lossless: true,
  ),
];

const _allTracks = [..._antennaTracks, _crossSeparator];

const _artists = [
  ArtistCard(
    id: 1,
    name: 'PinocchioP',
    kind: 'person',
    trackCount: 3,
    albumCount: 2,
    aliasCount: 1,
  ),
  ArtistCard(
    id: 2,
    name: 'Camellia',
    kind: 'person',
    trackCount: 1,
    albumCount: 1,
  ),
  ArtistCard(
    id: 4,
    name: 'Earth, Wind & Fire',
    kind: 'group',
    trackCount: 5,
    albumCount: 1,
    memberCount: 3,
  ),
];

void main() {
  late MarmeladeDatabase db;
  late Directory artRoot;

  /// Where to write rendered screenshots, if the caller wants them kept.
  final shotDir = Platform.environment['MARMELADE_UI_SHOTS'];

  setUp(() async {
    // A database is still needed for the few widgets that write directly - the
    // favourite toggle, the folder switches - but nothing here listens to a
    // query stream.
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    artRoot = Directory.systemTemp.createTempSync('marmelade_ui_art_');
  });

  tearDown(() async {
    await db.close();
    if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
  });

  Widget buildApp({
    List<AlbumCard> albums = const [_antenna, _comic],
    List<TrackRow> tracks = _allTracks,
  }) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        artStoreProvider.overrideWithValue(ArtStore(artRoot)),
        playbackEngineProvider.overrideWithValue(_SilentEngine()),
        playerProvider.overrideWith(() => _IdlePlayer(db)),
        albumsProvider.overrideWith((ref) => Stream.value(albums)),
        allTracksProvider.overrideWith((ref) => Stream.value(tracks)),
        artistsProvider.overrideWith((ref) => Stream.value(_artists)),
        tagsProvider.overrideWith((ref) => Stream.value(const <TagCard>[])),
        albumTracksProvider.overrideWith(
          (ref, albumId) =>
              Stream.value(tracks.where((t) => t.albumId == albumId).toList()),
        ),
        albumDetailProvider.overrideWith(
          (ref, albumId) async =>
              albums.where((a) => a.id == albumId).firstOrNull,
        ),
        artistTracksProvider.overrideWith(
          (ref, artistId) => Stream.value(
            tracks
                .where((t) => t.credits.any((c) => c.artistId == artistId))
                .toList(),
          ),
        ),
        artistAlbumsProvider
            .overrideWith((ref, artistId) => Stream.value(albums)),
        libraryFoldersProvider
            .overrideWith((ref) => Stream.value(const <LibraryFolder>[])),
        libraryCountsProvider.overrideWith(
          (ref) async => LibraryCounts(
            tracks: tracks.length,
            albums: albums.length,
            artists: _artists.length,
            tags: 0,
            playlists: 0,
            files: tracks.length,
            missingFiles: 0,
            pendingCredits: 2,
            totalDurationMs: 605000,
          ),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        theme: buildTheme(seed: marmeladeSeed, brightness: Brightness.light),
        darkTheme: buildTheme(seed: marmeladeSeed, brightness: Brightness.dark),
        home: const RepaintBoundary(child: AppShell()),
      ),
    );
  }

  /// Finds a label inside the navigation rail specifically.
  ///
  /// Section names appear twice - once in the rail, once in that section's own
  /// header - because the shell keeps every section alive in an IndexedStack so
  /// switching is instant and each keeps its scroll position.
  Finder railItem(String label) => find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text(label),
      );

  /// Pumps a bounded number of frames.
  ///
  /// Not pumpAndSettle: these views show a progress indicator until their data
  /// arrives, and an indefinite animation means settle never returns.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Renders the current frame to a PNG, so the result can be looked at.
  ///
  /// Encoding has to happen inside runAsync: toImage defers to the engine, and
  /// under the test binding's fake clock that never completes.
  Future<void> capture(WidgetTester tester, String name) async {
    if (shotDir == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary).first,
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return;
      final file = File(p.join(shotDir, '$name.png'));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes.buffer.asUint8List());
    });
  }

  Future<void> open(
    WidgetTester tester, {
    Widget? app,
    Size size = const Size(1400, 900),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app ?? buildApp());
    await settle(tester);
  }

  testWidgets('the shell builds and paints the albums grid', (tester) async {
    await open(tester);
    expect(tester.takeException(), isNull);

    expect(find.text('Albums'), findsWidgets);
    expect(find.text('Antenna'), findsOneWidget);
    expect(find.text('Comic and Cosmic'), findsOneWidget);
    expect(find.text('PinocchioP'), findsWidgets);
    expect(find.text('2023'), findsOneWidget);

    // The rail and the player strip are both present.
    expect(railItem('Songs'), findsOneWidget);
    expect(railItem('Artists'), findsOneWidget);
    expect(find.text('Nothing playing'), findsOneWidget);

    await capture(tester, '01-albums');
  });

  testWidgets('the songs list gives every credited artist its own link',
      (tester) async {
    await open(tester);
    await tester.tap(railItem('Songs'));
    await settle(tester);
    expect(tester.takeException(), isNull);

    expect(find.text('Cross Separator'), findsOneWidget);
    // The collaboration renders both artists separately, which is the visible
    // half of the credits model.
    expect(find.text('Camellia'), findsWidgets);
    expect(find.text('Nanahira'), findsWidgets);
    expect(find.text('FLAC'), findsOneWidget);

    await capture(tester, '02-songs');
  });

  testWidgets('the artists list marks groups differently', (tester) async {
    await open(tester);
    await tester.tap(railItem('Artists'));
    await settle(tester);
    expect(tester.takeException(), isNull);

    expect(find.text('PinocchioP'), findsWidgets);
    // A name that must never be split still reads as one artist here.
    expect(find.text('Earth, Wind & Fire'), findsOneWidget);
    expect(find.textContaining('3 members'), findsOneWidget);

    await capture(tester, '03-artists');
  });

  testWidgets('an album page opens from the grid', (tester) async {
    await open(tester);
    await tester.tap(find.text('Antenna'));
    await settle(tester);
    expect(tester.takeException(), isNull);

    expect(find.text('Tokyo Mannequin'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Shuffle'), findsOneWidget);

    await capture(tester, '04-album');
  });

  testWidgets('settings shows the folder controls and the repo link',
      (tester) async {
    await open(tester);
    await tester.tap(railItem('Settings'));
    await settle(tester);
    expect(tester.takeException(), isNull);

    expect(find.text('Music folders'), findsWidgets);
    expect(find.text('Add folder'), findsOneWidget);
    expect(find.text('No folders yet'), findsOneWidget);
    expect(find.text('Source code'), findsOneWidget);
    // Anything waiting on the user is surfaced rather than hidden.
    expect(find.textContaining('to review'), findsOneWidget);

    await capture(tester, '05-settings');
  });

  testWidgets('an empty library shows an empty state, not a blank panel',
      (tester) async {
    await open(tester, app: buildApp(albums: const [], tracks: const []));
    expect(tester.takeException(), isNull);
    expect(find.text('No music yet'), findsOneWidget);

    await capture(tester, '06-empty');
  });

  testWidgets('the narrowest allowed window does not overflow', (tester) async {
    // The minimum size main() permits. An overflow surfaces as an exception,
    // which takeException catches.
    await open(tester, size: const Size(860, 620));
    expect(tester.takeException(), isNull);

    await capture(tester, '07-narrow');
  });
}
