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
class PlaylistTracks extends ConsumerStatefulWidget {
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
  ConsumerState<PlaylistTracks> createState() => PlaylistTracksState();

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
  /// [hidden] is every track the playlist holds, including the ones a
  /// collapsed group is not showing. Without it, folding a group away and then
  /// dragging anything would save an order with that group's tracks missing --
  /// which is to say, would delete them from the arrangement.
  static List<int> trackOrder(
    List<PlaylistRow> rows,
    PlaylistGrouping grouping, {
    List<TrackRow> hidden = const [],
  }) {
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

    // Fill each group back up from the full list, keeping the relative order it
    // already had. A group whose tracks are all hidden still has its heading in
    // [rows], so it keeps its place.
    for (final track in hidden) {
      final label = groupLabel(track, grouping);
      final group = byGroup[label];
      if (group == null) {
        order.add(label);
        byGroup[label] = [track.id];
        continue;
      }
      if (!group.contains(track.id)) group.add(track.id);
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

class PlaylistTracksState extends ConsumerState<PlaylistTracks> {
  /// Groups folded away, by label.
  ///
  /// In memory rather than stored: collapsing is how you get through a long
  /// list right now, not a property of the playlist, and finding a playlist
  /// still folded up a week later would be a puzzle rather than a convenience.
  final _collapsed = <String>{};

  List<String> get _labels {
    final seen = <String>[];
    for (final track in widget.tracks) {
      final label = PlaylistTracks.groupLabel(track, widget.playlist.grouping);
      if (!seen.contains(label)) seen.add(label);
    }
    return seen;
  }

  void _toggle(String label) => setState(() {
        if (!_collapsed.remove(label)) _collapsed.add(label);
      });

  void _setAll({required bool collapsed}) => setState(() {
        _collapsed.clear();
        if (collapsed) _collapsed.addAll(_labels);
      });

  @override
  Widget build(BuildContext context) {
    final grouping = widget.playlist.grouping;
    final all = PlaylistTracks.buildRows(widget.tracks, grouping);
    // What is on screen. A collapsed group keeps its heading and loses its
    // tracks, and the list is indexed by what is shown -- so the order a drag
    // produces has to be rebuilt against the full list, not this one.
    final rows = [
      for (final row in all)
        if (row is! PlaylistTrackSlot ||
            !_collapsed.contains(PlaylistTracks.groupLabel(row.track, grouping)))
          row,
    ];

    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          widget.header,
          if (grouping != PlaylistGrouping.none) _collapseControls(),
        ],
      ),
      buildDefaultDragHandles: false,
      itemCount: rows.length,
      onReorderItem: (oldIndex, newIndex) => _reorder(rows, oldIndex, newIndex),
      itemBuilder: (context, index) {
        final row = rows[index];
        return switch (row) {
          PlaylistGroupRow(:final label, :final count, :final imagePath) =>
            _GroupHeader(
              key: ValueKey('group-$label'),
              index: index,
              label: label,
              count: count,
              imagePath: imagePath,
              collapsed: _collapsed.contains(label),
              onToggle: () => _toggle(label),
            ),
          PlaylistTrackSlot(:final track, :final position) => _Row(
              key: ValueKey('track-${track.id}-$position'),
              index: index,
              track: track,
              tracks: widget.tracks,
              position: position,
              playlistId: widget.playlist.id,
              onOpenArtist: widget.onOpenArtist,
              onOpenAlbum: widget.onOpenAlbum,
              onEditTrack: widget.onEditTrack,
              onRemoveTrack: widget.onRemoveTrack,
              removeTooltip: widget.removeTooltip,
            ),
        };
      },
    );
  }

  Widget _collapseControls() {
    final everything = _labels;
    final allCollapsed =
        everything.isNotEmpty && _collapsed.length >= everything.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () => _setAll(collapsed: !allCollapsed),
            icon: Icon(
              allCollapsed ? Icons.unfold_more : Icons.unfold_less,
              size: 18,
            ),
            label: Text(allCollapsed ? 'Expand all' : 'Collapse all'),
          ),
          const SizedBox(width: 8),
          Text(
            '${everything.length} groups',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  /// Applies a drag and stores the result.
  Future<void> _reorder(
    List<PlaylistRow> rows,
    int oldIndex,
    int newIndex,
  ) async {
    final moved = PlaylistTracks.move(rows, oldIndex, newIndex);
    final ordered = PlaylistTracks.trackOrder(
      moved,
      widget.playlist.grouping,
      hidden: widget.tracks,
    );
    await ref
        .read(playlistRepositoryProvider)
        .saveCustomOrder(widget.playlist.id, ordered);
  }
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
    required this.collapsed,
    required this.onToggle,
    this.imagePath,
  });

  final int index;
  final String label;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;
  final String? imagePath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      // The whole heading folds the group: it is the biggest target on the row
      // and there is nothing else clicking a heading could mean.
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
        child: Row(
        children: [
          Icon(
            collapsed ? Icons.chevron_right : Icons.expand_more,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
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
