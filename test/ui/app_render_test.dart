import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/app/shell.dart';
import 'package:marmelade/app/window_chrome.dart';
import 'package:marmelade/app/theme/app_theme.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/repositories/queue_repository.dart';
import 'package:marmelade/data/repositories/review_repository.dart';
import 'package:marmelade/features/player/player_bar.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/services/art/art_store.dart';
import 'package:marmelade/services/audio/playback_engine.dart';
import 'package:marmelade/services/audio/player_controller.dart';
import 'package:marmelade/widgets/artwork.dart';
import 'package:window_manager/window_manager.dart';
import 'package:marmelade/widgets/track_list.dart';
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

/// A player with a track loaded and a queue behind it.
///
/// The now-playing view is mostly empty states until something is playing, so
/// an idle player would not exercise the part worth testing.
class _PlayingPlayer extends PlayerController {
  _PlayingPlayer(MarmeladeDatabase db)
      : super(
          engine: _SilentEngine(),
          queueRepository: QueueRepository(db),
          libraryRepository: LibraryRepository(db),
          db: db,
        );

  @override
  PlayerSnapshot build() => _playing;
}

/// A player with a long queue, positioned wherever the test asks.
///
/// For the opening scroll offset, which only matters once the queue is longer
/// than the panel.
class _LongQueuePlayer extends PlayerController {
  _LongQueuePlayer(MarmeladeDatabase db, this.index, this.length)
      : super(
          engine: _SilentEngine(),
          queueRepository: QueueRepository(db),
          libraryRepository: LibraryRepository(db),
          db: db,
        );

  final int index;
  final int length;

  @override
  PlayerSnapshot build() => PlayerSnapshot(
        status: PlaybackStatus.playing,
        currentIndex: index,
        duration: const Duration(minutes: 3),
        queue: [
          for (var i = 0; i < length; i++)
            QueueEntry(
              itemId: i + 1,
              trackId: i + 1,
              position: (i + 1) * 1000,
              title: 'Track ${i + 1}',
              artistLine: 'Someone',
              durationMs: 180000,
              source: 'album',
            ),
        ],
        current: _playing.current,
      );
}

/// Something queued, nothing loaded. The "ready to play" state.
class _QueuedPlayer extends PlayerController {
  _QueuedPlayer(MarmeladeDatabase db)
      : super(
          engine: _SilentEngine(),
          queueRepository: QueueRepository(db),
          libraryRepository: LibraryRepository(db),
          db: db,
        );

  @override
  PlayerSnapshot build() => const PlayerSnapshot(queue: _queue);
}

/// A player that starts with nothing and can be handed a track mid-test.
///
/// This is how the player bar's reveal is actually triggered in the app: the
/// same notifier's state changes underneath it. Swapping the whole notifier
/// out is not a path that ever happens.
class _StageablePlayer extends PlayerController {
  _StageablePlayer(MarmeladeDatabase db)
      : super(
          engine: _SilentEngine(),
          queueRepository: QueueRepository(db),
          libraryRepository: LibraryRepository(db),
          db: db,
        );

  @override
  PlayerSnapshot build() => const PlayerSnapshot();

  void stageTrack() => state = _playing;
}

const _playing = PlayerSnapshot(
  status: PlaybackStatus.playing,
  currentIndex: 0,
  duration: Duration(minutes: 3, seconds: 22),
  queue: _queue,
  // Points at the collaboration fixture on purpose, so the credits actually
  // resolve to two artists instead of falling back to the pre-joined line the
  // player snapshot carries.
  current: PlayableTrack(
    trackId: 4,
    filePath: 'C:/nowhere/cross-separator.flac',
    title: 'Cross Separator',
    artistLine: 'Camellia x Nanahira',
    durationMs: 202000,
    albumId: 2,
    albumTitle: 'Comic and Cosmic',
  ),
);

const _queue = [
  QueueEntry(
    itemId: 1,
    trackId: 4,
    position: 1000,
    title: 'Cross Separator',
    artistLine: 'Camellia x Nanahira',
    durationMs: 202000,
    source: 'album',
    albumTitle: 'Comic and Cosmic',
  ),
  QueueEntry(
    itemId: 2,
    trackId: 11,
    position: 2000,
    title: 'Kanraku',
    artistLine: 'PinocchioP',
    durationMs: 200000,
    source: 'album',
    albumTitle: 'Antenna',
  ),
];

