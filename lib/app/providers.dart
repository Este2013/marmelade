import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../core/logging/app_log.dart';
import '../data/db/database.dart';
import '../data/indexer/library_indexer.dart';
import '../data/indexer/search_indexer.dart';
import '../data/repositories/edit_repository.dart';
import '../data/repositories/library_repository.dart';
import '../data/repositories/lyrics_repository.dart';
import '../data/repositories/queue_repository.dart';
import '../data/repositories/playlist_repository.dart';
import '../data/repositories/review_repository.dart';
import '../data/repositories/search_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/smart_playlist_resolver.dart';
import '../data/repositories/tag_repository.dart';
import '../data/transfer/library_exporter.dart';
import '../data/transfer/library_importer.dart';
import '../data/transfer/library_sync.dart';
import '../data/transfer/transfer_bundle.dart';
import '../data/transfer/transfer_report.dart';
import '../domain/models/library_views.dart';
import 'theme/app_theme.dart' show marmeladeSeed;
import 'theme/theme_settings.dart';
import '../services/art/art_store.dart';
import '../services/art/link_artwork_service.dart';
import '../core/changelog/changelog.dart';
import '../services/updates/changelog_service.dart';
import '../services/updates/update_service.dart';
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

final editRepositoryProvider = Provider<EditRepository>(
  (ref) => EditRepository(
    db: ref.watch(databaseProvider),
    searchIndexer: ref.watch(searchIndexerProvider),
    artStore: ref.watch(artStoreProvider),
  ),
);

/// One artist with everything the editor shows, refreshed as it is edited.
final artistEditProvider =
    StreamProvider.family<ArtistEdit?, int>((ref, artistId) {
  return ref.watch(editRepositoryProvider).watchArtist(artistId);
});

final albumEditProvider =
    StreamProvider.family<AlbumEdit?, int>((ref, albumId) {
  return ref.watch(editRepositoryProvider).watchAlbum(albumId);
});

final trackEditProvider =
    StreamProvider.family<TrackEdit?, int>((ref, trackId) {
  return ref.watch(editRepositoryProvider).watchTrack(trackId);
});

/// Resolves smart playlists.
///
/// The type is written out rather than inferred, and so are its two neighbours:
/// search hydrates playlist results, playlists resolve through search, and Dart
/// cannot infer a type through that ring even though the runtime dependency is
/// broken by the lazy read below.
final Provider<SmartPlaylistResolver> smartPlaylistResolverProvider = Provider(
  (ref) => SmartPlaylistResolver(
    db: ref.watch(databaseProvider),
    // Read when a query runs, not when this is built: search hydrates playlist
    // results, so watching it here would close a construction cycle.
    searchTracks: (query, {int limit = 20000}) =>
        ref.read(searchRepositoryProvider).trackIdsMatching(query, limit: limit),
  ),
);

final Provider<PlaylistRepository> playlistRepositoryProvider = Provider(
  (ref) => PlaylistRepository(
    db: ref.watch(databaseProvider),
    searchIndexer: ref.watch(searchIndexerProvider),
    smart: ref.watch(smartPlaylistResolverProvider),
  ),
);

/// Every playlist, flattened into tree order.
final playlistsProvider = StreamProvider<List<PlaylistCard>>((ref) {
  return _unlessIndexing(
    ref,
    () => ref.watch(playlistRepositoryProvider).watchPlaylists(),
  );
});

final playlistProvider =
    StreamProvider.family<PlaylistCard?, int>((ref, playlistId) {
  return ref.watch(playlistRepositoryProvider).watchPlaylist(playlistId);
});

/// One playlist's own rows: its tracks and the playlists it includes.
final playlistEntriesProvider =
    StreamProvider.family<List<PlaylistEntry>, int>((ref, playlistId) {
  return ref.watch(playlistRepositoryProvider).watchEntries(playlistId);
});

