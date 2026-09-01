import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart' show QueueSource;
import '../../domain/models/library_views.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import '../../widgets/track_list.dart';
import 'category_dialog.dart';
import 'tag_visuals.dart';

/// Everything carrying one tag.
///
/// Includes tracks that inherit it from their album or from a playlist, because
/// that is what the tag means. A page that showed only directly-tagged tracks
/// would disagree with the count in the tag list and with search.
class TagDetailView extends ConsumerWidget {
  const TagDetailView({
    super.key,
    required this.tagId,
    required this.onBack,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onEditTrack,
  });

  final int tagId;
  final VoidCallback onBack;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int trackId)? onEditTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(tagTrackListProvider(tagId));
    final tag = ref
        .watch(taggedProvider)
        .value
        ?.where((t) => t.id == tagId)
        .firstOrNull;

    return tracks.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load that tag',
        message: '$error',
      ),
      data: (items) {
        if (tag == null) {
          return EmptyState(
            icon: Icons.label_off_outlined,
            title: 'That tag is gone',
            message: 'It was deleted.',
            action:
                FilledButton(onPressed: onBack, child: const Text('Back')),
          );
        }
        return TrackList(
          tracks: items,
          onOpenArtist: onOpenArtist,
          onOpenAlbum: onOpenAlbum,
          onEditTrack: onEditTrack,
          queueSource: QueueSource.tag,
          queueSourceId: tagId,
          header: _Header(tag: tag, tracks: items, onBack: onBack),
        );
      },
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.tag,
    required this.tracks,
    required this.onBack,
  });

  final TagCard tag;
  final List<TrackRow> tracks;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = ref.read(playerProvider.notifier);
    final trackIds = tracks.map((t) => t.id).toList();
    final visuals = tagVisuals(
      context,
      categoryIcon: tag.categoryIcon,
      color: tag.color,
    );

    final total = tracks.fold(
      Duration.zero,
      (sum, track) => sum + track.duration,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 12),
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
                tooltip: 'Edit this tag',
                onPressed: () => editTag(
                  context,
                  ref,
                  tagId: tag.id,
                  name: tag.name,
                  categoryId: tag.categoryId,
                ),
                icon: const Icon(Icons.edit_outlined),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(Icons.more_vert),
                onSelected: (action) async {
                  if (action != 'delete') return;
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('Delete ${tag.name}?'),
                      content: Text(
                        'It comes off everything carrying it -- '
                        '${pluralize(tag.trackCount, 'track')}. The music '
                        'itself is untouched.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true) return;
                  await ref.read(tagRepositoryProvider).deleteTag(tag.id);
                  // Back, because this page is about a tag that no longer
                  // exists -- staying would show the "that tag is gone" card
                  // where a page used to be.
                  onBack();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(visuals.icon, size: 34, color: visuals.color),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tag.name,
                      style: theme.textTheme.displaySmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (tag.categoryName != null) tag.categoryName!,
                        pluralize(tracks.length, 'track'),
                        if (total > Duration.zero) formatDurationLong(total),
                      ].join(' · '),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: trackIds.isEmpty
                    ? null
                    : () => player.playAll(
                          trackIds,
                          source: QueueSource.tag,
                          sourceRefId: tag.id,
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
                          source: QueueSource.tag,
                          sourceRefId: tag.id,
                        );
                        await player.shuffleQueue();
                      },
                icon: const Icon(Icons.shuffle, size: 18),
                label: const Text('Shuffle'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            'Tracks carrying this tag, including through an album or a playlist',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
