import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/queue_repository.dart';
import '../../domain/models/library_views.dart';
import '../../services/audio/player_controller.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/spectrum_bars.dart';
import '../../widgets/time_text.dart';

/// The full-window now-playing view, with the queue beside it.
///
/// The artwork is the point of this screen, so it gets as much room as the
/// window allows and the same image, blurred past recognition, fills everything
/// behind it: the release sets the colour of the whole screen rather than
/// sitting in a grey box.
class NowPlayingView extends ConsumerWidget {
  const NowPlayingView({
    super.key,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;

  /// Below this width the two panes are shown one at a time instead of side by
  /// side. Cramming both into the app's minimum window makes both unusable.
  static const _twoPaneBreakpoint = 980.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);

    if (!player.hasTrack && !player.hasQueue) {
      return const EmptyState(
        icon: Icons.queue_music_outlined,
        title: 'Nothing queued',
        message: 'Play an album or a track and it will show up here, with the '
            'rest of the queue beside it.',
      );
    }

    return ArtworkBackdrop(
      storedPath: player.current?.imagePath,
      blur: 90,
      // Light enough that the release's colours actually reach the screen --
      // the point of the backdrop is the ambiance, not a grey wash -- and heavy
      // enough that white text stays readable over bright artwork.
      overlayOpacity: 0.56,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoPane = constraints.maxWidth >= _twoPaneBreakpoint;
          if (twoPane) {
            return Row(
              children: [
                Expanded(
                  child: _NowPlayingPane(
                    onOpenArtist: onOpenArtist,
                    onOpenAlbum: onOpenAlbum,
                  ),
                ),
                const SizedBox(
                  width: 380,
                  child: _QueuePane(),
                ),
              ],
            );
          }
          return _NarrowPanes(
            onOpenArtist: onOpenArtist,
            onOpenAlbum: onOpenAlbum,
          );
        },
      ),
    );
  }
}

/// One pane at a time, for windows too narrow to hold both.
class _NarrowPanes extends StatefulWidget {
  const _NarrowPanes({this.onOpenArtist, this.onOpenAlbum});

  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;

  @override
  State<_NarrowPanes> createState() => _NarrowPanesState();
}

class _NarrowPanesState extends State<_NarrowPanes> {
  var _showQueue = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.album_outlined, size: 18),
                label: Text('Now playing'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.queue_music, size: 18),
                label: Text('Queue'),
              ),
            ],
            selected: {_showQueue},
            onSelectionChanged: (value) =>
                setState(() => _showQueue = value.first),
          ),
        ),
        Expanded(
          child: _showQueue
              ? const _QueuePane()
              : _NowPlayingPane(
                  onOpenArtist: widget.onOpenArtist,
                  onOpenAlbum: widget.onOpenAlbum,
                ),
        ),
      ],
    );
  }
}

/// Artwork, title, credits, seek bar and transport.
class _NowPlayingPane extends ConsumerWidget {
  const _NowPlayingPane({this.onOpenArtist, this.onOpenAlbum});

  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final track = player.current;
    final theme = Theme.of(context);

    if (track == null) {
      return const EmptyState(
        icon: Icons.play_circle_outline,
        title: 'Ready to play',
        message: 'The queue is loaded. Press play, or pick a track from it.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Whatever is left after the text and controls have taken their share.
        // The reserve is measured, not guessed: padding, title, credits, album
        // line, scrubber, transport and visualiser come to about this much, and
        // under-reserving pushed the visualiser below the fold.
        const chromeHeight = 400.0;
        final artSide =
            (constraints.maxHeight - chromeHeight).clamp(120.0, 460.0);

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Cross-fades between releases rather than snapping, so skipping
              // through a queue does not strobe.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                child: Artwork(
                  key: ValueKey(track.imagePath ?? track.trackId),
                  storedPath: track.imagePath,
                  size: artSide,
                  borderRadius: 16,
                  fallbackSeed: track.albumTitle ?? track.title,
                ),
              ),
              const SizedBox(height: 28),
              Text(
                track.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              _Credits(
                trackId: track.trackId,
                fallback: track.artistLine,
                onOpenArtist: onOpenArtist,
              ),
              if (track.albumTitle != null) ...[
                const SizedBox(height: 6),
                _AlbumLink(
                  title: track.albumTitle!,
                  albumId: track.albumId,
                  onOpenAlbum: onOpenAlbum,
                ),
              ],
              const SizedBox(height: 24),
              const _Scrubber(),
              const SizedBox(height: 8),
              const _Transport(),
              const SizedBox(height: 20),
              // The visualiser last, as ambience under everything else rather
              // than a widget competing for attention.
              if (player.isPlaying)
                const SizedBox(
                  height: 56,
                  child: IgnorePointer(
                    child: SpectrumBars(opacity: 0.5, mirrored: true),
                  ),
                )
              else
                const SizedBox(height: 56),
            ],
          ),
        );
      },
    );
  }
}

