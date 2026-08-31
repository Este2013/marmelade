import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/time_text.dart';
import '../../widgets/track_list.dart';

/// A playlist's tracks: grouped, and arrangeable by hand.
///
/// Dragging always works, whatever the sort says, and switches the playlist to
/// a custom order. A list that snapped back to sorted-by-title the moment you
/// let go would be worse than not offering the drag at all.
///
/// When the tracks are grouped, a track can only be rearranged inside its own
/// group and whole groups move as blocks. Dropping a track into another album's
/// section cannot mean anything -- the group *is* its album -- so it lands back
/// among its own, at the point it was dropped.
class PlaylistTracks extends ConsumerWidget {
  const PlaylistTracks({
    super.key,
    required this.playlist,
    required this.tracks,
    required this.header,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onEditTrack,
    this.onRemoveTrack,
    this.removeTooltip = 'Remove',
  });

  final PlaylistCard playlist;

  /// Already in the order the playlist asks for.
  final List<TrackRow> tracks;

  final Widget header;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int trackId)? onEditTrack;
  final void Function(int trackId)? onRemoveTrack;
  final String removeTooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = buildRows(tracks, playlist.grouping);

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      header: header,
      buildDefaultDragHandles: false,
      itemCount: rows.length,
      onReorderItem: (oldIndex, newIndex) =>
          _reorder(ref, rows, oldIndex, newIndex),
      itemBuilder: (context, index) {
        final row = rows[index];
        return switch (row) {
          PlaylistGroupRow(:final label, :final count, :final imagePath) => _GroupHeader(
              key: ValueKey('group-$label'),
              index: index,
              label: label,
              count: count,
              imagePath: imagePath,
            ),
          PlaylistTrackSlot(:final track, :final position) => _Row(
              key: ValueKey('track-${track.id}-$position'),
              index: index,
              track: track,
              tracks: tracks,
              position: position,
              playlistId: playlist.id,
              onOpenArtist: onOpenArtist,
              onOpenAlbum: onOpenAlbum,
              onEditTrack: onEditTrack,
              onRemoveTrack: onRemoveTrack,
              removeTooltip: removeTooltip,
            ),
        };
      },
    );
  }

  /// Applies a drag and stores the result.
  Future<void> _reorder(
    WidgetRef ref,
    List<PlaylistRow> rows,
    int oldIndex,
    int newIndex,
  ) async {
    final moved = move(rows, oldIndex, newIndex);
    final ordered = trackOrder(moved, playlist.grouping);
    await ref
        .read(playlistRepositoryProvider)
        .saveCustomOrder(playlist.id, ordered);
  }

  /// Moves one row, taking a group's tracks with its header.
  static List<PlaylistRow> move(List<PlaylistRow> rows, int from, int to) {
    final working = [...rows];

    // A header carries its group. Anything else would let a heading and its
    // tracks come apart, which is not a state the list can render.
    final block = <PlaylistRow>[working.removeAt(from)];
    if (block.first is PlaylistGroupRow) {
      while (from < working.length && working[from] is PlaylistTrackSlot) {
        block.add(working.removeAt(from));
      }
    }

    final target = to > from ? to - block.length : to;
    working.insertAll(target.clamp(0, working.length), block);
    return working;
  }

  /// The track ids the moved list implies, with groups kept whole.
  ///
  /// Rebuilt from the group each track actually belongs to rather than from
  /// where it landed: a track dropped under another album's heading is still
  /// that album's track, so it rejoins its own group at the point it was
  /// dropped.
  static List<int> trackOrder(List<PlaylistRow> rows, PlaylistGrouping grouping) {
    if (grouping == PlaylistGrouping.none) {
      return [
        for (final row in rows)
          if (row is PlaylistTrackSlot) row.track.id,
      ];
    }

    final order = <String>[];
    final byGroup = <String, List<int>>{};
    for (final row in rows) {
      final label = switch (row) {
        PlaylistGroupRow(:final label) => label,
        PlaylistTrackSlot(:final track) => groupLabel(track, grouping),
      };
      if (!byGroup.containsKey(label)) {
        order.add(label);
        byGroup[label] = [];
      }
      if (row is PlaylistTrackSlot) byGroup[label]!.add(row.track.id);
    }

    return [
      for (final label in order) ...byGroup[label]!,
    ];
  }

  /// Flattens the tracks into rows, inserting a heading where a group turns
  /// over.
  static List<PlaylistRow> buildRows(
    List<TrackRow> tracks,
    PlaylistGrouping grouping,
  ) {
    if (grouping == PlaylistGrouping.none) {
      return [
        for (var i = 0; i < tracks.length; i++)
          PlaylistTrackSlot(track: tracks[i], position: i),
      ];
    }

    final rows = <PlaylistRow>[];
    String? current;
    for (var i = 0; i < tracks.length; i++) {
      final label = groupLabel(tracks[i], grouping);
      if (label != current) {
        current = label;
        rows.add(
          PlaylistGroupRow(
            label: label,
            count: tracks.where((t) => groupLabel(t, grouping) == label).length,
            imagePath: grouping == PlaylistGrouping.album
                ? tracks[i].imagePath
                : null,
          ),
        );
      }
      rows.add(PlaylistTrackSlot(track: tracks[i], position: i));
    }
    return rows;
  }

  static String groupLabel(TrackRow track, PlaylistGrouping grouping) =>
      switch (grouping) {
        PlaylistGrouping.album => track.albumTitle ?? 'No album',
        PlaylistGrouping.artist =>
          track.mainCredits.firstOrNull?.name ?? 'Unknown artist',
        PlaylistGrouping.releaseYear =>
          track.releaseYear?.toString() ?? 'Unknown year',
        PlaylistGrouping.none => '',
      };
}

