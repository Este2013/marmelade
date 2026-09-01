import 'package:marmelade/data/db/database.dart';
import 'package:marmelade/data/repositories/library_repository.dart';
import 'package:marmelade/data/repositories/queue_repository.dart';
import 'package:marmelade/services/audio/playback_engine.dart';
import 'package:marmelade/services/audio/player_controller.dart';

/// A player that does nothing, so a row can be built without audio.
class SilentEngine implements PlaybackEngine {
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

class IdlePlayer extends PlayerController {
  IdlePlayer(MarmeladeDatabase db)
      : super(
          engine: SilentEngine(),
          queueRepository: QueueRepository(db),
          libraryRepository: LibraryRepository(db),
          db: db,
        );

  @override
  PlayerSnapshot build() => const PlayerSnapshot();
}
