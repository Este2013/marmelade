import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models/library_views.dart';
import '../../data/repositories/tag_repository.dart' show TagTarget;
import '../../domain/search/smart_query.dart';
import '../../domain/text/normalize.dart' show matchesQuery;
import '../../widgets/empty_state.dart';
import '../../widgets/filter_field.dart';
import '../../widgets/section_title.dart';
import '../../widgets/selection.dart';
import 'bulk_actions.dart';
import '../../widgets/time_text.dart';
import '../../widgets/track_list.dart';

/// The tracks a smart-query filter currently matches, or null when the
/// filter is not written that way. Debounced the same way search is: a fast
/// typist should not fire one resolve per keystroke.
final _smartSongFilterProvider = FutureProvider<Set<int>?>((ref) async {
  final filter = ref.watch(songFilterProvider);
  if (SmartQuery.parse(filter).clauses.isEmpty) return null;

  var superseded = false;
  ref.onDispose(() => superseded = true);
  await Future<void>.delayed(const Duration(milliseconds: 200));
  if (superseded) return null;

  return (await ref.read(smartPlaylistResolverProvider).resolve(filter))
      .toSet();
});

/// Every song, and the ones that survive the current filter.
///
/// Shared between [SongsToolbar] (which only needs the counts and the
/// shuffle button) and the list (which needs the filtered rows) so the
/// filtering itself happens once regardless of which of them rebuilds.
final songsShownProvider =
    Provider<({List<TrackRow> all, List<TrackRow> shown})>((ref) {
  final all = ref.watch(allTracksProvider).value ?? const <TrackRow>[];
  final filter = ref.watch(songFilterProvider);

  // A query written in field syntax -- `artist:Camellia`, `is:Favourite` --
  // is answered precisely through the smart-query resolver instead of by
  // treating the whole typed string as a literal substring.
  final smartMatches = ref.watch(_smartSongFilterProvider).value;
  if (smartMatches != null) {
    return (
      all: all,
      shown: [for (final track in all) if (smartMatches.contains(track.id)) track],
    );
  }

  // Matched on everything the row shows: a song is as likely to be looked for
  // by who is on it or which release it is from as by its title.
  final shown = [
    for (final track in all)
      if (matchesQuery(filter, [
        track.title,
        track.albumTitle,
        for (final credit in track.credits) credit.name,
        for (final credit in track.credits) credit.creditedAs,
      ]))
        track,
  ];
  return (all: all, shown: shown);
});

/// The full song list.
class SongsView extends ConsumerWidget {
  const SongsView({
    super.key,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    this.onEditTrack,
  });

  final void Function(int artistId) onOpenArtist;
  final void Function(int albumId) onOpenAlbum;
  final void Function(int trackId)? onEditTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(allTracksProvider);
    final filter = ref.watch(songFilterProvider);
    final shown = ref.watch(songsShownProvider).shown;

    return Column(
      children: [
        _SongSelectionBar(tracks: shown, onEditTrack: onEditTrack),
        Expanded(
          child: tracks.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not read the library',
              message: '$error',
            ),
            data: (items) {
              if (items.isEmpty) return const LibraryEmptyState();
              if (shown.isEmpty) {
                return FilteredEmpty(
                  query: filter,
                  noun: 'song',
                  onClear: () => ref.read(songFilterProvider.notifier).set(''),
                );
              }
              return TrackList(
                tracks: shown,
                onOpenArtist: onOpenArtist,
                onOpenAlbum: onOpenAlbum,
                onEditTrack: onEditTrack,
                selectionScope: SelectionScope.songs,
                menuFor: (track) => _trackMenu(context, ref, track),
              );
            },
          ),
        ),
      ],
    );
  }

  /// The right-click menu for a row.
  ///
  /// Deliberately overlaps the hover buttons: the buttons are faster once you
  /// know they are there, and a menu is what someone tries first. Neither is
  /// the only way to reach anything.
  List<MenuAction> _trackMenu(
    BuildContext context,
    WidgetRef ref,
    TrackRow track,
  ) {
    final selection = ref.read(selectionProvider(SelectionScope.songs));
    // Right-clicking outside the selection has already narrowed it to this
    // row, so the selection is always what to act on.
    final ids = selection.contains(track.id) && selection.isNotEmpty
        ? selection.ids.toList()
        : [track.id];
    final many = ids.length > 1;
    final player = ref.read(playerProvider.notifier);

    return [
      MenuAction(
        label: many ? 'Play these ${ids.length}' : 'Play',
        icon: Icons.play_arrow,
        onSelected: () => player.playAll(ids),
      ),
      MenuAction(
        label: 'Play next',
        icon: Icons.playlist_play,
        onSelected: () => player.playNext(ids),
      ),
      MenuAction(
        label: 'Add to the queue',
        icon: Icons.playlist_add,
        onSelected: () => player.addToQueue(ids),
      ),
      const MenuAction.separator(),
      MenuAction(
        label: 'Add to a playlist',
        icon: Icons.library_add_outlined,
        onSelected: () => addTracksToPlaylist(context, ref, ids),
      ),
      MenuAction(
        label: many ? 'Tag these ${ids.length} songs' : 'Add a tag',
        icon: Icons.label_outline,
        onSelected: () => tagSelection(
          context,
          ref,
          target: TagTarget.track,
          ids: ids.toSet(),
          noun: 'song',
        ),
      ),
      const MenuAction.separator(),
      if (!many && track.albumId != null)
        MenuAction(
          label: 'Go to the album',
          icon: Icons.album_outlined,
          onSelected: () => onOpenAlbum(track.albumId!),
        ),
      if (!many && track.credits.isNotEmpty)
        MenuAction(
          label: 'Go to ${track.credits.first.name}',
          icon: Icons.person_outline,
          onSelected: () => onOpenArtist(track.credits.first.artistId),
        ),
      if (!many && onEditTrack != null)
        MenuAction(
          label: 'Edit',
          icon: Icons.edit_outlined,
          onSelected: () => onEditTrack!(track.id),
        ),
    ];
  }

}

