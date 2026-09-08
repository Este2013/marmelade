import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marmelade/app/providers.dart';
import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/repositories/queue_repository.dart';
import 'package:marmelade/services/audio/playback_engine.dart';
import 'package:marmelade/services/audio/player_controller.dart';

/// An engine that behaves the way SoLoud does around the end of a track.
///
/// The detail that matters: once a voice finishes, its handle is gone, and any
/// control aimed at it throws. Anything that calls pause on a finished voice is
/// a bug, and this fake is what makes that bug visible in a test.
class _EndingEngine implements PlaybackEngine {
  final _completed = StreamController<void>.broadcast();

  /// True once the voice has finished and its handle is no longer valid.
  var voiceFinished = false;

  var pauseCalls = 0;
  var playCalls = 0;

  @override
  PlaybackStatus status = PlaybackStatus.idle;

  /// Ends the current track, the way `allInstancesFinished` does.
  void finishTrack() {
    voiceFinished = true;
    status = PlaybackStatus.completed;
    _completed.add(null);
  }

  Future<void> dispose() => _completed.close();

  @override
  void pause() {
    pauseCalls += 1;
    if (voiceFinished) {
      // Exactly what flutter_soloud raises: the handle is not found.
      throw StateError('the sound handle is not found (on the C++ side)');
    }
    status = PlaybackStatus.paused;
  }

  @override
  Future<void> play() async {
    playCalls += 1;
    voiceFinished = false;
    status = PlaybackStatus.playing;
  }

  /// The file the engine is actually sounding, which is the thing the
  /// snapshot claims to be describing.
  String? lastLoadedPath;

  /// Set to make the next load hang, the way a wedged device does.
  var hangOnNextLoad = false;
  Completer<Duration>? _hung;

  void releaseHungLoad() {
    _hung?.complete(const Duration(minutes: 3));
    _hung = null;
  }

  @override
  Future<Duration> load(String filePath, {AudioLoadMode? mode}) async {
    voiceFinished = false;
    if (hangOnNextLoad) {
      // Consumed, so only the command it was set for hangs -- the queued one
      // behind it runs normally, which is the whole point of the test.
      hangOnNextLoad = false;
      _hung = Completer<Duration>();
      return _hung!.future;
    }
    // A real load is not instant, and the gap is where two overlapping
    // commands used to interleave.
    await Future<void>.delayed(Duration.zero);
    lastLoadedPath = filePath;
    return const Duration(minutes: 3);
  }

  @override
  Future<void> stop() async {
    voiceFinished = false;
    status = PlaybackStatus.idle;
  }

  @override
  Stream<void> get onCompleted => _completed.stream;

  @override
  bool get isInitialized => true;
  @override
  Object? get lastError => null;
  @override
  String? get loadedPath => null;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get duration => const Duration(minutes: 3);
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
  Future<void> initialize() async {}
  @override
  Future<void> shutdown() async {}
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
  SpectrumFrame? readSpectrum() => null;
  @override
  List<AudioOutputDevice> outputDevices() => const [];
  @override
  Future<void> setOutputDevice(AudioOutputDevice? device) async {}
  @override
  void setSpectrumEnabled(bool enabled) {}
}