/// A playlist's tracks: its rows, its nested playlists, or its query.
final playlistTracksProvider =
    StreamProvider.family<List<TrackRow>, int>((ref, playlistId) {
  final repository = ref.watch(playlistRepositoryProvider);
  final library = ref.watch(libraryRepositoryProvider);
  // Watched, not read: a smart playlist has no rows of its own, so entries
  // alone would never fire for it. Editing its query changes the playlist row,
  // which is what this picks up. (A scan that adds matching tracks refreshes
  // through the indexing guard, not through here.)
  ref.watch(playlistProvider(playlistId));
  return repository.watchEntries(playlistId).asyncMap((_) async {
    final ids = await repository.resolveContents(playlistId);
    // Membership first, then the order the playlist asks for. Two steps because
    // ordering needs track data -- titles, years, ratings -- that the playlist
    // tables do not have.
    final ordered = await repository.applyOrder(
      playlistId,
      ids,
      sortBy: repository.sortTrackIds,
    );
    return library.tracksByIds(ordered);
  });
});

/// The tracks a queried playlist explicitly keeps out.
final playlistExclusionsProvider =
    StreamProvider.family<List<TrackRow>, int>((ref, playlistId) {
  final repository = ref.watch(playlistRepositoryProvider);
  final library = ref.watch(libraryRepositoryProvider);
  return repository
      .watchExclusions(playlistId)
      .asyncMap(library.tracksByIds);
});

/// How much the search index holds, for the maintenance tile.
final searchIndexCountsProvider =
    FutureProvider<({int tokens, int trigrams})>((ref) {
  return ref.watch(searchIndexerProvider).counts();
});

final Provider<SearchRepository> searchRepositoryProvider = Provider(
  (ref) => SearchRepository(
    db: ref.watch(databaseProvider),
    library: ref.watch(libraryRepositoryProvider),
    tags: ref.watch(tagRepositoryProvider),
    playlists: ref.watch(playlistRepositoryProvider),
    // Read when a query runs, not when this is built: the resolver's own word
    // half runs through this repository, so watching it here would close the
    // same construction cycle [smartPlaylistResolverProvider] avoids above.
    resolveAdvanced: (query, {int limit = 20000}) =>
        ref.read(smartPlaylistResolverProvider).resolve(query, limit: limit),
  ),
);

/// What is currently typed in the search field.
///
/// Held here rather than in the view so the field survives navigating away and
/// back, and so a shortcut from anywhere can put a query in it.
final searchQueryProvider =
    NotifierProvider<ViewSetting<String>, String>(() => ViewSetting(''));

/// The results for what is typed, one search per pause in typing.
///
/// Debounced here rather than in the field: every widget that can change the
/// query would otherwise need its own timer, and they would disagree.
final searchResultsProvider = FutureProvider<SearchResults>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (searchTerms(query).isEmpty) return SearchResults.empty(query);

  // A keystroke disposes this build. Waiting first, then checking, collapses a
  // burst of typing into the one search that matters.
  var superseded = false;
  ref.onDispose(() => superseded = true);
  await Future<void>.delayed(const Duration(milliseconds: 160));
  if (superseded) return SearchResults.empty(query);

  return ref.watch(searchRepositoryProvider).search(query);
});

final reviewRepositoryProvider = Provider<ReviewRepository>(
  (ref) => ReviewRepository(
    db: ref.watch(databaseProvider),
    searchIndexer: ref.watch(searchIndexerProvider),
  ),
);

/// Credits the resolver would not decide on, grouped by the string itself.
final pendingCreditsProvider =
    StreamProvider<List<PendingCreditGroup>>((ref) {
  return _unlessIndexing(
    ref,
    () => ref.watch(reviewRepositoryProvider).watchPending(),
  );
});

/// How many credits are waiting, for the rail badge.
///
/// Deliberately not derived from [pendingCreditsProvider]: the badge is always
/// mounted, and a count is one cheap row where the full list is a join over
/// every parked credit.
final pendingCreditCountProvider = StreamProvider<int>((ref) {
  return _unlessIndexing(
    ref,
    () => ref.watch(reviewRepositoryProvider).watchPendingCount(),
  );
});

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