/// Title, count, filter, shuffle and sort -- the songs section's own
/// toolbar, merged into the window's title bar. See [AppShell] and
/// `WindowChrome.content`.
class SongsToolbar extends ConsumerWidget {
  const SongsToolbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sort = ref.watch(trackSortProvider);
    final filter = ref.watch(songFilterProvider);
    final data = ref.watch(songsShownProvider);

    return Row(
      children: [
        const SectionTitle(icon: Icons.music_note, label: 'Songs'),
        const SizedBox(width: 12),
        Text(
          filter.isEmpty
              ? pluralize(data.all.length, 'song')
              : '${data.shown.length} of ${pluralize(data.all.length, 'song')}',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: FilterField(
                value: filter,
                width: null,
                hint: 'Filter songs',
                onChanged: (value) =>
                    ref.read(songFilterProvider.notifier).set(value),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        if (data.shown.isNotEmpty)
          OutlinedButton.icon(
            // Shuffles what is on screen, so a filter narrows this too.
            onPressed: () => _shuffleEverything(ref, data.shown),
            icon: const Icon(Icons.shuffle, size: 18),
            label: Text(filter.isEmpty ? 'Shuffle all' : 'Shuffle these'),
          ),
        const SizedBox(width: 8),
        PopupMenuButton<LibrarySort>(
          tooltip: 'Sort',
          initialValue: sort,
          onSelected: (value) =>
              ref.read(trackSortProvider.notifier).set(value),
          icon: const Icon(Icons.sort),
          itemBuilder: (context) => [
            for (final option in const [
              LibrarySort.nameAscending,
              LibrarySort.nameDescending,
              LibrarySort.recentlyAdded,
              LibrarySort.recentlyPlayed,
              LibrarySort.mostPlayed,
              LibrarySort.releaseYear,
              LibrarySort.duration,
              LibrarySort.random,
            ])
              PopupMenuItem(value: option, child: Text(option.label)),
          ],
        ),
      ],
    );
  }
}

/// Queues the whole library in a random order and starts playing.
Future<void> _shuffleEverything(WidgetRef ref, List<TrackRow> tracks) async {
  final player = ref.read(playerProvider.notifier);
  await player.playAll(tracks.map((t) => t.id).toList());
  await player.shuffleQueue();
  await player.playAt(0);
}

/// The bulk actions for a selection of songs.
class _SongSelectionBar extends ConsumerWidget {
  const _SongSelectionBar({required this.tracks, this.onEditTrack});

  final List<TrackRow> tracks;
  final void Function(int trackId)? onEditTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider(SelectionScope.songs));
    final ids = selection.ids.toList();
    final player = ref.read(playerProvider.notifier);

    return SelectionBar(
      scope: SelectionScope.songs,
      noun: 'song',
      onSelectAll: () => ref
          .read(selectionProvider(SelectionScope.songs).notifier)
          .selectAll([for (final track in tracks) track.id]),
      actions: [
        MenuAction(
          label: 'Play',
          icon: Icons.play_arrow,
          onSelected: () => player.playAll(ids),
        ),
        MenuAction(
          label: 'Queue',
          icon: Icons.playlist_add,
          onSelected: () => player.addToQueue(ids),
        ),
        MenuAction(
          label: 'Playlist',
          icon: Icons.library_add_outlined,
          onSelected: () => addTracksToPlaylist(context, ref, ids),
        ),
        MenuAction(
          label: 'Tag',
          icon: Icons.label_outline,
          onSelected: () => tagSelection(
            context,
            ref,
            target: TagTarget.track,
            ids: ids.toSet(),
            noun: 'song',
          ),
        ),
      ],
    );
  }
}
