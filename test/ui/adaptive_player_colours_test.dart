import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/repositories/queue_repository.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/features/player/player_bar.dart';
import 'package:marmelade/services/audio/playback_engine.dart';
import 'package:marmelade/services/audio/player_controller.dart';
import 'package:marmelade/services/art/art_store.dart';

import '../support/silent_player.dart';

/// The player bar taking its colours from what is playing.
///
/// Opt-in, and that is the part worth pinning down: a strongly coloured
/// sleeve makes a strongly coloured bar, so the app's own colours have to be
/// what you get until the setting is turned on -- and have to come back when
/// it is turned off, or when a track has no picture to take them from.
void main() {
  late MarmeladeDatabase db;
  late Directory artRoot;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    artRoot = Directory.systemTemp.createTempSync('marmelade_colours_');
  });
  tearDown(() async {
    await db.close();
    if (artRoot.existsSync()) artRoot.deleteSync(recursive: true);
  });

  /// A scheme nothing else in the app would produce, so its arrival is
  /// unmistakable.
  final fromArtwork = ColorScheme.fromSeed(
    seedColor: const Color(0xFF00E5FF),
    brightness: Brightness.dark,
  );

  Future<Color> barColour(
    WidgetTester tester, {
    required bool adaptive,
    String? artwork = 'art/cover.jpg',
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          artStoreProvider.overrideWithValue(ArtStore(artRoot)),
          playbackEngineProvider.overrideWithValue(SilentEngine()),
          playerProvider.overrideWith(() => _Playing(db, artwork)),
          adaptivePlayerColorsProvider.overrideWith(() => _Flag(adaptive)),
          if (artwork != null)
            artworkSchemeProvider((path: artwork, brightness: Brightness.dark))
                .overrideWith((ref) async => fromArtwork),
        ],
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFE8730C),
              brightness: Brightness.dark,
            ),
          ),
          home: Scaffold(
            body: PlayerBar(
              expanded: false,
              onToggleExpanded: () {},
              onOpenQueue: () {},
            ),
          ),
        ),
      ),
    );
    // Long enough for the scheme to arrive and the cross-fade to land.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // First in tree order: the bar's own surface, which every button's
    // Material sits inside.
    return tester
        .widget<Material>(find
            .descendant(
              of: find.byType(PlayerBar),
              matching: find.byType(Material),
            )
            .first)
        .color!;
  }

  testWidgets('leaves the bar alone until the setting is on', (tester) async {
    final colour = await barColour(tester, adaptive: false);

    expect(colour, isNot(fromArtwork.surfaceContainer));
  });

  testWidgets('takes the artwork colours once it is on', (tester) async {
    final colour = await barColour(tester, adaptive: true);

    expect(colour, fromArtwork.surfaceContainer);
  });

  testWidgets('survives moving to a differently coloured release',
      (tester) async {
    // What the first album change did: AnimatedTheme lerped the app's merged
    // text styles against a freshly built theme's plain ones, TextStyle.lerp
    // refused, and the whole bar became an error widget.
    const second = 'art/other.jpg';
    final otherScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFF1744),
      brightness: Brightness.dark,
    );

    await tester.binding.setSurfaceSize(const Size(1200, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      artStoreProvider.overrideWithValue(ArtStore(artRoot)),
      playbackEngineProvider.overrideWithValue(SilentEngine()),
      playerProvider.overrideWith(() => _Playing(db, 'art/cover.jpg')),
      adaptivePlayerColorsProvider.overrideWith(() => _Flag(true)),
      artworkSchemeProvider((path: 'art/cover.jpg', brightness: Brightness.dark))
          .overrideWith((ref) async => fromArtwork),
      artworkSchemeProvider((path: second, brightness: Brightness.dark))
          .overrideWith((ref) async => otherScheme),
    ]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFE8730C),
              brightness: Brightness.dark,
            ),
          ),
          home: Scaffold(
            body: PlayerBar(
              expanded: false,
              onToggleExpanded: () {},
              onOpenQueue: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    (container.read(playerProvider.notifier) as _Playing).moveTo(second);
    await tester.pump();
    // Mid-fade, which is where the interpolation happens and where it threw.
    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<Material>(find
              .descendant(
                of: find.byType(PlayerBar),
                matching: find.byType(Material),
              )
              .first)
          .color,
      otherScheme.surfaceContainer,
    );

    // Unmounted and disposed here rather than in a tearDown: drift posts a
    // zero-duration cleanup timer when a query stream is cancelled, and after
    // the body has finished there is no pump left to run it, so the binding
    // fails the test on a pending timer.
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('keeps the app colours for a track with no picture',
      (tester) async {
    // Nothing to take them from, so nothing is taken -- rather than a bar
    // that flickers to a default palette between two illustrated tracks.
    final colour = await barColour(tester, adaptive: true, artwork: null);

    expect(colour, isNot(fromArtwork.surfaceContainer));
  });
}

/// A player with something on, with or without a cover.
class _Playing extends PlayerController {
  _Playing(MarmeladeDatabase db, this.artwork)
      : super(
          engine: SilentEngine(),
          queueRepository: QueueRepository(db),
          libraryRepository: LibraryRepository(db),
          db: db,
        );

  final String? artwork;

  static PlayerSnapshot _snapshot(String? artwork) => PlayerSnapshot(
        status: PlaybackStatus.playing,
        currentIndex: 0,
        duration: const Duration(minutes: 3),
        current: PlayableTrack(
          trackId: 1,
          filePath: 'C:/nowhere/song.flac',
          title: 'Idol',
          artistLine: 'YOASOBI',
          durationMs: 180000,
          imagePath: artwork,
        ),
      );

  @override
  PlayerSnapshot build() => _snapshot(artwork);

  /// Moves to a track from another release, the way skipping does.
  void moveTo(String? nextArtwork) => state = _snapshot(nextArtwork);
}

/// The setting, fixed.
class _Flag extends StoredFlag {
  _Flag(this.value) : super('test.adaptive');

  final bool value;

  @override
  bool build() => value;
}
