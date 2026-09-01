import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../data/db/enums.dart' show QueueSource;
import '../domain/models/library_views.dart';
import '../features/playlists/playlists_view.dart';
import 'artwork.dart';
import 'selection.dart';
import 'spectrum_bars.dart';
import 'time_text.dart';

/// A list of tracks, used by the songs view, album pages and artist pages.
///
/// Every artist name in every row is its own tappable target rather than part
/// of a joined string. That is the visible half of the credits model: a track
/// credited to three people offers three links, and none of them is more than
/// one click from that artist's page.
class TrackList extends ConsumerWidget {
  const TrackList({
    super.key,
    required this.tracks,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.showArtwork = true,
    this.showAlbum = true,
    this.showTrackNumbers = false,
    this.groupByAlbum = false,
    this.onEditTrack,
    this.padding = const EdgeInsets.fromLTRB(24, 0, 24, 24),
    this.header,
    this.queueSource = QueueSource.user,
    this.queueSourceId,
    this.onRemoveTrack,
    this.removeTooltip = 'Remove',
    this.selectionScope,
    this.menuFor,
  });

  final List<TrackRow> tracks;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final bool showArtwork;
  final bool showAlbum;
  final bool showTrackNumbers;

  /// Opens the track editor, when there is somewhere to open it.
  final void Function(int trackId)? onEditTrack;

  /// Breaks the list into a headed section per release.
  ///
  /// Only sensible when [tracks] is already ordered by album -- the headings
  /// mark where the album turns over, they do not sort anything. Pair it with
  /// [LibrarySort.albumThenTrack].
  final bool groupByAlbum;

  final EdgeInsets padding;

  /// Rendered above the list and scrolled with it.
  final Widget? header;

  final QueueSource queueSource;
  final int? queueSourceId;

  /// Takes a track out of whatever list this is, when that means something.
  ///
  /// Set by a smart playlist, where there is no row to delete: the query put
  /// the track there, so the only way to remove one is to say so explicitly.
  final void Function(int trackId)? onRemoveTrack;

  /// What that removal is called here, since it differs by context.
  final String removeTooltip;

  /// Set to make rows selectable with Ctrl and Shift.
  ///
  /// Left null in a playlist or a queue, where a row's position is part of what
  /// it means and multi-select would need to answer questions -- which of two
  /// copies did you pick? -- that the lists it is used in do not have.
  final SelectionScope? selectionScope;

  /// The right-click menu for a row, built when it opens so it can read the
  /// selection as it is then.
  final List<MenuAction> Function(TrackRow track)? menuFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The ids in display order, so Shift-click means between these two rows on
    // screen rather than between by id.
    final order = [for (final track in tracks) track.id];
    final currentTrackId =
        ref.watch(playerProvider.select((s) => s.current?.trackId));
    final isPlaying = ref.watch(playerProvider.select((s) => s.isPlaying));

    final rows = _buildRows();