/// Reads the picture a linked page shows for itself.
///
/// Kept as a provider so a test can hand the picker a fake instead of
/// reaching the network, and so the one HTTP client is shared.
final linkArtworkServiceProvider = Provider<LinkArtworkService>((ref) {
  final service = LinkArtworkService();
  ref.onDispose(service.dispose);
  return service;
});

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

/// Whether a library scan is running.
///
/// The list providers below stop listening to the database while it is true.
/// Live query streams are exactly the wrong tool during a bulk import: every
/// commit re-runs them, and a re-run means re-querying thousands of rows,
/// rebuilding the grids and decoding another wave of album art. Measured on a
/// 5,216-file library that cost three seconds and about four megabytes per
/// directory of artwork imported, climbing until the process died.
///
/// While a scan runs the UI keeps showing the data it already had, which is
/// both cheaper and less distracting than watching counts tick up. The lists
/// are refreshed once, at the end.
final isIndexingProvider = Provider<bool>(
  (ref) => ref.watch(indexProgressProvider) != null,
);

/// Wraps a library query stream so it is not subscribed during a scan.
///
/// Riverpod keeps the previous value visible while a provider is rebuilding,
/// so the UI shows stale-but-complete data rather than emptying out.
Stream<T> _unlessIndexing<T>(Ref ref, Stream<T> Function() build) =>
    ref.watch(isIndexingProvider) ? const Stream.empty() : build();


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

/// A setting that lives in the database, read once on build.
///
/// The same shape as [UpdateChannelSetting], generalised because the transfer
/// feature needs several: optimistic local state first so a toggle does not
/// wait on a write, and the stored value loaded in a microtask rather than
/// making every reader handle a loading state for something that is
/// effectively always available.
class StoredFlag extends Notifier<bool> {
  StoredFlag(this.key, {this.initial = false});

  final String key;
  final bool initial;

  @override
  bool build() {
    Future.microtask(() async {
      state = await ref.read(settingsRepositoryProvider).get(key, initial);
    });
    return initial;
  }

  Future<void> set(bool value) async {
    state = value;
    await ref.read(settingsRepositoryProvider).set(key, value);
  }
}

/// A stored string setting; empty means unset.
class StoredString extends Notifier<String> {
  StoredString(this.key, {this.initial = ''});

  final String key;
  final String initial;

  @override
  String build() {
    Future.microtask(() async {
      state = await ref.read(settingsRepositoryProvider).get(key, initial);
    });
    return initial;
  }

  Future<void> set(String value) async {
    state = value;
    await ref.read(settingsRepositoryProvider).set(key, value);
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
  final sort = ref.watch(albumSortProvider);
  final includeSingles = ref.watch(showSinglesProvider);
  return _unlessIndexing(
    ref,
    () => ref.watch(libraryRepositoryProvider).watchAlbums(
          sort: sort,
          includeSingles: includeSingles,
        ),
  );
});

/// Whether the queue panel is showing inside the now-playing shade.
///
/// Lives outside the view so the player bar's queue button can open the shade
/// with the panel already up, and so the choice survives closing and reopening.
/// The application's settings, as a typed key/value store.
final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

/// What the appearance settings currently say.
///
/// Stored, so the app opens looking the way it was left rather than flashing
/// the default theme on every launch before the real one arrives. The
/// [ThemePreference] value is read once and then kept in memory: the theme is
/// consulted on every build of every screen, and a stream read per build would
/// be a query per frame.
class ThemeSettings extends Notifier<ThemePreference> {
  @override
  ThemePreference build() {
    // The stored values arrive one frame later. Starting from the default and
    // replacing it is what the loading state looks like for something that
    // cannot show a spinner.
    Future.microtask(_load);
    return const ThemePreference();
  }

  SettingsRepository get _settings => ref.read(settingsRepositoryProvider);

  Future<void> _load() async {
    final mode = await _settings.get(SettingKeys.themeMode, ThemeMode.dark.name);
    final accent =
        await _settings.get(SettingKeys.accentSource, AccentSource.system.name);
    final custom = await _settings.get(
      SettingKeys.customAccent,
      marmeladeSeed.toARGB32(),
    );
    state = ThemePreference(
      mode: ThemeMode.values.where((m) => m.name == mode).firstOrNull ??
          ThemeMode.dark,
      accent: AccentSource.of(accent),
      customAccent: Color(custom),
    );
  }

