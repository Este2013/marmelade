import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart' show QueueSource;
import '../../data/repositories/playlist_repository.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import '../../widgets/track_list.dart';
import 'playlists_view.dart';

/// One playlist: its rows in order, and everything you can do to them.
///
/// Two lists in one, deliberately kept apart. The rows are what the playlist
/// *contains* -- tracks and other playlists, reorderable -- while the track
/// list underneath is what it *resolves to*, following the nesting. They differ
/// as soon as a playlist is included, and conflating them would make it
/// impossible to reorder the thing you actually added.
class PlaylistDetailView extends ConsumerWidget {
  const PlaylistDetailView({
    super.key,
    required this.playlistId,
    required this.onBack,
    required this.onOpenPlaylist,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onEditTrack,
  });

  final int playlistId;
  final VoidCallback onBack;
  final void Function(int playlistId) onOpenPlaylist;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int trackId)? onEditTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlist = ref.watch(playlistProvider(playlistId));
    final tracks = ref.watch(playlistTracksProvider(playlistId));
    final entries = ref.watch(playlistEntriesProvider(playlistId));

    return playlist.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load that playlist',
        message: '$error',
      ),
      data: (card) {
        if (card == null) {
          return EmptyState(
            icon: Icons.playlist_remove,
            title: 'That playlist is gone',
            message: 'It was deleted, or the playlist holding it was.',
            action:
                FilledButton(onPressed: onBack, child: const Text('Back')),
          );
        }

        final items = tracks.value ?? const <TrackRow>[];
        return TrackList(
          tracks: items,
          onOpenArtist: onOpenArtist,
          onOpenAlbum: onOpenAlbum,
          onEditTrack: onEditTrack,
          queueSource: QueueSource.playlist,
          queueSourceId: playlistId,
          header: _Header(
            playlist: card,
            tracks: items,
            entries: entries.value ?? const [],
            onBack: onBack,
            onOpenPlaylist: onOpenPlaylist,
          ),
        );
      },
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.playlist,
    required this.tracks,
    required this.entries,
    required this.onBack,
    required this.onOpenPlaylist,
  });

  final PlaylistCard playlist;
  final List<TrackRow> tracks;
  final List<PlaylistEntry> entries;
  final VoidCallback onBack;
  final void Function(int playlistId) onOpenPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = ref.read(playerProvider.notifier);
    final repository = ref.read(playlistRepositoryProvider);
    final trackIds = tracks.map((t) => t.id).toList();

    final total = tracks.fold(
      Duration.zero,
      (sum, track) => sum + track.duration,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Back',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Add a playlist inside this one',
                onPressed: () => _includePlaylist(context, ref),
                icon: const Icon(Icons.playlist_add),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Artwork(
                storedPath: playlist.imagePath,
                size: 160,
                borderRadius: 12,
                fallbackSeed: playlist.name,
                fallbackIcon: Icons.playlist_play,
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playlist.name,
                      style: theme.textTheme.displaySmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        pluralize(tracks.length, 'track'),
                        if (total > Duration.zero) formatDurationLong(total),
                        if (playlist.childCount > 0)
                          '${pluralize(playlist.childCount, 'playlist')} '
                              'included',
                      ].join(' · '),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (playlist.description != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        playlist.description!,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: trackIds.isEmpty
                              ? null
                              : () => player.playAll(
                                    trackIds,
                                    source: QueueSource.playlist,
                                    sourceRefId: playlist.id,
                                  ),
                          icon: const Icon(Icons.play_arrow, size: 20),
                          label: const Text('Play'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: trackIds.isEmpty
                              ? null
                              : () async {
                                  await player.playAll(
                                    trackIds,
                                    source: QueueSource.playlist,
                                    sourceRefId: playlist.id,
                                  );
                                  await player.shuffleQueue();
                                },
                          icon: const Icon(Icons.shuffle, size: 18),
                          label: const Text('Shuffle'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (entries.isNotEmpty) ...[
            const SizedBox(height: 28),
            Row(
              children: [
                Text('Contents', style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Drag to reorder. An included playlist contributes its own '
                    'tracks, and follows any change to it.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Bounded, because this sits inside the scrolling track list: an
            // unbounded reorderable list inside a scroll view has no height to
            // lay out against.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: entries.length,
                onReorderItem: (oldIndex, newIndex) => repository.moveEntry(
                  playlist.id,
                  entries[oldIndex].itemId,
                  newIndex,
                ),
                itemBuilder: (context, index) => _EntryRow(
                  key: ValueKey(entries[index].itemId),
                  entry: entries[index],
                  index: index,
                  onOpenPlaylist: onOpenPlaylist,
                  onRemove: () => repository.removeEntry(
                    entries[index].itemId,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            playlist.childCount > 0 ? 'All tracks, in order' : 'Tracks',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Future<void> _includePlaylist(BuildContext context, WidgetRef ref) async {
    final all = await ref.read(playlistsProvider.future);
    if (!context.mounted) return;

    final candidates = all.where((p) => p.id != playlist.id).toList();
    if (candidates.isEmpty) {
      final created = await createPlaylist(context, ref);
      if (created == null) return;
      await ref
          .read(playlistRepositoryProvider)
          .addChildPlaylist(playlist.id, created);
      return;
    }

    final chosen = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Include a playlist in ${playlist.name}'),
        children: [
          for (final candidate in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(candidate.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '${candidate.name} · '
                  '${pluralize(candidate.trackCount, 'track')}',
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !context.mounted) return;

    final ok = await ref
        .read(playlistRepositoryProvider)
        .addChildPlaylist(playlist.id, chosen);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That playlist already contains this one, so including it would '
            'make a loop.',
          ),
        ),
      );
    }
  }
}

/// One row of a playlist's contents: a track, or a playlist included whole.
class _EntryRow extends ConsumerWidget {
  const _EntryRow({
    super.key,
    required this.entry,
    required this.index,
    required this.onRemove,
    required this.onOpenPlaylist,
  });

  final PlaylistEntry entry;
  final int index;
  final VoidCallback onRemove;
  final void Function(int playlistId) onOpenPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final title = entry.isChildPlaylist
        ? entry.childPlaylistName ?? 'A playlist'
        : ref.watch(trackRowProvider(entry.trackId!)).value?.title ?? '...';

    return Material(
      color: Colors.transparent,
      child: ListTile(
        dense: true,
        leading: Icon(
          entry.isChildPlaylist
              ? Icons.playlist_play
              : Icons.music_note_outlined,
          color: entry.isChildPlaylist ? scheme.primary : null,
        ),
        title: Text(title),
        subtitle: entry.isChildPlaylist
            ? Text(
                'Included playlist · '
                '${pluralize(entry.childTrackCount ?? 0, 'track')}',
              )
            : null,
        onTap: entry.isChildPlaylist
            ? () => onOpenPlaylist(entry.childPlaylistId!)
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Remove from this playlist',
              onPressed: onRemove,
              icon: const Icon(Icons.close, size: 18),
            ),
            ReorderableDragStartListener(
              index: index,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.drag_handle,
                      size: 18, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
