import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart'
    show PlaylistGrouping, PlaylistSort, QueueSource;
import '../../data/repositories/playlist_repository.dart';
import '../../data/repositories/smart_playlist_resolver.dart' show smartPlaylistSorts;
import '../../data/repositories/tag_repository.dart';
import '../edit/tag_section.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/expandable_artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import 'playlist_pickers.dart';
import 'playlists_view.dart';
import 'playlist_tracks.dart';
import 'smart_query_field.dart';

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
    this.onOpenTag,
  });

  final int playlistId;
  final VoidCallback onBack;
  final void Function(int playlistId) onOpenPlaylist;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int trackId)? onEditTrack;
  final void Function(int tagId)? onOpenTag;

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
        return PlaylistTracks(
          playlist: card,
          tracks: items,
          onOpenArtist: onOpenArtist,
          onOpenAlbum: onOpenAlbum,
          onEditTrack: onEditTrack,
          // A query put these tracks here, so there is no row to delete. The
          // only way to drop one is to say it does not belong, which is what
          // an exclusion is.
          onRemoveTrack: !card.isSmart
              ? null
              : (trackId) => ref
                  .read(playlistRepositoryProvider)
                  .exclude(playlistId, trackId),
          removeTooltip: 'Keep this track out of this playlist',
          header: _Header(
            playlist: card,
            tracks: items,
            entries: entries.value ?? const [],
            onBack: onBack,
            onOpenPlaylist: onOpenPlaylist,
            onOpenTag: onOpenTag,
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
    this.onOpenTag,
  });

  final PlaylistCard playlist;
  final List<TrackRow> tracks;
  final List<PlaylistEntry> entries;
  final VoidCallback onBack;
  final void Function(int playlistId) onOpenPlaylist;
  final void Function(int tagId)? onOpenTag;

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
                tooltip: 'Add songs',
                onPressed: () => showAddTracksToPlaylist(
                  context,
                  ref,
                  playlist.id,
                  playlistName: playlist.name,
                ),
                icon: const Icon(Icons.music_note_outlined),
              ),
              IconButton(
                tooltip: 'Add an album',
                onPressed: () => showAddAlbumToThisPlaylist(
                  context,
                  ref,
                  playlist.id,
                  playlistName: playlist.name,
                ),
                icon: const Icon(Icons.album_outlined),
              ),
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
              ExpandableArtwork(
                storedPath: playlist.imagePath,
                size: 160,
                borderRadius: 12,
                owner: PictureOwner.playlist,
                id: playlist.id,
                title: playlist.name,
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
          if (playlist.isSmart) ...[
            const SizedBox(height: 24),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: _QuerySection(playlist: playlist),
            ),
          ],
          const SizedBox(height: 24),
          // Constrained, because the section is designed for an editor page
          // and this one is a header inside a scrolling list.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: TagSection(
              target: TagTarget.playlist,
              id: playlist.id,
              onOpenTag: onOpenTag,
            ),
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
          _OrderControls(playlist: playlist),
          const SizedBox(height: 12),
          Text(
            switch (playlist) {
              final p when p.isSmart => 'Tracks matching this query, now',
              final p when p.childCount > 0 => 'All tracks, in order',
              _ => 'Tracks',
            },
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

/// The query behind a smart playlist, editable in place.
///
/// On the playlist itself rather than behind a dialog: the query *is* the
/// playlist, and a smart playlist you cannot see the definition of is a list of
/// songs that changes for reasons you cannot inspect.
class _QuerySection extends ConsumerStatefulWidget {
  const _QuerySection({required this.playlist});

  final PlaylistCard playlist;

  @override
  ConsumerState<_QuerySection> createState() => _QuerySectionState();
}

class _QuerySectionState extends ConsumerState<_QuerySection> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.playlist.query ?? '');
  late String _sort = widget.playlist.querySort ?? '';
  var _saved = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final dirty = _controller.text != (widget.playlist.query ?? '');
      if (dirty == !_saved) return;
      setState(() => _saved = !dirty);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(playlistRepositoryProvider).saveQuery(
          widget.playlist.id,
          query: _controller.text,
          sort: _sort,
        );
    if (mounted) setState(() => _saved = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 18, color: scheme.primary),
              const SizedBox(width: 10),
              Text('Follows a search', style: theme.textTheme.titleMedium),
              const Spacer(),
              FilledButton.icon(
                onPressed: _saved ? null : _save,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Nothing is stored: the tracks below are this query and the '
            'library, right now. Add music that matches and it appears here.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          SmartQueryField(
            controller: _controller,
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: smartPlaylistSorts.containsKey(_sort)
                      ? _sort
                      : '',
                  decoration: const InputDecoration(
                    labelText: 'Order',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final entry in smartPlaylistSorts.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _sort = value);
                    _save();
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _Exclusions(playlistId: widget.playlist.id),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What this playlist refuses to include, and a way to change its mind.
class _Exclusions extends ConsumerWidget {
  const _Exclusions({required this.playlistId});

  final int playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final excluded = ref.watch(playlistExclusionsProvider(playlistId));
    final rows = excluded.value ?? const <TrackRow>[];
    if (rows.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${pluralize(rows.length, 'track')} kept out',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final track in rows)
              Chip(
                label: Text(track.title),
                avatar: const Icon(Icons.block_outlined, size: 16),
                onDeleted: () => ref
                    .read(playlistRepositoryProvider)
                    .unexclude(playlistId, track.id),
                deleteIcon: const Icon(Icons.undo, size: 16),
                deleteButtonTooltipMessage: 'Let it back in',
              ),
          ],
        ),
      ],
    );
  }
}

/// How the tracks are ordered and grouped.
///
/// Both are stored on the playlist, so they apply to whatever it holds later as
/// well: add a track to an album-grouped playlist and it appears under its
/// album without anyone rearranging anything.
class _OrderControls extends ConsumerWidget {
  const _OrderControls({required this.playlist});

  final PlaylistCard playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final repository = ref.read(playlistRepositoryProvider);

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 210,
          child: DropdownButtonFormField<PlaylistSort>(
            isExpanded: true,
            initialValue: playlist.displaySort,
            decoration: const InputDecoration(
              labelText: 'Order',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final sort in PlaylistSort.values)
                DropdownMenuItem(value: sort, child: Text(sort.label)),
            ],
            onChanged: (value) {
              if (value == null) return;
              repository.setDisplayRules(playlist.id, sort: value);
            },
          ),
        ),
        IconButton(
          tooltip: playlist.sortDescending ? 'Ascending' : 'Descending',
          isSelected: playlist.sortDescending,
          onPressed: () => repository.setDisplayRules(
            playlist.id,
            descending: !playlist.sortDescending,
          ),
          icon: Icon(
            playlist.sortDescending ? Icons.arrow_upward : Icons.arrow_downward,
          ),
        ),
        SizedBox(
          width: 190,
          child: DropdownButtonFormField<PlaylistGrouping>(
            isExpanded: true,
            initialValue: playlist.grouping,
            decoration: const InputDecoration(
              labelText: 'Groups',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final group in PlaylistGrouping.values)
                DropdownMenuItem(value: group, child: Text(group.label)),
            ],
            onChanged: (value) {
              if (value == null) return;
              repository.setDisplayRules(playlist.id, group: value);
            },
          ),
        ),
        Text(
          playlist.displaySort == PlaylistSort.custom
              ? 'Arranged by hand. Dragging keeps it that way.'
              : 'Drag a track to arrange it by hand.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
