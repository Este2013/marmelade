import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import '../../widgets/track_list.dart';

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
    final sort = ref.watch(trackSortProvider);
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Row(
            children: [
              Text('Songs', style: theme.textTheme.headlineSmall),
              const SizedBox(width: 12),
              Text(
                pluralize(tracks.value?.length ?? 0, 'song'),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const Spacer(),
              if (tracks.value?.isNotEmpty ?? false)
                OutlinedButton.icon(
                  onPressed: () => _shuffleEverything(ref, tracks.value!),
                  icon: const Icon(Icons.shuffle, size: 18),
                  label: const Text('Shuffle all'),
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
          ),
        ),
        Expanded(
          child: tracks.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not read the library',
              message: '$error',
            ),
            data: (items) => items.isEmpty
                ? const LibraryEmptyState()
                : TrackList(
                    tracks: items,
                    onOpenArtist: onOpenArtist,
                    onOpenAlbum: onOpenAlbum,
                    onEditTrack: onEditTrack,
                  ),
          ),
        ),
      ],
    );
  }

  /// Queues the whole library in a random order and starts playing.
  Future<void> _shuffleEverything(WidgetRef ref, List<TrackRow> tracks) async {
    final player = ref.read(playerProvider.notifier);
    await player.playAll(tracks.map((t) => t.id).toList());
    await player.shuffleQueue();
    await player.playAt(0);
  }
}