/// The credited artists, each its own target.
class _Credits extends ConsumerWidget {
  const _Credits({
    required this.trackId,
    required this.fallback,
    this.onOpenArtist,
  });

  final int trackId;
  final String fallback;
  final void Function(int artistId)? onOpenArtist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = ref.watch(trackRowProvider(trackId)).value;
    final theme = Theme.of(context);
    final style = theme.textTheme.titleMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final credits = row?.credits ?? const <TrackCreditRef>[];
    if (credits.isEmpty) {
      // The joined line from the player snapshot, until the credits load.
      return Text(fallback, style: style, textAlign: TextAlign.center);
    }

    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < credits.length; i++) ...[
          if (i > 0)
            Text(' · ',
                style: style?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.5),
                )),
          _Link(
            text: credits[i].creditedAs ?? credits[i].name,
            style: style,
            onTap: onOpenArtist == null
                ? null
                : () => onOpenArtist!(credits[i].artistId),
          ),
        ],
      ],
    );
  }
}

class _AlbumLink extends StatelessWidget {
  const _AlbumLink({
    required this.title,
    this.albumId,
    this.onOpenAlbum,
  });

  final String title;
  final int? albumId;
  final void Function(int albumId)? onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
    );
    return _Link(
      text: title,
      style: style,
      onTap: albumId == null || onOpenAlbum == null
          ? null
          : () => onOpenAlbum!(albumId!),
    );
  }
}

/// Text that underlines on hover when it leads somewhere.
class _Link extends StatefulWidget {
  const _Link({required this.text, this.style, this.onTap});

  final String text;
  final TextStyle? style;
  final VoidCallback? onTap;

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      widget.text,
      style: widget.style?.copyWith(
        decoration: _hovering && widget.onTap != null
            ? TextDecoration.underline
            : null,
        decorationColor: widget.style?.color,
      ),
    );
    if (widget.onTap == null) return text;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(onTap: widget.onTap, child: text),
    );
  }
}

/// The seek bar, with elapsed and remaining either side.
class _Scrubber extends ConsumerStatefulWidget {
  const _Scrubber();

  @override
  ConsumerState<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends ConsumerState<_Scrubber> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final duration = ref.watch(playerProvider.select((s) => s.duration));
    final position = ref.watch(playbackPositionProvider).value ?? Duration.zero;
    final theme = Theme.of(context);
    final totalMs = duration.inMilliseconds;

    final fraction = _dragValue ??
        (totalMs == 0
            ? 0.0
            : (position.inMilliseconds / totalMs).clamp(0.0, 1.0));
    final shown = _dragValue == null
        ? position
        : Duration(milliseconds: (_dragValue! * totalMs).round());

    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: Row(
        children: [
          Text(formatDuration(shown), style: labelStyle),
          Expanded(
            child: Slider(
              value: fraction,
              onChanged: totalMs == 0
                  ? null
                  : (next) => setState(() => _dragValue = next),
              onChangeEnd: (next) {
                ref
                    .read(playerProvider.notifier)
                    .seek(Duration(milliseconds: (next * totalMs).round()));
                setState(() => _dragValue = null);
              },
            ),
          ),
          Text(
            totalMs == 0 ? '--:--' : '-${formatDuration(duration - shown)}',
            style: labelStyle,
          ),
        ],
      ),
    );
  }
}

/// Shuffle, previous, play/pause, next, repeat — at full size.
class _Transport extends ConsumerWidget {
  const _Transport();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: player.isShuffled ? 'Restore queue order' : 'Shuffle once',
          iconSize: 24,
          onPressed: player.hasQueue
              ? () => player.isShuffled
                  ? controller.unshuffleQueue()
                  : controller.shuffleQueue()
              : null,
          icon: Icon(Icons.shuffle,
              color: player.isShuffled ? scheme.primary : null),
        ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: 'Previous',
          iconSize: 34,
          onPressed: player.hasTrack ? controller.previous : null,
          icon: const Icon(Icons.skip_previous),
        ),
        const SizedBox(width: 12),
        _BigPlayButton(
          isPlaying: player.isPlaying,
          enabled: player.hasTrack || player.hasQueue,
          onPressed: controller.togglePlayPause,
        ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: 'Next',
          iconSize: 34,
          onPressed: player.canGoNext ? () => controller.next() : null,
          icon: const Icon(Icons.skip_next),
        ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: switch (player.repeat) {
            QueueRepeat.off => 'Repeat off',
            QueueRepeat.all => 'Repeat queue',
            QueueRepeat.one => 'Repeat track',
          },
          iconSize: 24,
          onPressed: controller.cycleRepeat,
          icon: Icon(
            player.repeat == QueueRepeat.one ? Icons.repeat_one : Icons.repeat,
            color: player.repeat == QueueRepeat.off ? null : scheme.primary,
          ),
        ),
      ],
    );
  }
}

class _BigPlayButton extends StatefulWidget {
  const _BigPlayButton({
    required this.isPlaying,
    required this.enabled,
    required this.onPressed,
  });

