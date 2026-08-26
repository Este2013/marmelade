import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/indexer/library_indexer.dart';
import '../data/indexer/search_indexer.dart';
import '../data/repositories/library_repository.dart';
import '../data/repositories/queue_repository.dart';
import '../domain/models/library_views.dart';
import '../services/art/art_store.dart';
import '../services/audio/playback_engine.dart';
import '../services/audio/player_controller.dart';
import '../services/audio/soloud_engine.dart';

/// The open database.
///
/// Overridden in `main` with an instance opened before the first frame, so no
/// screen has to render a loading state for something that is always available.
final databaseProvider = Provider<MarmeladeDatabase>(
  (ref) => throw StateError('databaseProvider must be overridden in main()'),
);

/// The artwork store.
final artStoreProvider = Provider<ArtStore>(
  (ref) => throw StateError('artStoreProvider must be overridden in main()'),
);

/// The audio engine.
///
/// Overridden in `main` with the same instance the player drives. Creating one
/// here and another for the player would open two output devices and leave the
/// visualiser reading a mixer nothing is playing to.
final playbackEngineProvider = Provider<PlaybackEngine>(
  (ref) => throw StateError('playbackEngineProvider must be overridden'),
);

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(ref.watch(databaseProvider)),
);

final queueRepositoryProvider = Provider<QueueRepository>(
  (ref) => QueueRepository(ref.watch(databaseProvider)),
);

final searchIndexerProvider = Provider<SearchIndexer>(
  (ref) => SearchIndexer(ref.watch(databaseProvider)),
);

final libraryIndexerProvider = Provider<LibraryIndexer>(
  (ref) => LibraryIndexer(
    db: ref.watch(databaseProvider),
    artStore: ref.watch(artStoreProvider),
  ),
);

/// The player, with its queue.
final playerProvider =
    NotifierProvider<PlayerController, PlayerSnapshot>(() => throw StateError(
          'playerProvider must be overridden in main()',
        ));

/// Resolves an artwork path from the store into a file.
///
/// Returns null for a missing path or a file that has gone, so widgets can
/// treat "no artwork" and "artwork we cannot read" the same way.
final artworkFileProvider = Provider.family<File?, String?>((ref, storedPath) {
  if (storedPath == null || storedPath.isEmpty) return null;
  final store = ref.watch(artStoreProvider);
  final file = store.fileFor(storedPath);
  return file.existsSync() ? file : null;
});

/// The playhead, ticking only while something is playing.
///
/// Separate from [playerProvider] on purpose: the position changes constantly,
/// and letting it live in the main player state would rebuild the whole player
/// chrome several times a second.
final playbackPositionProvider = StreamProvider<Duration>((ref) {
  final engine = ref.watch(playbackEngineProvider);
  // Watch the status so the timer starts and stops with playback rather than
  // running forever.
  final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));

  late StreamController<Duration> controller;
  Timer? timer;

  void emit() {
    if (!controller.isClosed) controller.add(engine.position);
  }

  controller = StreamController<Duration>(
    onListen: () {
      emit();
      if (isPlaying) {
        // ~12 fps is smooth enough for a seek bar and cheap enough to ignore.
        timer = Timer.periodic(const Duration(milliseconds: 80), (_) => emit());
      }
    },
    onCancel: () {
      timer?.cancel();
      timer = null;
    },
  );
  ref.onDispose(() {
    timer?.cancel();
    controller.close();
  });
  return controller.stream;
});

/// Live visualisation frames, at animation rate.
///
/// Only ticks while a visualiser is mounted, because the FFT tap costs a
/// transform per frame.
final spectrumProvider = StreamProvider<SpectrumFrame>((ref) {
  final engine = ref.watch(playbackEngineProvider);
  engine.setSpectrumEnabled(true);
  ref.onDispose(() => engine.setSpectrumEnabled(false));

  late StreamController<SpectrumFrame> controller;
  Timer? timer;

  controller = StreamController<SpectrumFrame>(
    onListen: () {
      timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
        final frame = engine.readSpectrum();
        if (frame != null && !controller.isClosed) controller.add(frame);
      });
    },
    onCancel: () {
      timer?.cancel();
      timer = null;
    },
  );
  ref.onDispose(() {
    timer?.cancel();
    controller.close();
  });
  return controller.stream;
});

// ------------------------------------------------------------------ library

/// A single mutable view setting.
///
/// Riverpod 3 moved `StateProvider` to its legacy export; this is the same idea
/// without depending on something on the way out.
class ViewSetting<T> extends Notifier<T> {
  ViewSetting(this.initial);

  final T initial;

  @override
  T build() => initial;

  void set(T value) => state = value;
  void toggle() {
    if (state is bool) state = !(state as bool) as T;
  }
}

/// How the albums grid is sorted.
final albumSortProvider =
    NotifierProvider<ViewSetting<LibrarySort>, LibrarySort>(
  () => ViewSetting(LibrarySort.nameAscending),
);

/// Whether the albums grid also shows tracks that belong to no album.
final showSinglesProvider =
    NotifierProvider<ViewSetting<bool>, bool>(() => ViewSetting(false));

final albumsProvider = StreamProvider<List<AlbumCard>>((ref) {
  return ref.watch(libraryRepositoryProvider).watchAlbums(
        sort: ref.watch(albumSortProvider),
        includeSingles: ref.watch(showSinglesProvider),
      );
});

final albumTracksProvider =
    StreamProvider.family<List<TrackRow>, int>((ref, albumId) {
  return ref.watch(libraryRepositoryProvider).watchTracks(albumId: albumId);
});

