import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_soloud/flutter_soloud.dart' as sl;

import 'playback_engine.dart';

/// [PlaybackEngine] backed by SoLoud.
///
/// Chosen because it is the only Windows-capable option that covers every audio
/// requirement in one engine: MP3/FLAC/WAV decode, an FFT tap for the
/// visualiser, a parametric equalizer, playback speed, and output device
/// switching. See docs/ARCHITECTURE.md.
class SoLoudEngine implements PlaybackEngine {
  SoLoudEngine({
    this.defaultLoadMode = AudioLoadMode.memory,
    this.bufferSize = 1024,
  });

  /// How files are loaded unless a call overrides it.
  ///
  /// Memory by default: seeking is instant, which matters far more in a music
  /// player than the RAM cost of one decoded track.
  final AudioLoadMode defaultLoadMode;

  /// Mixer buffer size.
  ///
  /// 1024 rather than SoLoud's 2048 default: it gives visibly better FFT
  /// resolution, which the visualiser needs, at no audible cost here.
  final int bufferSize;

  sl.SoLoud get _soloud => sl.SoLoud.instance;

  sl.AudioSource? _source;
  sl.SoundHandle? _handle;
  sl.AudioData? _audioData;
  StreamSubscription<void>? _completionSubscription;

  final _completed = StreamController<void>.broadcast();

  var _status = PlaybackStatus.idle;
  String? _loadedPath;
  Duration _duration = Duration.zero;
  Object? _lastError;

  double _volume = 1;
  double _speed = 1;
  double _gainOffsetDb = 0;
  var _equalizer = EqualizerSettings.flat;
  var _spectrumEnabled = false;

  /// Position at the moment playback stopped, so it survives a pause.
  Duration _lastKnownPosition = Duration.zero;

  @override
  bool get isInitialized => _soloud.isInitialized;

  @override
  Object? get lastError => _lastError;

  @override
  PlaybackStatus get status => _status;

  @override
  String? get loadedPath => _loadedPath;

  @override
  Duration get duration => _duration;

  @override
  Stream<void> get onCompleted => _completed.stream;

  @override
  double get volume => _volume;

  @override
  double get speed => _speed;

  @override
  EqualizerSettings get equalizer => _equalizer;

  @override
  bool get spectrumEnabled => _spectrumEnabled;

  @override
  Future<void> initialize() async {
    if (_soloud.isInitialized) return;
    try {
      await _soloud.init(bufferSize: bufferSize);
      _lastError = null;
    } catch (e) {
      _lastError = e;
      _status = PlaybackStatus.error;
      rethrow;
    }
  }

  @override
  Future<void> shutdown() async {
    await _releaseSource();
    _audioData?.dispose();
    _audioData = null;
    await _completed.close();
    if (_soloud.isInitialized) _soloud.deinit();
    _status = PlaybackStatus.idle;
  }

