import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/repositories/queue_repository.dart';
import '../../domain/models/library_views.dart';
import 'playback_engine.dart';

/// What happens when the queue runs out.
enum QueueRepeat {
  /// Stop.
  off,

  /// Start the queue again.
  all,

  /// Repeat the current track.
  one;

  QueueRepeat get next => switch (this) {
        QueueRepeat.off => QueueRepeat.all,
        QueueRepeat.all => QueueRepeat.one,
        QueueRepeat.one => QueueRepeat.off,
      };
}

/// Everything the player UI needs, except the constantly-moving position.
///
/// Position is deliberately excluded and served by its own provider, so a
/// ticking playhead does not rebuild the whole player chrome ten times a
/// second.
class PlayerSnapshot {
  const PlayerSnapshot({
    this.status = PlaybackStatus.idle,
    this.queue = const [],
    this.currentIndex = -1,
    this.current,
    this.duration = Duration.zero,
    this.volume = 0.7,
    this.speed = 1,
    this.repeat = QueueRepeat.off,
    this.isShuffled = false,
    this.equalizer = EqualizerSettings.flat,
    this.errorMessage,
  });

  final PlaybackStatus status;
  final List<QueueEntry> queue;

  /// Index into [queue], or -1 when nothing is loaded.
  final int currentIndex;

  final PlayableTrack? current;
  final Duration duration;
  final double volume;
  final double speed;
  final QueueRepeat repeat;
  final bool isShuffled;
  final EqualizerSettings equalizer;
  final String? errorMessage;

  bool get isPlaying => status == PlaybackStatus.playing;
  bool get hasTrack => current != null;
  bool get hasQueue => queue.isNotEmpty;

  bool get canGoNext =>
      repeat != QueueRepeat.off || currentIndex < queue.length - 1;
  bool get canGoPrevious => currentIndex > 0;

  QueueEntry? get currentEntry =>
      currentIndex >= 0 && currentIndex < queue.length
          ? queue[currentIndex]
          : null;

  PlayerSnapshot copyWith({
    PlaybackStatus? status,
    List<QueueEntry>? queue,
    int? currentIndex,
    PlayableTrack? current,
    bool clearCurrent = false,
    Duration? duration,
    double? volume,
    double? speed,
    QueueRepeat? repeat,
    bool? isShuffled,
    EqualizerSettings? equalizer,
    String? errorMessage,
    bool clearError = false,
  }) =>
      PlayerSnapshot(
        status: status ?? this.status,
        queue: queue ?? this.queue,
        currentIndex: currentIndex ?? this.currentIndex,
        current: clearCurrent ? null : (current ?? this.current),
        duration: duration ?? this.duration,
        volume: volume ?? this.volume,
        speed: speed ?? this.speed,
        repeat: repeat ?? this.repeat,
        isShuffled: isShuffled ?? this.isShuffled,
        equalizer: equalizer ?? this.equalizer,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      );
}

/// Drives playback and owns the queue.
///
/// The queue lives in the database rather than in memory, so it survives a
/// restart and can be inspected and reordered like any other list. This class
/// keeps a cached copy for rendering and writes through for every change.
class PlayerController extends Notifier<PlayerSnapshot> {
  PlayerController({
    required this.engine,
    required this.queueRepository,
    required this.libraryRepository,
    required this.db,
  });

  final PlaybackEngine engine;
  final QueueRepository queueRepository;
  final LibraryRepository libraryRepository;
  final MarmeladeDatabase db;

  StreamSubscription<void>? _completionSubscription;

  /// When the current track started, for the history row.
  DateTime? _startedAt;

  /// Guards against a completion event arriving while an advance is in flight.
  var _advancing = false;

  /// Completes once the persisted queue has been read back.
  Future<void>? _restored;

  @override
  PlayerSnapshot build() {
    _completionSubscription = engine.onCompleted.listen((_) => _onCompleted());
    ref.onDispose(() {
      _completionSubscription?.cancel();
    });
    // Restore the persisted queue without starting playback. The future is
    // kept so a play pressed before the restore lands can wait for it rather
    // than quietly doing nothing.
    _restored = Future.microtask(_restoreQueue);
    return const PlayerSnapshot();
  }

  Future<void> _restoreQueue() async {
    final queue = await queueRepository.load();
    final shuffled = await queueRepository.isShuffled();
    state = state.copyWith(queue: queue, isShuffled: shuffled);
  }

  // --------------------------------------------------------------- playback

  /// Replaces the queue with [trackIds] and starts at [startIndex].
  Future<void> playAll(
    List<int> trackIds, {
    int startIndex = 0,
    QueueSource source = QueueSource.user,
    int? sourceRefId,
  }) async {
    if (trackIds.isEmpty) return;
    await queueRepository.replaceWith(
      trackIds,
      source: source,
      sourceRefId: sourceRefId,
    );
    final queue = await queueRepository.load();
    state = state.copyWith(queue: queue, isShuffled: false, clearError: true);
    await playAt(startIndex.clamp(0, queue.length - 1));
  }