final albumDetailProvider =
    FutureProvider.family<AlbumCard?, int>((ref, albumId) {
  return ref.watch(libraryRepositoryProvider).album(albumId);
});

/// How the song list is sorted.
final trackSortProvider =
    NotifierProvider<ViewSetting<LibrarySort>, LibrarySort>(
  () => ViewSetting(LibrarySort.nameAscending),
);

final allTracksProvider = StreamProvider<List<TrackRow>>((ref) {
  return ref
      .watch(libraryRepositoryProvider)
      .watchTracks(sort: ref.watch(trackSortProvider));
});

final artistSortProvider =
    NotifierProvider<ViewSetting<LibrarySort>, LibrarySort>(
  () => ViewSetting(LibrarySort.nameAscending),
);

final artistsProvider = StreamProvider<List<ArtistCard>>((ref) {
  return ref
      .watch(libraryRepositoryProvider)
      .watchArtists(sort: ref.watch(artistSortProvider));
});

final artistTracksProvider =
    StreamProvider.family<List<TrackRow>, int>((ref, artistId) {
  return ref.watch(libraryRepositoryProvider).watchTracks(artistId: artistId);
});

final artistAlbumsProvider =
    StreamProvider.family<List<AlbumCard>, int>((ref, artistId) {
  return ref.watch(libraryRepositoryProvider).watchArtistAlbums(artistId);
});

final tagsProvider = StreamProvider<List<TagCard>>((ref) {
  return ref.watch(libraryRepositoryProvider).watchTags();
});

final tagTracksProvider =
    StreamProvider.family<List<TrackRow>, int>((ref, tagId) {
  return ref.watch(libraryRepositoryProvider).watchTracks(tagId: tagId);
});

/// Headline library counts, refreshed when the catalog changes.
final libraryCountsProvider = FutureProvider<LibraryCounts>((ref) async {
  // Depend on the tracks stream so the counts refresh after an index run.
  ref.watch(allTracksProvider);
  return ref.watch(libraryRepositoryProvider).counts();
});

/// Watched folders, for settings.
final libraryFoldersProvider = StreamProvider<List<LibraryFolder>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.libraryFolders)
        ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
      .watch();
});

// ------------------------------------------------------------------ indexing

/// Progress of the running index job, or null when idle.
final indexProgressProvider =
    NotifierProvider<IndexJobController, IndexProgress?>(
  IndexJobController.new,
);

/// Runs library scans and reports progress.
///
/// Kept as a notifier rather than a fire-and-forget call so the UI can show a
/// progress bar, and so a second scan cannot be started on top of a running
/// one.
class IndexJobController extends Notifier<IndexProgress?> {
  @override
  IndexProgress? build() => null;

  var _running = false;
  bool get isRunning => _running;

  /// The outcomes of the last completed run.
  List<IndexOutcome> lastOutcomes = const [];

  /// Scans every enabled folder.
  Future<List<IndexOutcome>> refreshAll({
    ScanTrigger trigger = ScanTrigger.manual,
  }) async {
    if (_running) return const [];
    _running = true;
    state = const IndexProgress(phase: IndexPhase.scanning);
    try {
      final outcomes = await ref.read(libraryIndexerProvider).indexAll(
            trigger: trigger,
            onProgress: (progress) => state = progress,
          );
      lastOutcomes = outcomes;
      return outcomes;
    } finally {
      _running = false;
      state = null;
      // Nudge the count query, which is not stream-backed.
      ref.invalidate(libraryCountsProvider);
    }
  }

  /// Registers a folder and scans it.
  Future<IndexOutcome?> addFolder(String path) async {
    if (_running) return null;
    final indexer = ref.read(libraryIndexerProvider);
    final folderId = await indexer.addFolder(path);
    _running = true;
    state = const IndexProgress(phase: IndexPhase.scanning);
    try {
      return await indexer.indexFolder(
        folderId,
        trigger: ScanTrigger.folderAdded,
        onProgress: (progress) => state = progress,
      );
    } finally {
      _running = false;
      state = null;
      ref.invalidate(libraryCountsProvider);
    }
  }
}

/// The long-lived services the app is built on.
///
/// Constructed before the first frame so no screen has to render a loading
/// state for something that is always available, and so the audio engine is a
/// single shared instance.
class AppServices {
  AppServices({
    required this.db,
    required this.artStore,
    required this.engine,
  });

  final MarmeladeDatabase db;
  final ArtStore artStore;
  final SoLoudEngine engine;

  static Future<AppServices> start({
    required String databasePath,
    required Directory artworkDirectory,
  }) async {
    final db = await MarmeladeDatabase.open(databasePath);
    debugPrint('marmelade: database open');
    final artStore = await ArtStore.open(artworkDirectory);
    debugPrint('marmelade: artwork store open');

    final engine = SoLoudEngine();
    // Failing to open an audio device must not stop the library from loading;
    // the player surfaces the error instead. A device that hangs must not
    // either, hence the timeout.
    try {
      await engine.initialize().timeout(const Duration(seconds: 5));
      debugPrint('marmelade: audio engine ready');
    } catch (e) {
      debugPrint('marmelade: audio engine unavailable: $e');
    }
    return AppServices(db: db, artStore: artStore, engine: engine);
  }

  Future<void> dispose() async {
    await engine.shutdown();
    await db.close();
  }

  /// Builds the player the app runs on.
  PlayerController createPlayer() => PlayerController(
        engine: engine,
        queueRepository: QueueRepository(db),
        libraryRepository: LibraryRepository(db),
        db: db,
      );
}
