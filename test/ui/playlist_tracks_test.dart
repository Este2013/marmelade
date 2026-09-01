import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/indexer/search_indexer.dart';
import 'package:marmelade/data/repositories/playlist_repository.dart';
import 'package:marmelade/data/repositories/queue_repository.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/features/playlists/playlist_tracks.dart';
import 'package:marmelade/domain/models/library_views.dart';
import 'package:marmelade/services/audio/playback_engine.dart';
import 'package:marmelade/services/audio/player_controller.dart';

/// A playlist repository that records the order it was told to save.
class _RecordingPlaylists extends PlaylistRepository {
  _RecordingPlaylists(MarmeladeDatabase db)
      : super(db: db, searchIndexer: SearchIndexer(db));

  final saved = <List<int>>[];

  @override
  Future<void> saveCustomOrder(int playlistId, List<int> trackIds) async {
    saved.add(trackIds);
  }
}

/// A player that does nothing, so a row can be built without audio.
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
  void setEqualizer(EqualizerSettings settings) {}
  @override
  void setSpectrumEnabled(bool enabled) {}
  @override
  SpectrumFrame? readSpectrum() => null;
  @override
  List<AudioOutputDevice> outputDevices() => const [];
  @override
  Future<void> setOutputDevice(AudioOutputDevice? device) async {}
}

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

