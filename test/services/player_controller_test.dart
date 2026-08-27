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

  @override
  Future<Duration> load(String filePath, {AudioLoadMode? mode}) async {
    voiceFinished = false;
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