  final bool isPlaying;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_BigPlayButton> createState() => _BigPlayButtonState();
}

class _BigPlayButtonState extends State<_BigPlayButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 220),
    vsync: this,
    value: widget.isPlaying ? 1 : 0,
  );

  @override
  void didUpdateWidget(_BigPlayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      widget.isPlaying ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.isPlaying ? 'Pause' : 'Play',
      child: Material(
        color: widget.enabled ? scheme.primary : scheme.surfaceContainerHighest,
        shape: const CircleBorder(),
        elevation: widget.enabled ? 2 : 0,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.enabled ? widget.onPressed : null,
          child: SizedBox(
            width: 68,
            height: 68,
            child: Center(
              child: AnimatedIcon(
                icon: AnimatedIcons.play_pause,
                progress: _controller,
                size: 40,
                color:
                    widget.enabled ? scheme.onPrimary : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The queue: reorderable, removable, and playable from any point.
class _QueuePane extends ConsumerWidget {
  const _QueuePane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final total = player.queue.fold(
      Duration.zero,
      (sum, entry) => sum + entry.duration,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.55),
        border: Border(
          left: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Play queue', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        '${pluralize(player.queue.length, 'track')} · '
                        '${formatDurationLong(total)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip:
                      player.isShuffled ? 'Restore order' : 'Shuffle the queue',
                  onPressed: player.hasQueue
                      ? () => player.isShuffled
                          ? controller.unshuffleQueue()
                          : controller.shuffleQueue()
                      : null,
                  icon: Icon(Icons.shuffle,
                      color: player.isShuffled ? scheme.primary : null),
                ),
                IconButton(
                  tooltip: 'Clear the queue',
                  onPressed: player.hasQueue ? controller.clearQueue : null,
                  icon: const Icon(Icons.playlist_remove),
                ),
              ],
            ),
          ),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
          Expanded(
            child: player.queue.isEmpty
                ? const EmptyState(
                    icon: Icons.queue_music_outlined,
                    title: 'The queue is empty',
                    message: 'Tracks you play or add will line up here.',
                  )
                : ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: player.queue.length,
                    // The default handles are overlaid at the trailing edge,
                    // right on top of each row's remove button. Placing the
                    // handle inside the row instead puts both within reach.
                    buildDefaultDragHandles: false,
                    // onReorderItem, not onReorder: it hands over an index
                    // already adjusted for the dragged row's removal, which is
                    // the index this list actually needs.
                    onReorderItem: (oldIndex, newIndex) {
                      final moved = player.queue[oldIndex];
                      final rest = [...player.queue]..removeAt(oldIndex);
                      controller.moveInQueue(
                        moved.itemId,
                        beforeItemId: newIndex >= rest.length
                            ? null
                            : rest[newIndex].itemId,
                      );
                    },
                    itemBuilder: (context, index) {
                      final entry = player.queue[index];
                      return _QueueRow(
                        key: ValueKey(entry.itemId),
                        entry: entry,
                        index: index,
                        isCurrent: index == player.currentIndex,
                        isPlaying: index == player.currentIndex &&
                            player.isPlaying,
                        onPlay: () => controller.playAt(index),
                        onRemove: () =>
                            controller.removeFromQueue(entry.itemId),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatefulWidget {
  const _QueueRow({
    super.key,
    required this.entry,
    required this.index,
    required this.isCurrent,
    required this.isPlaying,
    required this.onPlay,
    required this.onRemove,
  });

  final QueueEntry entry;
  final int index;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entry = widget.entry;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        color: widget.isCurrent
            ? scheme.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        child: InkWell(
          onTap: widget.onPlay,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: widget.isPlaying
                      ? Icon(Icons.graphic_eq,
                          size: 16, color: scheme.primary)
                      : Text(
                          '${widget.index + 1}',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Artwork(
                  storedPath: entry.imagePath,
                  size: 40,
                  borderRadius: 4,
                  fallbackSeed: entry.albumTitle ?? entry.title,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: widget.isCurrent
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: entry.isMissing
                              ? scheme.onSurfaceVariant
                              : null,
                        ),
                      ),
                      Text(
                        entry.artistLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatDuration(entry.duration),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                // Dimmed rather than hidden until the row is hovered. Swapping
                // it in and out, or fading it to zero, would take the control
                // out of the accessibility tree -- and a zero-area interactive
                // node is what crashed this app on the Windows a11y bridge.
                // Always present, always reachable, just quiet.
                AnimatedOpacity(
                  opacity: _hovering ? 1 : 0.28,
                  duration: const Duration(milliseconds: 120),
                  alwaysIncludeSemantics: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Remove from queue',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        onPressed: widget.onRemove,
                        icon: const Icon(Icons.close),
                      ),
                      ReorderableDragStartListener(
                        index: widget.index,
                        child: Tooltip(
                          message: 'Drag to reorder',
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 8,
                              ),
                              child: Icon(Icons.drag_handle,
                                  size: 18, color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