/// Two parked credits: one with a split to offer, one without.
const _pending = [
  PendingCreditGroup(
    rawCredit: 'Koiflower,Bangler',
    pendingIds: [1],
    trackIds: [10, 11],
    reason: 'separator "," also occurs inside real names',
    confidence: 0.4,
    whole: [CreditOption(creditedAs: 'Koiflower,Bangler', role: 'main')],
    parts: [
      CreditOption(creditedAs: 'Koiflower', role: 'main'),
      CreditOption(creditedAs: 'Bangler', role: 'main'),
    ],
    sampleTitles: ['Feel Right'],
  ),
  PendingCreditGroup(
    rawCredit: 'Earth, Wind and Fire',
    pendingIds: [2],
    trackIds: [12],
    reason: 'the whole string recurs on its own',
    confidence: 0.4,
    whole: [CreditOption(creditedAs: 'Earth, Wind and Fire', role: 'main')],
    parts: [],
    sampleTitles: ['September'],
  ),
];

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
    List<PendingCreditGroup> pending = const [],
    bool playing = false,
    bool stageable = false,
    bool queuedOnly = false,
    ({int index, int length})? longQueue,
    Stream<Duration>? positions,
  }) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        artStoreProvider.overrideWithValue(ArtStore(artRoot)),
        playbackEngineProvider.overrideWithValue(_SilentEngine()),
        playerProvider.overrideWith(
          () => switch ((playing, stageable, longQueue)) {
            (_, _, final q?) => _LongQueuePlayer(db, q.index, q.length),
            (_, true, _) => _StageablePlayer(db),
            (true, _, _) => _PlayingPlayer(db),
            _ => queuedOnly ? _QueuedPlayer(db) : _IdlePlayer(db),
          },
        ),
        if (positions != null)
          playbackPositionProvider.overrideWith((ref) => positions),
        pendingCreditsProvider.overrideWith((ref) => Stream.value(pending)),
        pendingCreditCountProvider
            .overrideWith((ref) => Stream.value(pending.length)),
        trackRowProvider.overrideWith(
          (ref, trackId) => Stream.value(
            tracks.where((t) => t.id == trackId).firstOrNull,
          ),
        ),
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

    // The rail is present. The player strip is not: nothing is playing and
    // nothing is queued, so there is nothing for it to control.
    expect(railItem('Songs'), findsOneWidget);
    expect(railItem('Artists'), findsOneWidget);
    expect(find.byType(PlayerBar), findsNothing);

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

  testWidgets('the review queue is offered where the damage shows',
      (tester) async {
    await open(tester, app: buildApp(pending: _pending));
    await tester.tap(railItem('Artists'));
    await settle(tester);

    // The banner belongs on the artists list: that is where an unsplit credit
    // sits among the real artists.
    expect(find.textContaining('could not be split confidently'), findsOne);
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('2'),
      ),
      findsOne,
      reason: 'the rail should badge Artists with the pending count',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the review page offers a split, an accept and a skip',
      (tester) async {
    await open(tester, app: buildApp(pending: _pending));
    await tester.tap(railItem('Artists'));
    await settle(tester);
    await tester.tap(find.text('Review'));
    await settle(tester);

    expect(find.text('Credits to review'), findsOne);
    expect(find.text('Koiflower,Bangler'), findsOne);
    // The resolver reasoning is what makes the question answerable.
    expect(find.textContaining('also occurs inside real names'), findsOne);
    // The parts are editable, not just yes or no.
    expect(find.widgetWithText(TextField, 'Koiflower'), findsOne);
    expect(find.widgetWithText(TextField, 'Bangler'), findsOne);
    expect(find.text('Keep as one artist'), findsExactly(2));
    // No alternative reading was recorded for the second one, so no split.
    expect(find.text('Split'), findsOne);
    expect(tester.takeException(), isNull);
    await capture(tester, 'review');
  });

  testWidgets('now playing is not a rail destination', (tester) async {
    // It is the player, not a place in the library, so it opens out of the
    // player bar rather than sitting in the rail beside Albums and Artists.
    await open(tester, app: buildApp(playing: true));
    expect(railItem('Queue'), findsNothing);
    expect(find.text('Play queue'), findsNothing);
    expect(find.byTooltip('Open now playing'), findsOne);
  });

  testWidgets('settings sits at the foot of the rail, below the destinations',
      (tester) async {
    await open(tester);

    final railBox = tester.getRect(find.byType(NavigationRail));
    final settings = tester.getRect(find.text('Settings'));
    final playlists = tester.getRect(railItem('Playlists'));

    expect(settings.top, greaterThan(playlists.bottom));
    // Pinned to the bottom, not merely last: the gap below it should be far
    // smaller than the gap above.
    expect(railBox.bottom - settings.bottom, lessThan(60));
    expect(settings.top - playlists.bottom, greaterThan(100));
  });

  testWidgets('the player bar draws the now-playing shade up over the content',
      (tester) async {
    await open(tester, app: buildApp(playing: true));
    expect(find.text('Now playing'), findsNothing);

    await tester.tap(find.byTooltip('Open now playing'));
    await settle(tester);

    expect(find.text('Now playing'), findsOne);
    expect(find.text('Play queue'), findsOne);
    expect(find.text('Kanraku'), findsOne);
    // Every credited artist is its own target in the now-playing pane. The
    // snapshot's own artist line reads "Camellia x Nanahira" as one string --
    // still correct for the compact bar and the queue rows -- so finding the
    // two names standing alone is what proves the credits were resolved.
    expect(find.text('Camellia'), findsWidgets);
    expect(find.text('Nanahira'), findsWidgets);
    expect(find.byTooltip('Remove from queue'), findsExactly(_queue.length));
    expect(find.byTooltip('Drag to reorder'), findsExactly(_queue.length));
    // Two ways out, deliberately: the shade's own close button and the bar's
    // chevron. They carry different labels so each reads unambiguously.
    expect(find.byTooltip('Close now playing'), findsOne);
    expect(find.byTooltip('Hide now playing'), findsOne);
    expect(tester.takeException(), isNull);
    await capture(tester, 'now-playing');

    await tester.tap(find.byTooltip('Close now playing'));
    await settle(tester);
    expect(find.text('Now playing'), findsNothing);
  });

  testWidgets('the queue can be collapsed inside the shade', (tester) async {
    await open(tester, app: buildApp(playing: true));
    await tester.tap(find.byTooltip('Open now playing'));
    await settle(tester);
    expect(find.text('Play queue'), findsOne);

    await tester.tap(find.byTooltip('Hide the queue'));
    await settle(tester);
    expect(find.text('Play queue'), findsNothing);
    // Still obviously recoverable. The count rides in the tooltip now, so
    // match the prefix rather than pinning the fixture's track count.
    expect(find.byTooltip(RegExp(r'^Show the queue')), findsOne);

    await tester.tap(find.byTooltip(RegExp(r'^Show the queue')));
    await settle(tester);
    expect(find.text('Play queue'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow shade shows one pane at a time', (tester) async {
    // Artwork and queue together in the app's minimum window leaves neither
    // usable, so below the breakpoint the queue toggle swaps between them
    // rather than adding a second column.
    await open(
      tester,
      app: buildApp(playing: true),
      size: const Size(880, 700),
    );
    await tester.tap(find.byTooltip('Open now playing'));
    await settle(tester);

    // Titles are no discriminator here: the same track name is in the player
    // bar and the queue row too. The big cover is what the artwork pane is
    // for, so its presence is what actually distinguishes the two panes.
    bool bigCoverShown() => tester
        .widgetList<Artwork>(find.byType(Artwork))
        .any((a) => (a.size ?? 0) > 300);

    // Queue visible by default, so the artwork pane stands aside.
    expect(find.text('Play queue'), findsOne);
    expect(bigCoverShown(), isFalse);

    await tester.tap(find.byTooltip('Hide the queue'));
    await settle(tester);
    expect(find.text('Play queue'), findsNothing);
    expect(bigCoverShown(), isTrue);
    expect(tester.takeException(), isNull);

    // Back to the queue, and keep a picture of it: the app's own minimum
    // window is wider than this breakpoint on a scaled display, so the test
    // surface is the only place this layout can actually be looked at.
    await tester.tap(find.byTooltip(RegExp(r'^Show the queue')));
    await settle(tester);
    await capture(tester, 'now-playing-narrow');
  });

  /// The scroll position of the queue list.
  ScrollPosition queueScroll(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(
          of: find.byType(ReorderableListView),
          matching: find.byType(Scrollable),
        ),
      )
      .position;

  testWidgets('the queue opens with the current track at the top',
      (tester) async {
    // A queue of forty otherwise opens at track one, which is nowhere near
    // where you are.
    await open(
      tester,
      app: buildApp(longQueue: (index: 20, length: 40)),
    );
    await tester.tap(find.byTooltip('Open now playing'));
    await settle(tester);

    expect(
      queueScroll(tester).pixels,
      moreOrLessEquals(20 * 56, epsilon: 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a track near the end scrolls only as far as the queue goes',
      (tester) async {
    // The offset for the last track is past the end of the list, and clamping
    // has to wait until the list has been laid out and knows its own extent.
    await open(
      tester,
      app: buildApp(longQueue: (index: 39, length: 40)),
    );
    await tester.tap(find.byTooltip('Open now playing'));
    await settle(tester);

    final position = queueScroll(tester);
    expect(position.pixels, position.maxScrollExtent);
    expect(position.pixels, lessThan(39 * 56));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a queue shorter than the panel does not scroll at all',
      (tester) async {
    await open(tester, app: buildApp(longQueue: (index: 2, length: 3)));
    await tester.tap(find.byTooltip('Open now playing'));
    await settle(tester);

    expect(queueScroll(tester).pixels, 0);
    expect(queueScroll(tester).maxScrollExtent, 0);
  });

  group('window chrome', () {
    testWidgets('the app draws its own caption, and the rail reaches the top',
        (tester) async {
      await open(tester);

      expect(find.byType(WindowChrome), findsOne);
      // Minimise, maximise, close.
      expect(find.byType(WindowCaptionButton), findsExactly(3));

      // The whole point of hiding the native caption: the rail runs to the
      // very top edge rather than starting below a grey bar.
      expect(tester.getRect(find.byType(NavigationRail)).top, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the whole top edge drags, and covers nothing that matters',
        (tester) async {
      await open(tester);

      final drag = tester.getRect(
        find.descendant(
          of: find.byType(WindowChrome),
          matching: find.byType(DragToMoveArea),
        ),
      );
      // Runs from the left edge, over the rail's top as well.
      expect(drag.left, 0);
      // And no rail destination is underneath it, so nothing interactive is
      // swallowed. This is the invariant that matters; the rail is wider than
      // its minWidth once it has labels, so measuring it is the wrong test.
      for (final label in ['Albums', 'Songs', 'Artists']) {
        expect(
          tester.getRect(railItem(label)).top,
          greaterThanOrEqualTo(WindowChrome.height),
          reason: '$label must not sit under the caption strip',
        );
      }
    });

    testWidgets('the shade puts its own controls in the caption strip',
        (tester) async {
      // One strip of controls at the top of the window, not two stacked on
      // each other.
      await open(tester, app: buildApp(playing: true));

      Finder inChrome(Finder matching) => find.descendant(
            of: find.byType(WindowChrome),
            matching: matching,
          );

      // Closed: the strip carries nothing but the window's own buttons.
      expect(inChrome(find.text('Now playing')), findsNothing);
      expect(inChrome(find.byTooltip('Close now playing')), findsNothing);

      await tester.tap(find.byTooltip('Open now playing'));
      await settle(tester);

      expect(inChrome(find.text('Now playing')), findsOne);
      expect(inChrome(find.byTooltip('Close now playing')), findsOne);
      expect(inChrome(find.byTooltip('Hide the queue')), findsOne);
      // And nowhere else: the shade has no header of its own any more.
      expect(find.text('Now playing'), findsOne);
      expect(find.byTooltip('Close now playing'), findsOne);

      // Closing from the strip works.
      await tester.tap(inChrome(find.byTooltip('Close now playing')));
      await settle(tester);
      expect(find.text('Now playing'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('content starts below the caption, not underneath it',
        (tester) async {
      await open(tester);

      // The section stack itself, rather than any text in it: "Albums" is
      // also a rail label, and the question here is purely where the content
      // area begins.
      expect(tester.getRect(find.byType(IndexedStack)).top,
          WindowChrome.height);
    });
  });

  testWidgets('the ready-to-play bar is a bare cover, and stays centred',
      (tester) async {
    // Something queued, nothing loaded. The label said "Ready to play" and the
    // row collapsed to the height of the play button, which then sat against
    // the top edge of the bar.
    await open(tester, app: buildApp(queuedOnly: true));

    expect(find.byType(PlayerBar), findsOne);
    expect(find.text('Ready to play'), findsNothing);
    expect(find.text('Nothing playing'), findsNothing);

    // A placeholder the size of a cover.
    expect(
      tester
          .widgetList<Artwork>(find.byType(Artwork))
          .where((a) => a.size == 56),
      isNotEmpty,
    );

    // Centred in the controls row, not riding its top edge. The row is the
    // bottom PlayerBar.height of the bar; the strip above it is the seek bar,
    // which is deliberately not part of this.
    final bar = tester.getRect(find.byType(PlayerBar));
    final play = tester.getRect(find.byTooltip('Play'));
    final controlsTop = bar.bottom - PlayerBar.height;
    expect(
      play.center.dy - controlsTop,
      moreOrLessEquals(bar.bottom - play.center.dy, epsilon: 2),
    );
    expect(tester.takeException(), isNull);
  });

  group('seek bar semantics', () {
    /// The seek bar's semantics value, as a screen reader would read it.
    String seekValue(WidgetTester tester) =>
        tester.getSemantics(find.bySemanticsLabel('Playback position')).value;

    testWidgets('the announced position is coarse, not per-frame',
        (tester) async {
      // The playhead moves twelve times a second and a Slider rebuilds its
      // semantics node on every value change. On Windows that outran the
      // accessibility bridge: moving the window to another monitor produced
      // around 155 "Nodes left pending by the update" errors and left the
      // bridge's tree out of step with Flutter's, which is the divergence that
      // used to end in a hard crash. It is also unlistenable.
      final handle = tester.ensureSemantics();

      // Driven through the stream the app actually reads, in one mount.
      // Swapping a provider override between pumps is not a path that happens
      // in the app, and Riverpod does not reliably pick it up.
      final positions = StreamController<Duration>.broadcast();
      addTearDown(positions.close);

      await open(tester, app: buildApp(playing: true, positions: positions.stream));

      positions.add(const Duration(seconds: 1));
      await settle(tester);
      final atOneSecond = seekValue(tester);
      expect(atOneSecond, contains('0:00'));

      // Three seconds later, the same announcement.
      positions.add(const Duration(seconds: 4));
      await settle(tester);
      expect(seekValue(tester), atOneSecond);

      // Past the step, a new one.
      positions.add(const Duration(seconds: 7));
      await settle(tester);
      expect(seekValue(tester), isNot(atOneSecond));
      expect(seekValue(tester), contains('0:05'));
      handle.dispose();
    });

    testWidgets('it is still a slider that can be seeked', (tester) async {
      // Coarsening the announcement must not cost the control itself.
      final handle = tester.ensureSemantics();

      await open(
        tester,
        app: buildApp(
          playing: true,
          positions: Stream.value(const Duration(seconds: 30)),
        ),
      );

      // hasAction lives on SemanticsData, not the node.
      final data = tester
          .getSemantics(find.bySemanticsLabel('Playback position'))
          .getSemanticsData();
      expect(data.hasFlag(SemanticsFlag.isSlider), isTrue);
      expect(data.hasAction(SemanticsAction.increase), isTrue);
      expect(data.hasAction(SemanticsAction.decrease), isTrue);
      expect(data.value, contains('3:22'), reason: 'the total should be read');
      handle.dispose();
    });
  });

  testWidgets('the player bar stays away until there is something to play',
      (tester) async {
    // Gone, not disabled: a permanent strip saying "Nothing playing" is a
    // control that does nothing, and clipping it to zero height would leave
    // every button in it as a zero-area node in the accessibility tree --
    // which is what crashed this app on the Windows accessibility bridge.
    await open(tester);
    expect(find.byType(PlayerBar), findsNothing);
    expect(find.byTooltip('Open now playing'), findsNothing);
  });

  testWidgets('the player bar rises into view when a track starts',
      (tester) async {
    await open(tester, app: buildApp(stageable: true));
    expect(find.byType(PlayerBar), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AppShell)),
    );
    (container.read(playerProvider.notifier) as _StageablePlayer).stageTrack();

    // Part-way through, the bar is present but not yet at full height: it is
    // sliding, not appearing.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final partial = tester.getSize(find.byType(PlayerBar));
    final partialVisible = tester.getRect(find.byType(SizeTransition)).height;
    expect(partialVisible, greaterThan(0));
    expect(partialVisible, lessThan(partial.height));

    await settle(tester);
    expect(find.byType(PlayerBar), findsOne);
    expect(find.byTooltip('Open now playing'), findsOne);
    expect(
      tester.getRect(find.byType(SizeTransition)).height,
      moreOrLessEquals(partial.height, epsilon: 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an artist page groups its tracks by release', (tester) async {
    // The list is what gets queued, so scattering an album's running order
    // scatters playback with it.
    await open(tester, app: buildApp(playing: true));
    await tester.tap(railItem('Artists'));
    await settle(tester);
    await tester.tap(find.text('PinocchioP').first);
    await settle(tester);

    final list = tester.widget<TrackList>(find.byType(TrackList));
    expect(list.groupByAlbum, isTrue);
    expect(tester.takeException(), isNull);
    await capture(tester, 'artist');
  });

  testWidgets('the narrowest allowed window does not overflow', (tester) async {
    // The minimum size main() permits. An overflow surfaces as an exception,
    // which takeException catches.
    await open(tester, size: const Size(860, 620));
    expect(tester.takeException(), isNull);

    await capture(tester, '07-narrow');
  });
}
