import 'dart:math' as math;
import 'dart:typed_data';

/// What the engine is currently doing.
enum PlaybackStatus {
  /// Nothing loaded.
  idle,

  /// Decoding a file.
  loading,
  playing,
  paused,

  /// Reached the end of the track.
  completed,

  /// The last operation failed; see [PlaybackEngine.lastError].
  error,
}

/// An audio output the engine can play to.
class AudioOutputDevice {
  const AudioOutputDevice({
    required this.id,
    required this.name,
    required this.isDefault,
  });

  final int id;
  final String name;
  final bool isDefault;

  @override
  bool operator ==(Object other) =>
      other is AudioOutputDevice && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'AudioOutputDevice($id, $name${isDefault ? ", default" : ""})';
}

/// One frame of visualisation data.
///
/// The engine hands back both representations because they answer different
/// questions: bars want the spectrum, an oscilloscope wants the waveform.
class SpectrumFrame {
  const SpectrumFrame({required this.magnitudes, required this.waveform});

  /// FFT magnitudes, low frequency first. Values are roughly 0..1 but can
  /// exceed 1 on loud material, so consumers should clamp.
  final Float32List magnitudes;

  /// Time-domain samples, roughly -1..1.
  final Float32List waveform;

  /// Whether the frame carries any signal at all.
  ///
  /// Worth checking before concluding the visualiser is broken: the tap reads
  /// post-mix output, so silence in means zeros out.
  bool get isSilent {
    for (final value in magnitudes) {
      if (value > 0.0001) return false;
    }
    return true;
  }

  static final empty = SpectrumFrame(
    magnitudes: Float32List(256),
    waveform: Float32List(256),
  );
}

/// Equalizer configuration, in decibels.
///
/// Stored as dB because that is what a person reading a slider expects, and
/// converted to the engine's linear gain at the boundary.
class EqualizerSettings {
  const EqualizerSettings({
    this.enabled = false,
    this.gainsDb = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    this.preampDb = 0,
  });

  /// A flat ten-band equalizer.
  static const flat = EqualizerSettings();

  final bool enabled;

  /// One value per band, low frequency first.
  final List<double> gainsDb;

  /// Overall gain applied before the bands.
  final double preampDb;

  int get bandCount => gainsDb.length;

  bool get isFlat =>
      preampDb == 0 && gainsDb.every((g) => g.abs() < 0.01);

  EqualizerSettings copyWith({
    bool? enabled,
    List<double>? gainsDb,
    double? preampDb,
  }) =>
      EqualizerSettings(
        enabled: enabled ?? this.enabled,
        gainsDb: gainsDb ?? this.gainsDb,
        preampDb: preampDb ?? this.preampDb,
      );

  EqualizerSettings withBand(int index, double db) {
    final next = [...gainsDb];
    if (index < 0 || index >= next.length) return this;
    next[index] = db;
    return copyWith(gainsDb: next);
  }

  /// Converts a decibel value into the linear multiplier the engine wants.
  ///
  /// SoLoud's parametric EQ takes 0..4 with 1 meaning flat, which corresponds
  /// to roughly -12 dB..+12 dB.
  static double dbToLinear(double db) =>
      math.pow(10, db / 20).toDouble().clamp(0.0, 4.0);

  /// The inverse of [dbToLinear].
  static double linearToDb(double linear) =>
      linear <= 0 ? -60 : 20 * (math.log(linear) / math.ln10);

  /// Decibel range the UI should offer.
  static const minDb = -12.0;
  static const maxDb = 12.0;

  @override
  String toString() =>
      'EqualizerSettings(enabled: $enabled, gains: $gainsDb, '
      'preamp: $preampDb)';
}

/// A named equalizer preset.
class EqualizerPreset {
  const EqualizerPreset(this.name, this.gainsDb);
  final String name;
  final List<double> gainsDb;

  EqualizerSettings toSettings({double preampDb = 0}) => EqualizerSettings(
        enabled: true,
        gainsDb: gainsDb,
        preampDb: preampDb,
      );
}

/// Presets for a ten-band equalizer, low frequency first.
const equalizerPresets = <EqualizerPreset>[
  EqualizerPreset('Flat', [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  EqualizerPreset('Bass boost', [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
  EqualizerPreset('Bass cut', [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
  EqualizerPreset('Treble boost', [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
  EqualizerPreset('Vocal', [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
  EqualizerPreset('Loudness', [5, 4, 1, 0, -1, -1, 0, 2, 4, 5]),
  EqualizerPreset('Soft', [3, 2, 1, 0, -1, -2, -2, -1, 1, 2]),
  EqualizerPreset('Electronic', [5, 4, 1, -1, -2, 0, 1, 2, 4, 5]),
  EqualizerPreset('Classical', [3, 2, 1, 0, 0, 0, -1, -1, -1, 1]),
];

/// How much of a file to hold in memory.
enum AudioLoadMode {
  /// Decode into RAM. Instant seeking, roughly 20 MB per decoded minute.
  memory,

  /// Stream from disk. Lower memory, and seeking in MP3 becomes noticeably
  /// slower because frames have to be walked.
  disk,
}

/// Plays audio files.
///
/// An interface rather than a direct dependency on the engine, so the app's
/// player logic can be tested against a fake and the engine can be replaced
/// without touching anything above this line.
abstract interface class PlaybackEngine {
  Future<void> initialize();
  Future<void> shutdown();
  bool get isInitialized;

  /// The most recent failure, cleared by the next successful operation.
  Object? get lastError;

  /// Loads [filePath] and returns its duration.
  ///
  /// Replaces whatever was loaded. Throws on an unreadable or undecodable file.
  Future<Duration> load(String filePath, {AudioLoadMode? mode});

  /// Starts or resumes playback of the loaded file.
  Future<void> play();
  void pause();

  /// Stops and unloads.
  Future<void> stop();

  void seek(Duration position);

  Duration get position;
  Duration get duration;
  PlaybackStatus get status;
  String? get loadedPath;

  /// 0.0 to 1.0, on a perceptual curve.
  double get volume;
  void setVolume(double value);

  /// Fades to [value] over [duration], for pausing without a click.
  void fadeVolume(double value, Duration duration);

  /// 0.25 to 4.0, where 1.0 is normal.
  double get speed;
  void setSpeed(double value);

  /// Fires when the loaded track reaches its end.
  Stream<void> get onCompleted;

  List<AudioOutputDevice> outputDevices();
  AudioOutputDevice? get currentOutputDevice;

  /// Switches output. Null selects the system default.
  Future<void> setOutputDevice(AudioOutputDevice? device);

  EqualizerSettings get equalizer;
  void setEqualizer(EqualizerSettings settings);

  /// Turns the visualisation tap on or off.
  ///
  /// Off by default: the tap costs an FFT per frame, and most of the app does
  /// not show a visualiser.
  void setSpectrumEnabled(bool enabled);
  bool get spectrumEnabled;

  /// Reads the latest visualisation frame, or null when the tap is off.
  SpectrumFrame? readSpectrum();

  /// Applies a ReplayGain adjustment for the current track, in decibels.
  ///
  /// Kept separate from [setVolume] so the user's volume setting is not
  /// rewritten by per-track normalisation.
  void setGainOffset(double db);
}
