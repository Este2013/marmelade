import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../data/db/enums.dart' show QueueSource;
import '../domain/models/library_views.dart';
import 'artwork.dart';
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
    this.padding = const EdgeInsets.fromLTRB(24, 0, 24, 24),
    this.header,
    this.queueSource = QueueSource.user,
    this.queueSourceId,
  });

  final List<TrackRow> tracks;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final bool showArtwork;
  final bool showAlbum;
  final bool showTrackNumbers;

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          showArtwork: showArtwork && !groupByAlbum,
          showAlbum: showAlbum && !groupByAlbum,
          showTrackNumber: showTrackNumbers || groupByAlbum,
          onOpenArtist: onOpenArtist,
          onOpenAlbum: onOpenAlbum,
          onPlay: () => _playFrom(ref, trackRow.trackIndex),
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
      rows.add(_HeadingRow(
        title: tracks[start].albumTitle ?? 'Not part of an album',
        albumId: albumId,
        trackCount: end - start,
        imagePath: tracks[start].imagePath,
      ));
      for (var i = start; i < end; i++) {
        rows.add(_TrackRowSlot(tracks[i], i));
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
  const _TrackRowSlot(this.track, this.trackIndex);

  final TrackRow track;

  /// Index into the tracks list, which is what play uses.
  final int trackIndex;
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

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        color: widget.isCurrent
            ? scheme.primaryContainer.withValues(alpha: 0.35)
            : (_hovering ? scheme.surfaceContainerHighest : Colors.transparent),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onPlay,
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
                  child: _RowActions(track: track, enabled: _hovering),
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
class _RowActions extends ConsumerWidget {
  const _RowActions({required this.track, required this.enabled});

  final TrackRow track;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.read(playerProvider.notifier);
    final db = ref.watch(databaseProvider);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: track.isFavorite ? 'Remove from favourites' : 'Favourite',
          onPressed: enabled
              ? () => db.customStatement(
                    'UPDATE tracks SET is_favorite = NOT is_favorite '
                    'WHERE id = ?',
                    [track.id],
                  )
              : null,
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
          onPressed: enabled ? () => player.playNext([track.id]) : null,
          icon: const Icon(Icons.playlist_play, size: 19),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Add to queue',
          onPressed: enabled ? () => player.addToQueue([track.id]) : null,
          icon: const Icon(Icons.playlist_add, size: 19),
        ),
      ],
    );
  }
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
