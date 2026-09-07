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

  @override
  PlayerSnapshot build() => PlayerSnapshot(
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
}

/// The setting, fixed.
class _Flag extends StoredFlag {
  _Flag(this.value) : super('test.adaptive');

  final bool value;

  @override
  bool build() => value;
}