  /// Plays the queue entry at [index].
  Future<void> playAt(int index) async {
    final queue = state.queue;
    if (index < 0 || index >= queue.length) return;

    final entry = queue[index];
    final playable = await libraryRepository.playable(entry.trackId);
    if (playable == null) {
      // Every file for this track is missing. Say so and move on rather than
      // failing silently or stalling the queue.
      state = state.copyWith(
        currentIndex: index,
        status: PlaybackStatus.error,
        errorMessage: 'No playable file for "${entry.title}"',
      );
      return;
    }

    await _recordFinishedPlay();

    try {
      final duration = await engine.load(playable.filePath);
      // ReplayGain is applied as a separate offset, so the user's volume
      // setting is not rewritten by per-track normalisation.
      engine.setGainOffset(playable.replayGainDb ?? 0);
      engine.setVolume(state.volume);
      engine.setSpeed(state.speed);
      await engine.play();

      _startedAt = DateTime.now().toUtc();
      state = state.copyWith(
        status: PlaybackStatus.playing,
        currentIndex: index,
        current: playable,
        duration: duration == Duration.zero ? playable.duration : duration,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(
        status: PlaybackStatus.error,
        currentIndex: index,
        errorMessage: 'Could not play "${entry.title}": $e',
      );
    }
  }

  /// Plays one track, replacing the queue.
  Future<void> playTrack(int trackId, {QueueSource? source, int? refId}) =>
      playAll([trackId], source: source ?? QueueSource.user, sourceRefId: refId);

  Future<void> togglePlayPause() async {
    if (!state.hasTrack) {
      // Pressing play in the first moments after launch would otherwise be a
      // silent no-op: the queue is still being read out of the database, so
      // there is nothing yet to start.
      if (!state.hasQueue) await _restored;
      if (state.hasQueue) await playAt(0);
      return;
    }
    if (state.isPlaying) {
      // A short fade avoids the click of cutting a waveform mid-cycle.
      engine.fadeVolume(state.volume, const Duration(milliseconds: 60));
      engine.pause();
      state = state.copyWith(status: PlaybackStatus.paused);
    } else {
      await engine.play();
      state = state.copyWith(status: PlaybackStatus.playing);
    }
  }

  Future<void> pause() async {
    if (!state.isPlaying) return;
    engine.pause();
    state = state.copyWith(status: PlaybackStatus.paused);
  }

  Future<void> resume() async {
    if (state.isPlaying || !state.hasTrack) return;
    await engine.play();
    state = state.copyWith(status: PlaybackStatus.playing);
  }

  Future<void> stop() async {
    await _recordFinishedPlay();
    await engine.stop();
    state = state.copyWith(
      status: PlaybackStatus.idle,
      clearCurrent: true,
      currentIndex: -1,
      duration: Duration.zero,
    );
  }

  Future<void> next({bool userInitiated = true}) async {
    final index = state.currentIndex;
    if (state.repeat == QueueRepeat.one && !userInitiated) {
      engine.seek(Duration.zero);
      await engine.play();
      return;
    }
    if (index + 1 < state.queue.length) {
      await playAt(index + 1);
      return;
    }
    if (state.repeat == QueueRepeat.all && state.queue.isNotEmpty) {
      await playAt(0);
      return;
    }
    // End of the queue.
    await _recordFinishedPlay();
    engine.pause();
    state = state.copyWith(status: PlaybackStatus.completed);
  }

  /// Goes back a track, or restarts the current one.
  ///
  /// Restarting first matches every other player: pressing back a few seconds
  /// in means "start this again", not "skip backwards".
  Future<void> previous({Duration restartThreshold = const Duration(seconds: 3)}) async {
    if (engine.position > restartThreshold) {
      engine.seek(Duration.zero);
      return;
    }
    if (state.currentIndex > 0) {
      await playAt(state.currentIndex - 1);
    } else {
      engine.seek(Duration.zero);
    }
  }

  void seek(Duration position) => engine.seek(position);

  /// Seeks by a relative amount, clamped to the track.
  void seekBy(Duration delta) {
    final target = engine.position + delta;
    engine.seek(target < Duration.zero ? Duration.zero : target);
  }

  void setVolume(double value) {
    final clamped = value.clamp(0.0, 1.0);
    engine.setVolume(clamped);
    state = state.copyWith(volume: clamped);
  }

  void setSpeed(double value) {
    final clamped = value.clamp(0.25, 4.0);
    engine.setSpeed(clamped);
    state = state.copyWith(speed: clamped);
  }

  void cycleRepeat() => state = state.copyWith(repeat: state.repeat.next);

  void setRepeat(QueueRepeat mode) => state = state.copyWith(repeat: mode);

  void setEqualizer(EqualizerSettings settings) {
    engine.setEqualizer(settings);
    state = state.copyWith(equalizer: settings);
  }

  // ------------------------------------------------------------------ queue

  /// Appends to the end of the queue.
  Future<void> addToQueue(
    List<int> trackIds, {
    QueueSource source = QueueSource.user,
    int? sourceRefId,
  }) async {
    await queueRepository.append(
      trackIds,
      source: source,
      sourceRefId: sourceRefId,
    );
    await _reloadQueue();
  }

  /// Inserts straight after the current track.
  Future<void> playNext(
    List<int> trackIds, {
    QueueSource source = QueueSource.user,
    int? sourceRefId,
  }) async {
    final entry = state.currentEntry;
    if (entry == null) {
      await addToQueue(trackIds, source: source, sourceRefId: sourceRefId);
      return;
    }
    await queueRepository.insertNext(
      trackIds,
      afterPosition: entry.position,
      source: source,
      sourceRefId: sourceRefId,
    );
    await _reloadQueue();
  }

  Future<void> removeFromQueue(int itemId) async {
    final removedIndex =
        state.queue.indexWhere((entry) => entry.itemId == itemId);
    await queueRepository.remove(itemId);
    await _reloadQueue(
      // Keep the playhead on the same track when something above it is removed.
      indexShift: removedIndex >= 0 && removedIndex < state.currentIndex ? -1 : 0,
    );
  }

  Future<void> clearQueue() async {
    await queueRepository.clear();
    await stop();
    state = state.copyWith(queue: const [], currentIndex: -1);
  }

  /// Shuffles the queue once, leaving the current track in place.
  Future<void> shuffleQueue() async {
    await queueRepository.shuffleOnce(keepItemId: state.currentEntry?.itemId);
    await _reloadQueue(findCurrentByItemId: true);
    state = state.copyWith(isShuffled: true);
  }

  /// Restores the order from before the last shuffle.
  Future<void> unshuffleQueue() async {
    await queueRepository.unshuffle();
    await _reloadQueue(findCurrentByItemId: true);
    state = state.copyWith(isShuffled: false);
  }

  Future<void> moveInQueue(int itemId, {int? beforeItemId}) async {
    await queueRepository.move(itemId, beforeItemId: beforeItemId);
    await _reloadQueue(findCurrentByItemId: true);
  }

  /// Reloads the cached queue, keeping the playhead pointing at the same track.
  Future<void> _reloadQueue({
    int indexShift = 0,
    bool findCurrentByItemId = false,
  }) async {
    final previousItemId = state.currentEntry?.itemId;
    final queue = await queueRepository.load();

    var index = state.currentIndex + indexShift;
    if (findCurrentByItemId && previousItemId != null) {
      final found = queue.indexWhere((e) => e.itemId == previousItemId);
      if (found >= 0) index = found;
    }
    state = state.copyWith(
      queue: queue,
      currentIndex: index.clamp(-1, queue.length - 1),
    );
  }

  // ---------------------------------------------------------------- internal

  Future<void> _onCompleted() async {
    if (_advancing) return;
    _advancing = true;
    try {
      await _recordFinishedPlay(completed: true);
      await next(userInitiated: false);
    } finally {
      _advancing = false;
    }
  }

  /// Writes a history row and bumps the track's counters.
  ///
  /// A play only counts once enough of the track was heard; anything shorter is
  /// a skip. Otherwise flicking through a library would inflate every count.
  Future<void> _recordFinishedPlay({bool completed = false}) async {
    final track = state.current;
    final startedAt = _startedAt;
    _startedAt = null;
    if (track == null || startedAt == null) return;

    final heard = engine.position;
    final total = state.duration;
    final threshold = total > Duration.zero
        ? Duration(milliseconds: (total.inMilliseconds * 0.5).round())
        : const Duration(seconds: 30);
    final counts = completed || heard >= threshold;

    await db.into(db.playHistory).insert(PlayHistoryCompanion.insert(
          trackId: track.trackId,
          startedAt: startedAt,
          endedAt: Value(DateTime.now().toUtc()),
          msPlayed: Value(heard.inMilliseconds),
          completed: Value(counts),
        ));

    await db.customStatement(
      counts
          ? 'UPDATE tracks SET play_count = play_count + 1, last_played_at = ? '
              'WHERE id = ?'
          : 'UPDATE tracks SET skip_count = skip_count + 1, last_played_at = ? '
              'WHERE id = ?',
      [DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000, track.trackId],
    );
  }
}