    return ListView.builder(
      padding: padding,
      // One extra slot for the header, so it scrolls with the content instead
      // of eating vertical space permanently.
      itemCount: rows.length + (header == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (header != null) {
          if (index == 0) return header!;
          index -= 1;
        }
        final row = rows[index];

        if (row is _HeadingRow) {
          return _AlbumHeading(
            title: row.title,
            albumId: row.albumId,
            trackCount: row.trackCount,
            imagePath: row.imagePath,
            isFirst: index == 0,
            onOpenAlbum: onOpenAlbum,
          );
        }

        final trackRow = row as _TrackRowSlot;
        return TrackTile(
          track: trackRow.track,
          index: trackRow.trackIndex,
          isCurrent: trackRow.track.id == currentTrackId,
          isPlaying: isPlaying,
          // Every track under a heading carries the same cover, so a column of
          // identical thumbnails says nothing. The heading holds the artwork
          // and the rows get their track numbers, which is the information
          // actually missing from a grouped list.
          showArtwork: showArtwork && (!groupByAlbum || trackRow.alone),
          showAlbum: showAlbum && (!groupByAlbum || trackRow.alone),
          showTrackNumber:
              showTrackNumbers || (groupByAlbum && !trackRow.alone),
          onOpenArtist: onOpenArtist,
          onOpenAlbum: onOpenAlbum,
          onEditTrack: onEditTrack,
          onRemove: onRemoveTrack,
          removeTooltip: removeTooltip,
          onPlay: () => _playFrom(ref, trackRow.trackIndex),
          selectionScope: selectionScope,
          order: order,
          menu: menuFor == null
              ? null
              : () => menuFor!(trackRow.track),
        );
      },
    );
  }

  /// Flattens the tracks into rows, inserting a heading where the album turns
  /// over.
  ///
  /// Each track slot keeps its index *within the tracks list*, not within the
  /// rows. That index is what play uses, and confusing the two would start
  /// playback on the wrong song by however many headings came before it.
  List<_Row> _buildRows() {
    if (!groupByAlbum) {
      return [
        for (var i = 0; i < tracks.length; i++) _TrackRowSlot(tracks[i], i),
      ];
    }

    final rows = <_Row>[];
    var start = 0;
    while (start < tracks.length) {
      final albumId = tracks[start].albumId;
      var end = start;
      while (end < tracks.length && tracks[end].albumId == albumId) {
        end += 1;
      }
      // A release with one track on it is a single, and a heading above a
      // single row says the same thing twice at four times the height. An
      // artist with a page full of singles was mostly headings.
      final alone = end - start == 1;
      if (!alone) {
        rows.add(_HeadingRow(
          title: tracks[start].albumTitle ?? 'Not part of an album',
          albumId: albumId,
          trackCount: end - start,
          imagePath: tracks[start].imagePath,
        ));
      }
      for (var i = start; i < end; i++) {
        rows.add(_TrackRowSlot(tracks[i], i, alone: alone));
      }
      start = end;
    }
    return rows;
  }

  /// Plays from [index], queueing the whole visible list.
  ///
  /// Queueing what is on screen matches the expectation that double-clicking a
  /// song in a list plays that list, not just that song.
  Future<void> _playFrom(WidgetRef ref, int index) async {
    await ref.read(playerProvider.notifier).playAll(
          tracks.map((t) => t.id).toList(),
          startIndex: index,
          source: queueSource,
          sourceRefId: queueSourceId,
        );
  }
}

/// One slot in a [TrackList].
sealed class _Row {
  const _Row();
}

class _HeadingRow extends _Row {
  const _HeadingRow({
    required this.title,
    required this.trackCount,
    this.albumId,
    this.imagePath,
  });

  final String title;
  final int? albumId;
  final int trackCount;
  final String? imagePath;
}

class _TrackRowSlot extends _Row {
  const _TrackRowSlot(this.track, this.trackIndex, {this.alone = false});

  final TrackRow track;

  /// Index into the tracks list, which is what play uses.
  final int trackIndex;

  /// The only track of its release, so it has no heading above it.
  ///
  /// It carries what the heading would have: its own cover and the album name,
  /// rather than a track number that can only ever read "1".
  final bool alone;
}

/// Names the release a run of tracks belongs to.
class _AlbumHeading extends StatelessWidget {
  const _AlbumHeading({
    required this.title,
    required this.trackCount,
    required this.isFirst,
    this.albumId,
    this.imagePath,
    this.onOpenAlbum,
  });

  final String title;
  final int? albumId;
  final int trackCount;
  final String? imagePath;
  final bool isFirst;
  final void Function(int albumId)? onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tappable = albumId != null && onOpenAlbum != null;