  @override
  Future<Duration> load(String filePath, {AudioLoadMode? mode}) async {
    await initialize();
    await _releaseSource();

    _status = PlaybackStatus.loading;
    _loadedPath = filePath;
    _lastKnownPosition = Duration.zero;

    try {
      final source = await _soloud.loadFile(
        filePath,
        mode: (mode ?? defaultLoadMode) == AudioLoadMode.memory
            ? sl.LoadMode.memory
            : sl.LoadMode.disk,
      );
      _source = source;
      _duration = _soloud.getLength(source);

      // Fires once every voice for this source has ended, which is the clean
      // signal that the track finished rather than was stopped.
      _completionSubscription = source.allInstancesFinished.listen((_) {
        // A stop() or a load() also ends the voices, so only report a genuine
        // completion.
        if (_status == PlaybackStatus.playing) {
          _status = PlaybackStatus.completed;
          _lastKnownPosition = _duration;
          if (!_completed.isClosed) _completed.add(null);
        }
      });

      _status = PlaybackStatus.paused;
      _lastError = null;
      return _duration;
    } catch (e) {
      _lastError = e;
      _status = PlaybackStatus.error;
      _loadedPath = null;
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    final source = _source;
    if (source == null) return;

    // Resume an existing voice rather than starting a second one.
    final handle = _handle;
    if (handle != null && _soloud.getIsValidVoiceHandle(handle)) {
      _soloud.setPause(handle, false);
      _status = PlaybackStatus.playing;
      return;
    }

    _handle = _soloud.play(source, volume: _effectiveVolume());
    _status = PlaybackStatus.playing;
    _soloud.setRelativePlaySpeed(_handle!, _speed);

    // A play() after completion should start from the beginning; anything else
    // resumes where it left off.
    if (_lastKnownPosition > Duration.zero &&
        _lastKnownPosition < _duration) {
      _soloud.seek(_handle!, _lastKnownPosition);
    }
  }

  @override
  void pause() {
    final handle = _handle;
    if (handle == null) return;
    _lastKnownPosition = position;
    _soloud.setPause(handle, true);
    _status = PlaybackStatus.paused;
  }

  @override
  Future<void> stop() async {
    _lastKnownPosition = Duration.zero;
    await _releaseSource();
    _status = PlaybackStatus.idle;
    _loadedPath = null;
    _duration = Duration.zero;
  }

  @override
  void seek(Duration target) {
    final clamped = target < Duration.zero
        ? Duration.zero
        : (_duration > Duration.zero && target > _duration ? _duration : target);
    _lastKnownPosition = clamped;

    final handle = _handle;
    if (handle == null || !_soloud.getIsValidVoiceHandle(handle)) return;
    _soloud.seek(handle, clamped);
    // Seeking past the end of a completed track makes it playable again.
    if (_status == PlaybackStatus.completed && clamped < _duration) {
      _status = PlaybackStatus.paused;
    }
  }

  @override
  Duration get position {
    final handle = _handle;
    if (handle == null || !_soloud.getIsValidVoiceHandle(handle)) {
      return _lastKnownPosition;
    }
    if (_status == PlaybackStatus.paused) return _lastKnownPosition;
    return _soloud.getPosition(handle);
  }

  @override
  void setVolume(double value) {
    _volume = value.clamp(0.0, 1.0);
    final handle = _handle;
    if (handle != null && _soloud.getIsValidVoiceHandle(handle)) {
      _soloud.setVolume(handle, _effectiveVolume());
    }
  }

  @override
  void fadeVolume(double value, Duration duration) {
    final handle = _handle;
    _volume = value.clamp(0.0, 1.0);
    if (handle == null || !_soloud.getIsValidVoiceHandle(handle)) return;
    _soloud.fadeVolume(handle, _effectiveVolume(), duration);
  }

  @override
  void setSpeed(double value) {
    _speed = value.clamp(0.25, 4.0);
    final handle = _handle;
    if (handle != null && _soloud.getIsValidVoiceHandle(handle)) {
      _soloud.setRelativePlaySpeed(handle, _speed);
    }
  }

  @override
  void setGainOffset(double db) {
    _gainOffsetDb = db.clamp(-24.0, 24.0);
    setVolume(_volume);
  }

  /// Combines the user's volume with any per-track gain.
  ///
  /// The slider is mapped through a square curve, because a linear volume
  /// control feels wrong: most of the perceived range crowds into the bottom
  /// third.
  double _effectiveVolume() {
    final perceptual = _volume * _volume;
    final gain = math.pow(10, _gainOffsetDb / 20).toDouble();
    return (perceptual * gain).clamp(0.0, 4.0);
  }

  // ------------------------------------------------------------------ devices

  @override
  List<AudioOutputDevice> outputDevices() {
    if (!_soloud.isInitialized) return const [];
    try {
      return [
        for (final device in _soloud.listPlaybackDevices())
          AudioOutputDevice(
            id: device.id,
            name: device.name,
            isDefault: device.isDefault,
          ),
      ];
    } catch (e) {
      _lastError = e;
      return const [];
    }
  }

  AudioOutputDevice? _currentDevice;

  @override
  AudioOutputDevice? get currentOutputDevice => _currentDevice;

  @override
  Future<void> setOutputDevice(AudioOutputDevice? device) async {
    if (!_soloud.isInitialized) return;
    try {
      if (device == null) {
        _soloud.changeDevice();
        _currentDevice = null;
        return;
      }
      final match = _soloud
          .listPlaybackDevices()
          .where((d) => d.id == device.id && d.name == device.name)
          .firstOrNull;
      if (match == null) return;
      _soloud.changeDevice(newDevice: match);
      _currentDevice = device;
      _lastError = null;
    } catch (e) {
      _lastError = e;
    }
  }

  // --------------------------------------------------------------- equalizer

  @override
  void setEqualizer(EqualizerSettings settings) {
    _equalizer = settings;
    if (!_soloud.isInitialized) return;

    try {
      final eq = _soloud.filters.parametricEqFilter;
      if (!settings.enabled || settings.isFlat) {
        if (eq.isActive) eq.deactivate();
        return;
      }

      if (!eq.isActive) eq.activate();
      eq.numBands.value = settings.bandCount.toDouble();
      for (var i = 0; i < settings.bandCount; i++) {
        eq.bandGain(i).value =
            EqualizerSettings.dbToLinear(settings.gainsDb[i]);
      }
      // Preamp rides on the voice volume rather than the filter, so it applies
      // even when every band is flat.
      setGainOffset(settings.preampDb);
      _lastError = null;
    } catch (e) {
      _lastError = e;
    }
  }

  /// Centre frequencies of the current equalizer bands.
  ///
  /// SoLoud spaces them logarithmically between 30 Hz and 16 kHz; reading them
  /// from the engine keeps the labels honest if that ever changes.
  List<double> equalizerFrequencies() {
    if (!_soloud.isInitialized) return const [];
    try {
      final eq = _soloud.filters.parametricEqFilter;
      final wasActive = eq.isActive;
      if (!wasActive) eq.activate();
      eq.numBands.value = _equalizer.bandCount.toDouble();
      final frequencies = [
        for (var i = 0; i < _equalizer.bandCount; i++) eq.bandFrequency(i),
      ];
      if (!wasActive) eq.deactivate();
      return frequencies;
    } catch (_) {
      return const [];
    }
  }

  // -------------------------------------------------------------- visualiser

  @override
  void setSpectrumEnabled(bool enabled) {
    if (_spectrumEnabled == enabled) return;
    _spectrumEnabled = enabled;
    if (!_soloud.isInitialized) return;

    _soloud.setVisualizationEnabled(enabled);
    if (enabled) {
      // A little smoothing stops the bars from strobing between frames.
      _soloud.setFftSmoothing(0.35);
      _audioData ??= sl.AudioData(sl.GetSamplesKind.linear);
    } else {
      _audioData?.dispose();
      _audioData = null;
    }
  }

  @override
  SpectrumFrame? readSpectrum() {
    final data = _audioData;
    if (!_spectrumEnabled || data == null || !_soloud.isInitialized) return null;

    try {
      data.updateSamples();
      final samples = data.getAudioData();
      if (samples.length < 512) return null;
      // The linear layout is 256 FFT bins followed by 256 waveform samples.
      return SpectrumFrame(
        magnitudes: samples.sublist(0, 256),
        waveform: samples.sublist(256, 512),
      );
    } catch (e) {
      _lastError = e;
      return null;
    }
  }

  // ----------------------------------------------------------------- private

  Future<void> _releaseSource() async {
    await _completionSubscription?.cancel();
    _completionSubscription = null;

    final handle = _handle;
    if (handle != null && _soloud.isInitialized) {
      try {
        await _soloud.stop(handle);
      } catch (_) {
        // Already gone; nothing to do.
      }
    }
    _handle = null;

    final source = _source;
    if (source != null && _soloud.isInitialized) {
      try {
        await _soloud.disposeSource(source);
      } catch (_) {
        // Already disposed.
      }
    }
    _source = null;
  }
}