/// A row in a playlist's list: a group heading, or a track.
sealed class PlaylistRow {
  const PlaylistRow();
}

/// A heading, and how many tracks are under it.
class PlaylistGroupRow extends PlaylistRow {
  const PlaylistGroupRow({
    required this.label,
    required this.count,
    this.imagePath,
  });

  final String label;
  final int count;
  final String? imagePath;
}

/// One track, and where it sits in the whole list.
class PlaylistTrackSlot extends PlaylistRow {
  const PlaylistTrackSlot({required this.track, required this.position});

  final TrackRow track;

  /// Where it sits in the whole list, so playing starts on the right song.
  final int position;
}

/// A group heading, which drags its whole group.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    super.key,
    required this.index,
    required this.label,
    required this.count,
    this.imagePath,
  });

  final int index;
  final String label;
  final int count;
  final String? imagePath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Row(
        children: [
          if (imagePath != null) ...[
            Artwork(storedPath: imagePath, size: 34, borderRadius: 6),
            const SizedBox(width: 12),
          ] else ...[
            Icon(Icons.folder_outlined, size: 18, color: scheme.primary),
            const SizedBox(width: 10),
          ],
          Text(
            label,
            style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary),
          ),
          const SizedBox(width: 10),
          Text(
            pluralize(count, 'track'),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const Spacer(),
          ReorderableDragStartListener(
            index: index,
            child: Tooltip(
              message: 'Drag to move this whole group',
              child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// One track, with a handle.
class _Row extends ConsumerWidget {
  const _Row({
    super.key,
    required this.index,
    required this.track,
    required this.tracks,
    required this.position,
    required this.playlistId,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onEditTrack,
    this.onRemoveTrack,
    this.removeTooltip = 'Remove',
  });

  final int index;
  final TrackRow track;
  final List<TrackRow> tracks;
  final int position;
  final int playlistId;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int trackId)? onEditTrack;
  final void Function(int trackId)? onRemoveTrack;
  final String removeTooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final isCurrent = player.current?.trackId == track.id;

    return Row(
      children: [
        Expanded(
          child: TrackTile(
            track: track,
            index: position,
            isCurrent: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            onPlay: () => controller.playAll(
              [for (final one in tracks) one.id],
              startIndex: position,
              source: QueueSource.playlist,
              sourceRefId: playlistId,
            ),
            onOpenArtist: onOpenArtist,
            onOpenAlbum: onOpenAlbum,
            onEditTrack: onEditTrack,
            onRemove: onRemoveTrack,
            removeTooltip: removeTooltip,
          ),
        ),
        ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: const EdgeInsets.only(left: 4, right: 2),
            child: Tooltip(
              message: 'Drag to rearrange',
              child: Icon(
                Icons.drag_indicator,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