  Future<void> setMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
    await _settings.set(SettingKeys.themeMode, mode.name);
  }

  Future<void> setAccent(AccentSource accent) async {
    state = state.copyWith(accent: accent);
    await _settings.set(SettingKeys.accentSource, accent.name);
  }

  /// Picking a colour also selects it, since picking one and having nothing
  /// happen because the source is still "Windows accent" is a puzzle.
  Future<void> setCustomAccent(Color color) async {
    state = state.copyWith(accent: AccentSource.custom, customAccent: color);
    await _settings.set(SettingKeys.customAccent, color.toARGB32());
    await _settings.set(SettingKeys.accentSource, AccentSource.custom.name);
  }
}

final themeSettingsProvider =
    NotifierProvider<ThemeSettings, ThemePreference>(ThemeSettings.new);

/// The version this build reports, as package_info sees it.
///
/// Overridden in tests; read once because it cannot change while running.
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
});

/// Checks GitHub for a newer release.
final updateServiceProvider = FutureProvider<UpdateService>((ref) async {
  final version = await ref.watch(appVersionProvider.future);
  final service = UpdateService(
    repository: 'Este2013/marmelade',
    currentVersion: version,
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Where the published changelog lives.
const changelogUrl = 'https://este2013.github.io/marmelade/changelog.json';

final changelogServiceProvider = Provider<ChangelogService>((ref) {
  final service = ChangelogService(url: changelogUrl);
  ref.onDispose(service.dispose);
  return service;
});

/// The published changelog, fetched once per launch.
///
/// The result is cached in the settings table, so a launch with no network
/// still knows about versions the last successful fetch saw. A failed fetch
/// leaves the cache alone rather than emptying it.
final publishedChangelogProvider =
    FutureProvider<List<ReleaseNotes>>((ref) async {
  final settings = ref.watch(settingsRepositoryProvider);
  final fetched = await ref.watch(changelogServiceProvider).fetch();

  if (fetched != null) {
    await settings.set(
      SettingKeys.changelogCache,
      jsonEncode({'schema': 1, 'versions': [for (final r in fetched) r.toJson()]}),
    );
    return fetched;
  }

  final cached = await settings.get(SettingKeys.changelogCache, '');
  if (cached.isEmpty) return const [];
  return ChangelogService.parse(cached) ?? const [];
});

/// Every version's notes: the built-in changelog, with the published one
/// layered over it.
final changelogProvider = FutureProvider<List<ReleaseNotes>>((ref) async {
  final published = await ref.watch(publishedChangelogProvider.future);
  return ChangelogService.merge(published);
});

/// The versions newer than the one running, which is what an update brings.
final upcomingChangesProvider =
    FutureProvider<List<ReleaseNotes>>((ref) async {
  final all = await ref.watch(changelogProvider.future);
  final current = await ref.watch(appVersionProvider.future);
  return ChangelogService.newerThan(current, all);
});

/// The notes for the version that is running, if there are any.
final currentChangesProvider = FutureProvider<ReleaseNotes?>((ref) async {
  final all = await ref.watch(changelogProvider.future);
  final current = await ref.watch(appVersionProvider.future);
  return all.where((r) => r.version == current).firstOrNull;
});

/// Whether this launch is the first on a newly installed version.
///
/// Answered from the built-in changelog and a stored marker, so it needs no
/// network: the build knows its own version and what it changed.
final justUpdatedProvider = FutureProvider<ReleaseNotes?>((ref) async {
  final settings = ref.watch(settingsRepositoryProvider);
  final current = await ref.watch(appVersionProvider.future);
  final seen = await settings.get(SettingKeys.lastSeenVersion, '');
  if (seen == current) return null;

  // Mark it seen straight away. A dialog that reappears because something
  // failed downstream is worse than one that is missed once.
  await settings.set(SettingKeys.lastSeenVersion, current);

  // Nothing to show on a first install: there is no previous version whose
  // changes would be news.
  if (seen.isEmpty) return null;
  return changelog.where((r) => r.version == current).firstOrNull;
});

/// Whether the update check should include pre-releases.
final updateChannelProvider =
    NotifierProvider<UpdateChannelSetting, bool>(UpdateChannelSetting.new);

/// The beta channel, stored like the appearance settings are.
class UpdateChannelSetting extends Notifier<bool> {
  @override
  bool build() {
    Future.microtask(() async {
      state = await ref
          .read(settingsRepositoryProvider)
          .get(SettingKeys.updateChannel, false);
    });
    return false;
  }

  Future<void> set(bool includePreReleases) async {
    state = includePreReleases;
    await ref
        .read(settingsRepositoryProvider)
        .set(SettingKeys.updateChannel, includePreReleases);
  }
}

/// Reads and writes lyrics.
final lyricsRepositoryProvider = Provider<LyricsRepository>(
  (ref) => LyricsRepository(ref.watch(databaseProvider)),
);

/// Every lyrics document a track has, parsed.
final trackLyricsProvider =
    StreamProvider.family<TrackLyrics, int>((ref, trackId) {
  return ref.watch(lyricsRepositoryProvider).watch(trackId);
});

/// Which paragraph of the current track's lyrics is being sung.
///
/// Derived rather than computed in the view: the position stream ticks twelve
/// times a second and the answer changes once a verse, and a Provider only
/// notifies when its value actually changes. The pane therefore rebuilds when
/// the words move, not on every tick -- which also keeps the accessibility
/// bridge out of the flood that a per-frame rebuild would cause.
final activeLyricsBlockProvider =
    Provider.family<int?, ({int trackId, String? language})>((ref, key) {
  final position = ref.watch(playbackPositionProvider).value ?? Duration.zero;
  final entry =
      ref.watch(trackLyricsProvider(key.trackId)).value?.forLanguage(key.language);
  if (entry == null) return null;
  return entry.document.activeBlock(position, extraOffset: entry.offset);
});

/// Whether the shade's side pane is showing lyrics.
///
/// Lyrics and the queue share that pane: three columns in the app's minimum
/// window leaves none of them readable, and a toggle that means different
/// things at different widths is worse than one that always means the same.
final lyricsPaneVisibleProvider =
    NotifierProvider<ViewSetting<bool>, bool>(() => ViewSetting(false));

/// Which language the lyrics pane is showing, null being the original.
final lyricsLanguageProvider =
    NotifierProvider<ViewSetting<String?>, String?>(() => ViewSetting(null));

/// Whether to show the original beside the translation.
final lyricsBilingualProvider =
    NotifierProvider<ViewSetting<bool>, bool>(() => ViewSetting(true));

/// What is typed in each list's filter box.
///
/// One per list rather than one shared: filtering albums and then switching to
/// Songs should not hide most of the songs for reasons that are off screen.
/// They survive navigating away and back, which is what makes the box useful
/// for "keep this narrowed while I work through it".
final albumFilterProvider =
    NotifierProvider<ViewSetting<String>, String>(() => ViewSetting(''));
final songFilterProvider =
    NotifierProvider<ViewSetting<String>, String>(() => ViewSetting(''));
final artistFilterProvider =
    NotifierProvider<ViewSetting<String>, String>(() => ViewSetting(''));

final queuePaneVisibleProvider =
    NotifierProvider<ViewSetting<bool>, bool>(() => ViewSetting(true));

/// How an album's own track list is sorted.
///
/// Separate from [albumSortProvider], which orders the grid of albums.
final albumTrackSortProvider =
    NotifierProvider<ViewSetting<LibrarySort>, LibrarySort>(
  () => ViewSetting(LibrarySort.trackNumber),
);

final albumTracksProvider =
    StreamProvider.family<List<TrackRow>, int>((ref, albumId) {
  final sort = ref.watch(albumTrackSortProvider);
  return ref
      .watch(libraryRepositoryProvider)
      .watchTracks(albumId: albumId, sort: sort);
});

/// One track with its credits as individual, tappable artists.
///
/// The player's own snapshot carries a pre-joined artist line, which is right
/// for the compact bar and wrong for the now-playing view: a name on screen
/// there has to be one click from its page.
final trackRowProvider = StreamProvider.family<TrackRow?, int>((ref, trackId) {
  return ref
      .watch(libraryRepositoryProvider)
      .watchTracks(trackId: trackId)
      .map((rows) => rows.isEmpty ? null : rows.first);
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
  final sort = ref.watch(trackSortProvider);
  return _unlessIndexing(
    ref,
    () => ref.watch(libraryRepositoryProvider).watchTracks(sort: sort),
  );
});

final artistSortProvider =
    NotifierProvider<ViewSetting<LibrarySort>, LibrarySort>(
  () => ViewSetting(LibrarySort.nameAscending),
);

final artistsProvider = StreamProvider<List<ArtistCard>>((ref) {
  final sort = ref.watch(artistSortProvider);
  return _unlessIndexing(
    ref,
    () => ref.watch(libraryRepositoryProvider).watchArtists(sort: sort),
  );
});

/// How an artist's own track list is sorted.
final artistTrackSortProvider =
    NotifierProvider<ViewSetting<LibrarySort>, LibrarySort>(
  () => ViewSetting(LibrarySort.albumThenTrack),
);

final artistTracksProvider =
    StreamProvider.family<List<TrackRow>, int>((ref, artistId) {
  final sort = ref.watch(artistTrackSortProvider);
  return ref
      .watch(libraryRepositoryProvider)
      .watchTracks(artistId: artistId, sort: sort);
});

final artistAlbumsProvider =
    StreamProvider.family<List<AlbumCard>, int>((ref, artistId) {
  return ref.watch(libraryRepositoryProvider).watchArtistAlbums(artistId);
});

/// An artist's external links, for the page itself rather than the editor.
final artistLinksProvider =
    StreamProvider.family<List<LinkRow>, int>((ref, artistId) {
  return ref.watch(editRepositoryProvider).watchArtistLinks(artistId);
});

final tagRepositoryProvider = Provider<TagRepository>(
  (ref) => TagRepository(
    db: ref.watch(databaseProvider),
    searchIndexer: ref.watch(searchIndexerProvider),
  ),
);

/// The tags attached to one thing, cascade included for a track.
final attachedTagsProvider = StreamProvider.family<List<AttachedTag>,
    ({TagTarget target, int id})>((ref, key) {
  return ref.watch(tagRepositoryProvider).watchTagsOf(key.target, key.id);
});

/// Every tag, with the number of tracks that carry it once the cascade from
/// albums and playlists is taken into account.
final taggedProvider = StreamProvider<List<TagCard>>((ref) {
  return _unlessIndexing(
    ref,
    () => ref.watch(tagRepositoryProvider).watchTags(),
  );
});

final tagCategoriesProvider = StreamProvider<List<TagCategoryRow>>((ref) {
  return _unlessIndexing(
    ref,
    () => ref.watch(tagRepositoryProvider).watchCategories(),
  );
});

/// The tracks carrying a tag, cascade included.
final tagTrackListProvider =
    StreamProvider.family<List<TrackRow>, int>((ref, tagId) {
  final repository = ref.watch(tagRepositoryProvider);
  final library = ref.watch(libraryRepositoryProvider);
  // Watched rather than fetched once: tagging an album, or adding a track to a
  // tagged playlist, moves tracks into this set without touching them.
  return repository
      .watchTrackIdsWithTag(tagId)
      .asyncMap(library.tracksByIds);
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

// ------------------------------------------------------------------ transfer

final libraryExporterProvider = Provider<LibraryExporter>(
  (ref) => LibraryExporter(
    db: ref.watch(databaseProvider),
    artStore: ref.watch(artStoreProvider),
  ),
);

final libraryImporterProvider = Provider<LibraryImporter>(
  (ref) => LibraryImporter(
    db: ref.watch(databaseProvider),
    artStore: ref.watch(artStoreProvider),
    searchIndexer: ref.watch(searchIndexerProvider),
  ),
);

final librarySyncProvider = Provider<LibrarySync>(
  (ref) => LibrarySync(
    exporter: ref.watch(libraryExporterProvider),
    importer: ref.watch(libraryImporterProvider),
    settings: ref.watch(settingsRepositoryProvider),
  ),
);

/// This installation's identity in a shared folder, created on first read.
final machineIdentityProvider = FutureProvider<TransferOrigin>((ref) async {
  final version = await ref.watch(appVersionProvider.future);
  return ref.watch(librarySyncProvider).identity(appVersion: version);
});

/// The folder this library is shared through, or empty for none.
final syncFolderProvider =
    NotifierProvider<StoredString, String>(() => StoredString(SettingKeys.syncFolder));

/// Whether artwork travels with a bundle. On: it is a few megabytes, and a
/// picture chosen by hand is exactly the sort of work worth carrying.
final syncArtworkProvider = NotifierProvider<StoredFlag, bool>(
  () => StoredFlag(SettingKeys.syncIncludeArtwork, initial: true),
);

/// Whether the audio files travel too. Off: that turns a bundle of megabytes
/// into one the size of the music, and a shared folder is often metered.
final syncAudioProvider = NotifierProvider<StoredFlag, bool>(
  () => StoredFlag(SettingKeys.syncIncludeAudio, initial: false),
);

/// When this computer last shared, for the settings page.
///
/// Read back from storage rather than held in a notifier because
/// [LibrarySync] writes it itself, deep inside a job -- and the one thing
/// worse than no timestamp is one that says the share worked when it did
/// not.
final lastSharedAtProvider = FutureProvider<String>((ref) async {
  ref.watch(transferProgressProvider);
  return ref.watch(settingsRepositoryProvider).get(SettingKeys.lastSyncAt, '');
});

/// The other computers sharing this library's folder.
final syncPeersProvider = FutureProvider<List<SyncPeer>>((ref) async {
  final path = ref.watch(syncFolderProvider);
  if (path.isEmpty) return const [];
  // Re-read after every transfer, so the list is not stale the moment it
  // matters most.
  ref.watch(transferProgressProvider);
  final origin = await ref.watch(machineIdentityProvider.future);
  return ref.watch(librarySyncProvider).peers(Directory(path), origin: origin);
});

/// Progress of a running export, import or share, or null when idle.
final transferProgressProvider =
    NotifierProvider<TransferJobController, TransferProgress?>(
  TransferJobController.new,
);

/// Runs the transfer jobs, one at a time.
///
/// Shaped like [IndexJobController]: null state means idle, a bool guards
/// re-entry, and progress arrives through the same callback the data layer
/// already reports on. Two of these running at once would have both writing
/// the same rows.
class TransferJobController extends Notifier<TransferProgress?> {
  @override
  TransferProgress? build() => null;

  var _running = false;
  bool get isRunning => _running;

  /// Writes a bundle into [path].
  Future<TransferExportReport?> exportTo(String path) => _guard(() async {
        final origin = await ref.read(machineIdentityProvider.future);
        return ref.read(libraryExporterProvider).exportTo(
              Directory(path),
              origin: origin,
              options: _exportOptions,
              onProgress: (progress) => state = progress,
            );
      });

  /// Reads the bundle in [path]. With [preview] nothing is written.
  Future<TransferReport?> importFrom(
    String path, {
    required TransferImportOptions options,
    bool preview = false,
  }) =>
      _guard(() async {
        final directory = Directory(path);
        final file = File(p.join(directory.path, transferBundleFileName));
        state = const TransferProgress(phase: TransferPhase.readingBundle);
        final bundle = TransferBundle.decode(await file.readAsString());
        return ref.read(libraryImporterProvider).import(
              bundle,
              bundleDirectory: directory,
              options: options,
              preview: preview,
              onProgress: (progress) => state = progress,
            );
      });

  /// Publishes to the shared folder and folds in every other machine.
  Future<SyncOutcome?> shareNow({
    TransferImportOptions options = const TransferImportOptions(),
  }) =>
      _guard(() async {
        final path = ref.read(syncFolderProvider);
        if (path.isEmpty) return null;
        final origin = await ref.read(machineIdentityProvider.future);
        return ref.read(librarySyncProvider).syncNow(
              folder: Directory(path),
              origin: origin,
              export: _exportOptions,
              import: options,
              onProgress: (progress) => state = progress,
            );
      });

  TransferExportOptions get _exportOptions => TransferExportOptions(
        includeArtwork: ref.read(syncArtworkProvider),
        includeAudio: ref.read(syncAudioProvider),
      );

  Future<T?> _guard<T>(Future<T?> Function() body) async {
    if (_running) return null;
    _running = true;
    state = const TransferProgress(phase: TransferPhase.readingLibrary);
    try {
      return await body();
    } finally {
      _running = false;
      state = null;
    }
  }
}

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
      // Clearing the progress state flips isIndexingProvider, which is what
      // makes the gated list providers resubscribe and pick up the new data.
      // Invalidating them by hand here would be a circular dependency: they
      // watch this notifier.
      state = null;
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
    }
  }
}

/// The long-lived services the app is built on.
///
/// Constructed before the first frame so no screen has to render a loading
/// state for something that is always available, and so the audio engine is a
/// single shared instance.
/// How long any one shutdown step gets before it is abandoned.
///
/// Long enough for a real close under load -- a checkpoint of a large log is
/// not instant -- and short enough that three of them in a row still feel
/// like closing a window rather than waiting on one.
const shutdownStepTimeout = Duration(seconds: 4);

/// Runs one shutdown step, and gives up rather than hanging the app.
///
/// Reports which step it was, since "the app would not close" is otherwise
/// unattributable: the failure leaves no window, no dialog and, before this,
/// no line in the log either.
Future<void> closeQuietly(
  String what,
  Future<void> Function() step, {
  Duration within = shutdownStepTimeout,
}) async {
  try {
    await step().timeout(within);
  } on TimeoutException {
    AppLog.instance.error(
      'closing $what did not finish in ${within.inMilliseconds}ms, moving on',
      tag: 'shutdown',
    );
  } catch (error, stack) {
    AppLog.instance.error(
      'closing $what failed',
      tag: 'shutdown',
      error: error,
      stack: stack,
    );
  }
}

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
    // Debug-only, and a guess rather than a verified fix: opening the database
    // spawns a second isolate (drift's background worker) around 600ms after
    // main() starts. On this beta-channel SDK, VS Code has been seen to pause
    // *both* isolates on entry and never auto-resume either -- not just the
    // usual momentary pause every debug launch has, but one that sits there
    // until a person clicks Resume on each. That shape (the debugger's own
    // auto-resume failing, not merely being slow) matches a known class of
    // Dart-Code/DAP bug where a second isolate starting while the adapter is
    // still attaching to the first confuses its isolate bookkeeping for both.
    // Giving the debugger more working room before the second isolate exists
    // is the only lever app code has on that timing. If this still happens
    // after this change, the theory is wrong and the cause is upstream --
    // see docs/ARCHITECTURE.md.
    if (kDebugMode) {
      AppLog.instance.info('debug isolate-spawn delay');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
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

  /// Closes everything down, and cannot be prevented from finishing.
  ///
  /// Every step is bounded and independent, because the last one is the one
  /// that matters: this used to be two plain awaits, so an audio device that
  /// never finished deinitialising meant `db.close()` was never reached at
  /// all. The window then stayed open forever -- the app "would not close"
  /// -- and the only way out was to kill it, leaving the write-ahead log
  /// unfolded. That is the exact corruption this shutdown path exists to
  /// prevent, arrived at by way of the shutdown path itself.
  ///
  /// So nothing here is allowed to hold the app open. A step that hangs or
  /// throws is logged and abandoned, and the next one still runs.
  Future<void> dispose() async {
    await closeQuietly('the audio engine', engine.shutdown);
    await closeQuietly('the write-ahead log', db.checkpoint);
    await closeQuietly('the database', db.close);
  }

  /// Builds the player the app runs on.
  PlayerController createPlayer() => PlayerController(
        engine: engine,
        queueRepository: QueueRepository(db),
        libraryRepository: LibraryRepository(db),
        db: db,
      );
}