    return Padding(
      padding: EdgeInsets.only(top: isFirst ? 8 : 28, bottom: 8),
      child: Row(
        children: [
          Artwork(
            storedPath: imagePath,
            size: 36,
            borderRadius: 5,
            fallbackSeed: title,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: InkWell(
              onTap: tappable ? () => onOpenAlbum!(albumId!) : null,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: tappable ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            pluralize(trackCount, 'track'),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Divider(
              color: scheme.outlineVariant.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row in a [TrackList].
class TrackTile extends ConsumerStatefulWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.index,
    required this.isCurrent,
    required this.isPlaying,
    required this.onPlay,
    this.showArtwork = true,
    this.showAlbum = true,
    this.showTrackNumber = false,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onEditTrack,
    this.onRemove,
    this.removeTooltip = 'Remove',
    this.selectionScope,
    this.order = const [],
    this.menu,
  });

  final TrackRow track;
  final int index;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onPlay;
  final bool showArtwork;
  final bool showAlbum;
  final bool showTrackNumber;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int trackId)? onEditTrack;

  /// Takes this track out of the list it is in. See [TrackList.onRemoveTrack].
  final void Function(int trackId)? onRemove;
  final String removeTooltip;

  final SelectionScope? selectionScope;
  final List<int> order;
  final List<MenuAction> Function()? menu;

  @override
  ConsumerState<TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends ConsumerState<TrackTile> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final track = widget.track;

    final scope = widget.selectionScope;
    final selected = scope == null
        ? false
        : ref.watch(
            selectionProvider(scope).select((s) => s.contains(track.id)),
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        // Selection outranks both the playing row and hover: it is the thing
        // the next action will act on, so it has to be the thing that stands
        // out.
        color: selected
            ? scheme.primary.withValues(alpha: 0.18)
            : widget.isCurrent
                ? scheme.primaryContainer.withValues(alpha: 0.35)
                : (_hovering
                    ? scheme.surfaceContainerHighest
                    : Colors.transparent),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            // Ctrl and Shift select; a plain click plays, as it always has.
            if (scope == null ||
                applyClick(ref, scope, track.id, widget.order)) {
              widget.onPlay();
            }
          },
          onSecondaryTapUp: widget.menu == null
              ? null
              : (details) {
                  if (scope != null) {
                    prepareContextMenu(ref, scope, track.id);
                  }
                  showItemMenu(context, details.globalPosition, widget.menu!());
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                _leading(scheme),
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: widget.isCurrent ? scheme.primary : null,
                                fontWeight: widget.isCurrent
                                    ? FontWeight.w600
                                    : null,
                              ),
                            ),
                          ),
                          if (track.lossless) ...[
                            const SizedBox(width: 8),
                            _Chip(label: 'FLAC', scheme: scheme),
                          ],
                          if (track.isMissing) ...[
                            const SizedBox(width: 8),
                            Tooltip(
                              message: 'The file for this track is missing',
                              child: Icon(
                                Icons.link_off,
                                size: 15,
                                color: scheme.error,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      _CreditLine(
                        track: track,
                        onOpenArtist: widget.onOpenArtist,
                      ),
                    ],
                  ),
                ),
                if (widget.showAlbum && track.albumTitle != null)
                  Expanded(
                    flex: 3,
                    child: _LinkText(
                      text: track.albumTitle!,
                      onTap: track.albumId == null
                          ? null
                          : () => widget.onOpenAlbum?.call(track.albumId!),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                const SizedBox(width: 12),
                // Row actions appear on hover, so a long list stays quiet.
                AnimatedOpacity(
                  opacity: _hovering ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  // See the note in albums_view: dropping semantics at zero
                  // opacity churns the accessibility tree on every hover.
                  alwaysIncludeSemantics: true,
                  child: _RowActions(
                    track: track,
                    onEdit: widget.onEditTrack,
                    onRemove: widget.onRemove,
                    removeTooltip: widget.removeTooltip,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatDuration(track.duration),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Artwork, a track number, or the playing indicator.
  Widget _leading(ColorScheme scheme) {
    if (widget.isCurrent) {
      return SizedBox(
        width: widget.showArtwork ? 40 : 24,
        child: Center(
          child: PlayingIndicator(isPlaying: widget.isPlaying),
        ),
      );
    }
    if (widget.showArtwork) {
      return Artwork(
        storedPath: widget.track.imagePath,
        size: 40,
        borderRadius: 5,
        fallbackSeed: widget.track.albumTitle ?? widget.track.title,
        fallbackIcon: Icons.music_note_outlined,
      );
    }
    if (widget.showTrackNumber) {
      return SizedBox(
        width: 24,
        child: Text(
          '${widget.track.trackNo ?? widget.index + 1}',
          textAlign: TextAlign.end,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );
    }
    return const SizedBox(width: 24);
  }
}

/// The artist line, with each name individually tappable.
class _CreditLine extends StatelessWidget {
  const _CreditLine({required this.track, required this.onOpenArtist});

  final TrackRow track;
  final void Function(int artistId)? onOpenArtist;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    if (track.credits.isEmpty) {
      return Text('Unknown artist', style: style);
    }

    final mains = track.mainCredits;
    final featured = track.featuredCredits;

    return DefaultTextStyle.merge(
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < mains.length; i++) ...[
            if (i > 0) const Text(', '),
            _LinkText(
              text: mains[i].displayName,
              onTap: () => onOpenArtist?.call(mains[i].artistId),
              style: style,
            ),
          ],
          if (featured.isNotEmpty) ...[
            const Text('  feat. '),
            for (var i = 0; i < featured.length; i++) ...[
              if (i > 0) const Text(', '),
              _LinkText(
                text: featured[i].displayName,
                onTap: () => onOpenArtist?.call(featured[i].artistId),
                style: style,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Text that underlines on hover and reports a click.
class _LinkText extends StatefulWidget {
  const _LinkText({required this.text, this.onTap, this.style});

  final String text;
  final VoidCallback? onTap;
  final TextStyle? style;

  @override
  State<_LinkText> createState() => _LinkTextState();
}

class _LinkTextState extends State<_LinkText> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (widget.style ?? const TextStyle()).copyWith(
            decoration: enabled && _hovering
                ? TextDecoration.underline
                : TextDecoration.none,
            color: enabled && _hovering
                ? Theme.of(context).colorScheme.onSurface
                : null,
          ),
        ),
      ),
    );
  }
}

/// Per-row actions: favourite, queue, more.
/// The buttons at the end of a row.
///
/// Always live, never disabled between hovers. Turning a button from disabled
/// to enabled rewrites its semantics node, and the Windows accessibility
/// bridge treats that as the node leaving and a new one arriving: hovering
/// twenty rows threw 85 "Failed to update ui::AXTree" errors, and not doing it
/// throws one. Nothing is lost -- reaching these with a mouse means hovering
/// the row, which is what makes them visible in the first place, and a screen
/// reader should be able to use them without hovering anything.
class _RowActions extends ConsumerWidget {
  const _RowActions({
    required this.track,
    this.onEdit,
    this.onRemove,
    this.removeTooltip = 'Remove',
  });

  final TrackRow track;
  final void Function(int trackId)? onEdit;
  final void Function(int trackId)? onRemove;
  final String removeTooltip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.read(playerProvider.notifier);
    final db = ref.watch(databaseProvider);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onEdit != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Edit this track',
            onPressed: () => onEdit!(track.id),
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: track.isFavorite ? 'Remove from favourites' : 'Favourite',
          onPressed: () => db.customStatement(
            'UPDATE tracks SET is_favorite = NOT is_favorite WHERE id = ?',
            [track.id],
          ),
          icon: Icon(
            track.isFavorite ? Icons.favorite : Icons.favorite_border,
            size: 18,
            color: track.isFavorite
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Play next',
          onPressed: () => player.playNext([track.id]),
          icon: const Icon(Icons.playlist_play, size: 19),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Add to queue',
          onPressed: () => player.addToQueue([track.id]),
          icon: const Icon(Icons.playlist_add, size: 19),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Add to a playlist',
          onPressed: () => showAddToPlaylist(context, ref, [track.id]),
          icon: const Icon(Icons.library_add_outlined, size: 18),
        ),
        if (onRemove != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: removeTooltip,
            onPressed: () => onRemove!(track.id),
            icon: const Icon(Icons.block_outlined, size: 18),
          ),
      ],
    );
  }
}

/// Offers the playlists, and adds [trackIds] to the chosen one.
///
/// Also offers making a new playlist, because the first time anyone reaches for
/// this there will not be one yet.
Future<void> showAddToPlaylist(
  BuildContext context,
  WidgetRef ref,
  List<int> trackIds,
) async {
  final playlists = await ref.read(playlistsProvider.future);
  if (!context.mounted) return;

  final chosen = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(
        trackIds.length == 1
            ? 'Add to a playlist'
            : 'Add ${pluralize(trackIds.length, 'track')} to a playlist',
      ),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(-1),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.add, size: 18),
                SizedBox(width: 12),
                Text('New playlist...'),
              ],
            ),
          ),
        ),
        if (playlists.isNotEmpty) const Divider(),
        for (final playlist in playlists)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(playlist.id),
            child: Padding(
              // Indented by depth, so a nested playlist is recognisable here
              // as the same thing it is in the playlists view.
              padding: EdgeInsets.only(
                left: playlist.depth * 20.0,
                top: 6,
                bottom: 6,
              ),
              child: Text(
                '${playlist.name} · '
                '${pluralize(playlist.trackCount, 'track')}',
              ),
            ),
          ),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return;

  var target = chosen;
  if (target == -1) {
    final created = await createPlaylist(context, ref);
    if (created == null) return;
    target = created;
  }

  await ref.read(playlistRepositoryProvider).addTracks(target, trackIds);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Added ${pluralize(trackIds.length, 'track')}'),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// A small outlined label, for format badges.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.scheme});

  final String label;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          letterSpacing: 0.4,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