/// Arranging a playlist by hand.
///
/// A drag cannot be photographed, so this is the only way to check what one
/// actually does -- and the rules are specific: a group moves as a block, and a
/// track dropped into another album rejoins its own.
void main() {
  late MarmeladeDatabase db;
  late _RecordingPlaylists playlists;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    playlists = _RecordingPlaylists(db);
  });

  tearDown(() => db.close());

  TrackRow track(int id, String title, String album) => TrackRow(
        id: id,
        title: title,
        credits: const [],
        durationMs: 200000,
        albumId: album.hashCode,
        albumTitle: album,
      );

  // Two albums, two tracks each, interleaved by album so grouping has
  // something to gather.
  final tracks = [
    track(1, 'Alpha one', 'Alpha'),
    track(2, 'Alpha two', 'Alpha'),
    track(3, 'Beta one', 'Beta'),
    track(4, 'Beta two', 'Beta'),
  ];

  Future<void> pump(
    WidgetTester tester, {
    PlaylistGrouping grouping = PlaylistGrouping.none,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          playlistRepositoryProvider.overrideWithValue(playlists),
          playbackEngineProvider.overrideWithValue(_SilentEngine()),
          playerProvider.overrideWith(() => _IdlePlayer(db)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PlaylistTracks(
              playlist: PlaylistCard(
                id: 5,
                name: 'Mine',
                kind: 'manual',
                trackCount: tracks.length,
                grouping: grouping,
              ),
              tracks: tracks,
              title: 'Tracks',
              header: const SizedBox(height: 8),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// Drags the handle at [from] onto the row at [to].
  Future<void> dragHandle(
    WidgetTester tester,
    Finder handle,
    Finder onto,
  ) async {
    final start = tester.getCenter(handle);
    final end = tester.getCenter(onto);
    final gesture = await tester.startGesture(start);
    // In steps, because a reorderable list needs the drag to be recognised
    // before it will follow the pointer.
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  group('the rules', () {
    // Tested directly rather than through a drag: a drag cannot be aimed
    // precisely enough to pin down an exact resulting order, and these are the
    // rules that decide what an arrangement means.

    List<PlaylistRow> rowsFor(PlaylistGrouping grouping) =>
        PlaylistTracks.buildRows(tracks, grouping);

    test('ungrouped, the rows are just the tracks', () {
      final rows = rowsFor(PlaylistGrouping.none);
      expect(rows.whereType<PlaylistGroupRow>(), isEmpty);
      expect(rows, hasLength(4));
    });

    test('grouped, a heading is inserted where the album turns over', () {
      final rows = rowsFor(PlaylistGrouping.album);
      expect(
        rows.whereType<PlaylistGroupRow>().map((r) => r.label),
        ['Alpha', 'Beta'],
      );
      expect(rows.whereType<PlaylistGroupRow>().first.count, 2);
      expect(rows, hasLength(6));
    });

    test('moving a track ungrouped puts it exactly where it was dropped', () {
      final rows = rowsFor(PlaylistGrouping.none);
      // The last track to the front.
      final moved = PlaylistTracks.move(rows, 3, 0);
      expect(
        PlaylistTracks.trackOrder(moved, PlaylistGrouping.none),
        [4, 1, 2, 3],
      );
    });

    test('moving a heading carries its tracks', () {
      final rows = rowsFor(PlaylistGrouping.album);
      // Beta's heading is at index 3; to the very top.
      final moved = PlaylistTracks.move(rows, 3, 0);
      expect(
        PlaylistTracks.trackOrder(moved, PlaylistGrouping.album),
        [3, 4, 1, 2],
      );
    });

    test('a heading and its tracks never come apart', () {
      final rows = rowsFor(PlaylistGrouping.album);
      // Into the middle of the other album, which is not a state the list can
      // render -- the block goes as a block.
      final moved = PlaylistTracks.move(rows, 3, 2);
      final order = PlaylistTracks.trackOrder(moved, PlaylistGrouping.album);
      expect(order.toSet(), {1, 2, 3, 4});
      expect((order.indexOf(1) - order.indexOf(2)).abs(), 1);
      expect((order.indexOf(3) - order.indexOf(4)).abs(), 1);
    });

    test('a track dropped into another album rejoins its own', () {
      // The group *is* the album, so landing under another heading cannot mean
      // anything else.
      final rows = rowsFor(PlaylistGrouping.album);
      // Beta's second track (index 5) up among Alpha's (index 1).
      final moved = PlaylistTracks.move(rows, 5, 1);
      final order = PlaylistTracks.trackOrder(moved, PlaylistGrouping.album);

      expect(order, [1, 2, 4, 3]);
      // It moved inside Beta -- ahead of the track it was dropped above -- and
      // the groups did not move. Dragging a track is a statement about that
      // track, not about where its album belongs.
      expect(order.indexOf(4), lessThan(order.indexOf(3)));
      expect(order.indexOf(1), lessThan(order.indexOf(3)));
    });

    test('nothing is ever lost by a move', () {
      final rows = rowsFor(PlaylistGrouping.album);
      for (var from = 0; from < rows.length; from++) {
        for (var to = 0; to <= rows.length; to++) {
          final order = PlaylistTracks.trackOrder(
            PlaylistTracks.move(rows, from, to),
            PlaylistGrouping.album,
          );
          expect(order.toSet(), {1, 2, 3, 4}, reason: '$from -> $to');
          expect(order, hasLength(4), reason: '$from -> $to');
        }
      }
    });
  });

  group('a group is one section', () {
    // The bug this pins: a custom order puts tracks it has never seen at the
    // end, so an album could arrive both at its arranged place and again at
    // the bottom. A heading per turnover then meant two headings with the same
    // name, two widgets with the same key, and a crash that wedged the list --
    // after which no further reorder registered at all.
    final scattered = [
      track(1, 'Alpha one', 'Alpha'),
      track(3, 'Beta one', 'Beta'),
      track(2, 'Alpha two', 'Alpha'),
      track(4, 'Beta two', 'Beta'),
    ];

    test('a label appears once however scattered the order', () {
      final rows = PlaylistTracks.buildRows(scattered, PlaylistGrouping.album);
      final labels =
          rows.whereType<PlaylistGroupRow>().map((r) => r.label).toList();

      expect(labels, ['Alpha', 'Beta']);
      expect(labels.toSet().length, labels.length);
    });

    test('gathering keeps every track, in the order each group had', () {
      final rows = PlaylistTracks.buildRows(scattered, PlaylistGrouping.album);
      expect(
        PlaylistTracks.displayOrder(rows).map((t) => t.id),
        [1, 2, 3, 4],
      );
    });

    test('positions follow the rows, not the list handed in', () {
      // Playing from a row queues the displayed order, so a position that
      // referred to the original list would start the wrong song.
      final rows = PlaylistTracks.buildRows(scattered, PlaylistGrouping.album);
      final slots = rows.whereType<PlaylistTrackSlot>().toList();
      expect(slots.map((s) => s.position), [0, 1, 2, 3]);
      expect(slots[1].track.id, 2);
    });

    testWidgets('a scattered order renders without a key collision',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            playlistRepositoryProvider.overrideWithValue(playlists),
            playbackEngineProvider.overrideWithValue(_SilentEngine()),
            playerProvider.overrideWith(() => _IdlePlayer(db)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PlaylistTracks(
                playlist: const PlaylistCard(
                  id: 5,
                  name: 'Mine',
                  kind: 'manual',
                  trackCount: 4,
                  grouping: PlaylistGrouping.album,
                ),
                tracks: scattered,
                title: 'Tracks',
                header: const SizedBox(height: 8),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('2 tracks'), findsNWidgets(2));
    });

    testWidgets('the heading fits the narrowest window', (tester) async {
      // 860 is the minimum the window can be dragged to, and the heading now
      // carries the title, the collapse button and two dropdowns on one line.
      await tester.binding.setSurfaceSize(const Size(860, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            playlistRepositoryProvider.overrideWithValue(playlists),
            playbackEngineProvider.overrideWithValue(_SilentEngine()),
            playerProvider.overrideWith(() => _IdlePlayer(db)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PlaylistTracks(
                playlist: const PlaylistCard(
                  id: 5,
                  name: 'Mine',
                  kind: 'smart',
                  trackCount: 4,
                  grouping: PlaylistGrouping.album,
                  displaySort: PlaylistSort.custom,
                ),
                tracks: scattered,
                title: 'Every track, including the included playlists',
                header: const SizedBox(height: 8),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Collapse all'), findsOneWidget);
    });
  });

  group('collapsing', () {
    test('a hidden group keeps its tracks in a saved arrangement', () {
      // The dangerous case: fold a group away, drag something else, and the
      // order that gets saved must still contain the tracks nobody can see --
      // otherwise collapsing a group deletes it from the arrangement.
      final rows = PlaylistTracks.buildRows(tracks, PlaylistGrouping.album);
      // What the list shows with Beta collapsed: both headings, Alpha's two.
      final visible = [
        for (final row in rows)
          if (row is! PlaylistTrackSlot ||
              PlaylistTracks.groupLabel(row.track, PlaylistGrouping.album) !=
                  'Beta')
            row,
      ];
      expect(visible, hasLength(4));

      final moved = PlaylistTracks.move(visible, 2, 1);
      final order = PlaylistTracks.trackOrder(
        moved,
        PlaylistGrouping.album,
        hidden: tracks,
      );

      expect(order.toSet(), {1, 2, 3, 4});
      expect((order.indexOf(3) - order.indexOf(4)).abs(), 1);
    });

    test('a collapsed group can still be moved as a block', () {
      final rows = PlaylistTracks.buildRows(tracks, PlaylistGrouping.album);
      final visible = [
        for (final row in rows)
          if (row is! PlaylistTrackSlot ||
              PlaylistTracks.groupLabel(row.track, PlaylistGrouping.album) !=
                  'Beta')
            row,
      ];

      // Beta's heading is last in the visible list; move it to the top.
      final moved = PlaylistTracks.move(visible, 3, 0);
      final order = PlaylistTracks.trackOrder(
        moved,
        PlaylistGrouping.album,
        hidden: tracks,
      );

      expect(order, [3, 4, 1, 2]);
    });
  });

  group('the list itself', () {
    testWidgets('ungrouped, every track has a handle and no headings',
        (tester) async {
      await pump(tester);

      expect(find.byTooltip('Drag to rearrange'), findsNWidgets(4));
      expect(find.byTooltip('Drag to move this whole group'), findsNothing);
    });

    testWidgets('grouping by album adds a heading per album', (tester) async {
      await pump(tester, grouping: PlaylistGrouping.album);

      expect(find.byTooltip('Drag to move this whole group'), findsNWidgets(2));
      // The heading says how big the group is, which the rows cannot.
      expect(find.text('2 tracks'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('dragging a track stores an arrangement', (tester) async {
      // What the drag has to do: hand a complete order to the repository. Which
      // order depends on where it landed, and that is the rules' business.
      await pump(tester);

      await dragHandle(
        tester,
        find.byTooltip('Drag to rearrange').last,
        find.text('Alpha one'),
      );

      expect(playlists.saved, isNotEmpty);
      expect(playlists.saved.last.toSet(), {1, 2, 3, 4});
      expect(tester.takeException(), isNull);
    });

    testWidgets('clicking a heading folds its group away', (tester) async {
      await pump(tester, grouping: PlaylistGrouping.album);
      expect(find.text('Alpha one'), findsOneWidget);

      await tester.tap(find.text('2 tracks').first);
      await tester.pumpAndSettle();

      // The heading stays; its tracks go.
      expect(find.text('2 tracks'), findsNWidgets(2));
      expect(find.text('Alpha one'), findsNothing);
      expect(find.text('Beta one'), findsOneWidget);
    });

    testWidgets('collapse all folds every group, and offers to undo it',
        (tester) async {
      await pump(tester, grouping: PlaylistGrouping.album);

      await tester.tap(find.text('Collapse all'));
      await tester.pumpAndSettle();

      expect(find.text('Alpha one'), findsNothing);
      expect(find.text('Beta one'), findsNothing);
      expect(find.text('Expand all'), findsOneWidget);

      await tester.tap(find.text('Expand all'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha one'), findsOneWidget);
    });

    testWidgets('there is nothing to collapse when there are no groups',
        (tester) async {
      await pump(tester);
      expect(find.text('Collapse all'), findsNothing);
    });

    testWidgets('a group heading can be dragged too', (tester) async {
      await pump(tester, grouping: PlaylistGrouping.album);

      await dragHandle(
        tester,
        find.byTooltip('Drag to move this whole group').last,
        find.text('Alpha one'),
      );

      expect(playlists.saved, isNotEmpty);
      final saved = playlists.saved.last;
      expect(saved.toSet(), {1, 2, 3, 4});
      // Whatever it landed on, the groups are still whole.
      expect((saved.indexOf(1) - saved.indexOf(2)).abs(), 1);
      expect((saved.indexOf(3) - saved.indexOf(4)).abs(), 1);
    });
  });
}
