import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/repositories/playlist_repository.dart';
import 'package:marmelade/data/repositories/queue_repository.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/features/playlists/playlists_view.dart';
import 'package:marmelade/services/audio/playback_engine.dart';
import 'package:marmelade/services/audio/player_controller.dart';

/// An engine that does nothing -- the fake player below never actually calls
/// it, but PlayerController's constructor still wants one.
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

/// Records what a playlist tile's quick-play button asked for, instead of
/// actually touching an audio engine or a real queue.
class _RecordingPlayer extends PlayerController {
  _RecordingPlayer(MarmeladeDatabase db)
      : super(
          engine: _SilentEngine(),
          queueRepository: QueueRepository(db),
          libraryRepository: LibraryRepository(db),
          db: db,
        );

  List<int>? lastTrackIds;
  QueueSource? lastSource;
  int? lastSourceRefId;

  @override
  PlayerSnapshot build() => const PlayerSnapshot();

  @override
  Future<void> playAll(
    List<int> trackIds, {
    int startIndex = 0,
    QueueSource source = QueueSource.user,
    int? sourceRefId,
  }) async {
    lastTrackIds = trackIds;
    lastSource = source;
    lastSourceRefId = sourceRefId;
  }
}

/// A playlist repository that answers a fixed set of tracks, so a test does
/// not have to seed a real playlist's rows just to press one button.
class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository(MarmeladeDatabase db, this.contents)
      : super(db: db, searchIndexer: SearchIndexer(db));

  final List<int> contents;

  @override
  Future<List<int>> resolveContents(int playlistId) async => contents;
}

void main() {
  late MarmeladeDatabase db;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() => db.close());

  testWidgets('the quick-play button resolves and plays the playlist',
      (tester) async {
    final player = _RecordingPlayer(db);
    const playlist = PlaylistCard(
      id: 7,
      name: 'Late night',
      kind: 'manual',
      trackCount: 3,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playlistsProvider.overrideWith((ref) => Stream.value(const [playlist])),
          playlistInclusionsProvider.overrideWith((ref) => Stream.value(const [])),
          playlistRepositoryProvider.overrideWithValue(
            _FakePlaylistRepository(db, [10, 11, 12]),
          ),
          playerProvider.overrideWith(() => player),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PlaylistsView(onOpenPlaylist: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Late night'), findsOneWidget);

    await tester.tap(find.byTooltip('Play'));
    await tester.pumpAndSettle();

    expect(player.lastTrackIds, [10, 11, 12]);
    expect(player.lastSource, QueueSource.playlist);
    expect(player.lastSourceRefId, 7);
  });

  testWidgets('an empty playlist does nothing rather than throwing',
      (tester) async {
    final player = _RecordingPlayer(db);
    const playlist = PlaylistCard(
      id: 7,
      name: 'Empty for now',
      kind: 'smart',
      trackCount: 0,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playlistsProvider.overrideWith((ref) => Stream.value(const [playlist])),
          playlistInclusionsProvider.overrideWith((ref) => Stream.value(const [])),
          playlistRepositoryProvider.overrideWithValue(
            _FakePlaylistRepository(db, const []),
          ),
          playerProvider.overrideWith(() => player),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PlaylistsView(onOpenPlaylist: (_) {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Play'));
    await tester.pumpAndSettle();

    expect(player.lastTrackIds, isNull);
    expect(tester.takeException(), isNull);
  });

  group('the nesting tree', () {
    // All three sit at the top level of their own folder placement --
    // "Coding sessions" includes "Late night", which includes "Focus", the
    // same way addChildPlaylist() links them, rather than through the
    // unrelated parent_id/folder mechanism.
    const parent = PlaylistCard(
      id: 1,
      name: 'Coding sessions',
      kind: 'manual',
      trackCount: 0,
      childCount: 1,
    );
    const child = PlaylistCard(
      id: 2,
      name: 'Late night',
      kind: 'manual',
      trackCount: 5,
      childCount: 1,
    );
    const grandchild = PlaylistCard(
      id: 3,
      name: 'Focus',
      kind: 'manual',
      trackCount: 5,
    );

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            playlistsProvider.overrideWith(
              (ref) => Stream.value(const [parent, child, grandchild]),
            ),
            playlistInclusionsProvider.overrideWith(
              (ref) => Stream.value(const [
                PlaylistInclusion(parentId: 1, childId: 2),
                PlaylistInclusion(parentId: 2, childId: 3),
              ]),
            ),
            playlistRepositoryProvider.overrideWithValue(
              _FakePlaylistRepository(db, const []),
            ),
            playerProvider.overrideWith(() => _RecordingPlayer(db)),
          ],
          child: MaterialApp(
            home: Scaffold(body: PlaylistsView(onOpenPlaylist: (_) {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder toggleFor(String name) => find.descendant(
          of: find.ancestor(
            of: find.text(name),
            matching: find.byType(InkWell),
          ),
          matching: find.byTooltip('Hide what it contains'),
        );

    testWidgets('a playlist with nothing inside offers no toggle',
        (tester) async {
      await pump(tester);

      final tile = find.ancestor(
        of: find.text('Focus'),
        matching: find.byType(InkWell),
      );
      expect(
        find.descendant(of: tile, matching: find.byTooltip('Hide what it contains')),
        findsNothing,
      );
    });

    testWidgets('an included playlist does not also float at the top level',
        (tester) async {
      // The bug this whole tree exists to fix: before, "Late night" and
      // "Focus" each got their own untouched, unindented row up top, with no
      // sign they were included anywhere.
      await pump(tester);

      expect(find.text('Late night'), findsOneWidget);
      expect(find.text('Focus'), findsOneWidget);

      final lateNight = tester.getRect(find.text('Late night'));
      final focus = tester.getRect(find.text('Focus'));
      final root = tester.getRect(find.text('Coding sessions'));
      expect(lateNight.left, greaterThan(root.left));
      expect(focus.left, greaterThan(lateNight.left));
    });

    testWidgets('collapsing a playlist hides everything nested under it',
        (tester) async {
      await pump(tester);

      expect(find.text('Late night'), findsOneWidget);
      expect(find.text('Focus'), findsOneWidget);

      await tester.tap(toggleFor('Coding sessions'));
      await tester.pumpAndSettle();

      expect(find.text('Coding sessions'), findsOneWidget);
      expect(find.text('Late night'), findsNothing);
      expect(find.text('Focus'), findsNothing);
    });

    testWidgets('expanding it again brings the whole branch back',
        (tester) async {
      await pump(tester);

      await tester.tap(toggleFor('Coding sessions'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show what it contains'));
      await tester.pumpAndSettle();

      expect(find.text('Late night'), findsOneWidget);
      expect(find.text('Focus'), findsOneWidget);
    });
  });
}