void main() {
  late MarmeladeDatabase db;
  late _EndingEngine engine;
  late ProviderContainer container;

  setUp(() async {
    db = MarmeladeDatabase.memory();
    await db.customSelect('SELECT 1').get();
    engine = _EndingEngine();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine),
        playerProvider.overrideWith(
          () => PlayerController(
            engine: engine,
            queueRepository: QueueRepository(db),
            libraryRepository: LibraryRepository(db),
            db: db,
            // Short, so the test that proves a wedged command cannot hold the
            // queue does not cost the suite the ten seconds the app allows.
            commandTimeout: const Duration(milliseconds: 300),
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await engine.dispose();
    await db.close();
  });

  /// A track with a media file, so it is playable.
  Future<int> playableTrack(String title) async {
    final folderId = await db.into(db.libraryFolders).insert(
          LibraryFoldersCompanion.insert(path: 'C:/music-$title'),
        );
    final trackId = await db.into(db.tracks).insert(
          TracksCompanion.insert(title: title, nameKey: title.toLowerCase()),
        );
    await db.into(db.mediaFiles).insert(
          MediaFilesCompanion.insert(
            folderId: folderId,
            relativePath: '$title.flac',
            fileName: '$title.flac',
            extension: 'flac',
            sizeBytes: 1000,
            modifiedAt: DateTime.now().toUtc(),
            quickKey: Value('quick-$title'),
            trackId: Value(trackId),
            // Files default to pendingScan, and only a present file is
            // playable.
            status: const Value(FileStatus.present),
          ),
        );
    return trackId;
  }

  /// Choosing a song while one is ending.
  ///
  /// Reported from real listening: clicking a song in an album that was
  /// already playing sometimes started a neighbouring one instead, while the
  /// title on screen was the song that had been clicked. Both halves come
  /// from the same place -- a track ending and a click landing together, each
  /// reading and writing the same index across several awaits.
  group('a click landing as a track ends', () {
    test('plays what was clicked, not where the advance was going', () async {
      final one = await playableTrack('One');
      final two = await playableTrack('Two');
      final three = await playableTrack('Three');
      final controller = container.read(playerProvider.notifier);
      await controller.playAll([one, two, three]);

      // The track ends, and in the same beat a song further down is clicked.
      // The advance would go to Two; the person asked for Three.
      engine.finishTrack();
      await controller.playAll([one, two, three], startIndex: 2);
      await pumpEventQueue();

      expect(container.read(playerProvider).current?.trackId, three);
      expect(container.read(playerProvider).currentIndex, 2);
      expect(container.read(playerProvider).isPlaying, isTrue);
    });

    test('what is playing and what is named are the same song', () async {
      // The tell in the report: the right title over the wrong audio. Two
      // overlapping loads each set the snapshot after their own await, so the
      // last to finish named a track the engine was not playing.
      final one = await playableTrack('One');
      final two = await playableTrack('Two');
      final controller = container.read(playerProvider.notifier);
      await controller.playAll([one, two]);

      engine.finishTrack();
      await controller.playAll([one, two], startIndex: 1);
      await pumpEventQueue();

      final snapshot = container.read(playerProvider);
      expect(snapshot.current?.trackId, snapshot.queue[snapshot.currentIndex].trackId);
      // The half that was audible: the file the engine holds has to be the
      // one the snapshot is naming.
      expect(engine.lastLoadedPath, snapshot.current?.filePath);
    });

    test('still advances on its own when nobody interrupts', () async {
      // The guard must not cost the ordinary case: an album left alone has to
      // keep playing through.
      final one = await playableTrack('One');
      final two = await playableTrack('Two');
      final controller = container.read(playerProvider.notifier);
      await controller.playAll([one, two]);

      engine.finishTrack();
      await pumpEventQueue();

      expect(container.read(playerProvider).currentIndex, 1);
      expect(container.read(playerProvider).current?.trackId, two);
    });
  });

  /// One stuck command must not take the player with it.
  ///
  /// Track changes run one at a time, which fixed a real bug and introduced
  /// the risk of another: a load that never returns would hold every later
  /// command behind it, and the first thing anybody would notice is the media
  /// keys going dead.
  group('a command that never finishes', () {
    test('lets the next one through, and the player still answers', () async {
      final one = await playableTrack('One');
      final two = await playableTrack('Two');
      final controller = container.read(playerProvider.notifier);
      await controller.playAll([one, two]);

      // A load that hangs, the way a wedged audio device would.
      engine.hangOnNextLoad = true;
      final stuck = controller.playAt(1);

      // The command behind it, which must not wait forever. The controller
      // under test is built with a 300ms budget, so this returns quickly
      // rather than after the ten seconds the app allows.
      await controller.playAt(0).timeout(const Duration(seconds: 5));

      expect(container.read(playerProvider).currentIndex, 0);
      expect(container.read(playerProvider).isPlaying, isTrue);
      engine.releaseHungLoad();
      await stuck;
    });
  });

  group('the end of the queue', () {
    test('finishing the last track leaves the player not playing', () async {
      final controller = container.read(playerProvider.notifier);
      await controller.playAll([await playableTrack('Only')]);
      expect(container.read(playerProvider).isPlaying, isTrue);

      engine.finishTrack();
      // Let the completion event travel and the handler finish.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // The bug this covers: an engine call throwing here stranded the snapshot
      // at "playing", so the bar kept showing a pause button.
      expect(container.read(playerProvider).isPlaying, isFalse);
      expect(
        container.read(playerProvider).status,
        PlaybackStatus.completed,
      );
    });

    test('pressing play after the queue ends starts again, not pauses',
        () async {
      final controller = container.read(playerProvider.notifier);
      await controller.playAll([await playableTrack('Only')]);
      engine.finishTrack();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final pausesBefore = engine.pauseCalls;
      // This is the tap that threw SoLoudSoundHandleNotFoundCppException.
      await controller.togglePlayPause();

      expect(engine.pauseCalls, pausesBefore,
          reason: 'a finished voice must not be paused');
      expect(engine.playCalls, greaterThan(1));
      expect(container.read(playerProvider).isPlaying, isTrue);
    });

    test('a queue of two advances rather than stopping', () async {
      final controller = container.read(playerProvider.notifier);
      await controller.playAll([
        await playableTrack('First'),
        await playableTrack('Second'),
      ]);
      expect(container.read(playerProvider).currentIndex, 0);

      engine.finishTrack();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(playerProvider).currentIndex, 1);
      expect(container.read(playerProvider).isPlaying, isTrue);
    });

    test('repeating the queue wraps to the start', () async {
      final controller = container.read(playerProvider.notifier);
      await controller.playAll([await playableTrack('Only')]);
      controller.setRepeat(QueueRepeat.all);

      engine.finishTrack();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(playerProvider).currentIndex, 0);
      expect(container.read(playerProvider).isPlaying, isTrue);
    });
  });
}
