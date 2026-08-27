import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/repositories/queue_repository.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';

/// The now-playing shade: artwork at full size, with the queue beside it.
///
/// Drawn up over the content by the player bar rather than reached from the
/// navigation rail, because it is the player and not a place in the library.
/// That also means it deliberately repeats none of the transport controls --
/// they are a few pixels below, in the bar that opened this -- so the freed
/// space goes to the artwork instead.
class NowPlayingView extends ConsumerWidget {
  const NowPlayingView({
    super.key,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onClose,
  });

  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;

  /// Closes the shade.
  final VoidCallback? onClose;

  /// Below this width the artwork and the queue are shown one at a time.
  ///
  /// Both at once in the app's minimum window leaves neither usable.
  static const _twoPaneBreakpoint = 980.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final queueVisible = ref.watch(queuePaneVisibleProvider);

    return ArtworkBackdrop(
      storedPath: player.current?.imagePath,
      blur: 90,
      // Light enough that the release's colours actually reach the screen --
      // the point of the backdrop is the ambiance, not a grey wash -- and heavy
      // enough that text stays readable over bright artwork.
      overlayOpacity: 0.56,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // One toggle covers both layouts: on a wide window it adds or removes
          // the queue beside the artwork, on a narrow one it swaps between
          // them. Either way, "show the queue" means the same thing.
          final twoPane = constraints.maxWidth >= _twoPaneBreakpoint;

          final artwork = _NowPlayingPane(
            onOpenArtist: onOpenArtist,
            onOpenAlbum: onOpenAlbum,
          );

          return Column(
            children: [
              _ShadeBar(
                queueVisible: queueVisible,
                queueLength: player.queue.length,
                onToggleQueue: () =>
                    ref.read(queuePaneVisibleProvider.notifier).toggle(),
                onClose: onClose,
              ),
              Expanded(
                child: twoPane
                    // Side by side: the queue slides in from the right edge
                    // and the artwork gives up the room as it arrives.
                    ? Row(
                        children: [
                          Expanded(child: artwork),
                          _QueueSlide(visible: queueVisible, width: 400),
                        ],
                      )
                    // Too narrow for two: the queue takes the whole pane, so
                    // it cross-fades with the artwork instead of sliding in
                    // beside it, and floats as a rounded card rather than
                    // butting a bare strip of colour up against the header.
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        child: queueVisible
                            ? const Padding(
                                key: ValueKey('queue'),
                                padding: EdgeInsets.fromLTRB(12, 4, 12, 12),
                                child: _QueueCard(),
                              )
                            : KeyedSubtree(
                                key: const ValueKey('artwork'),
                                child: artwork,
                              ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The shade's own thin header: close on the left, queue toggle on the right.
class _ShadeBar extends StatelessWidget {
  const _ShadeBar({
    required this.queueVisible,
    required this.queueLength,
    required this.onToggleQueue,
    this.onClose,
  });

  final bool queueVisible;
  final int queueLength;
  final VoidCallback onToggleQueue;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close now playing',
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
          const SizedBox(width: 4),
          Text(
            'Now playing',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          IconButton(
            // The count lives in the tooltip rather than a badge: a permanent
            // red dot on a control that is not a notification reads as an
            // alert about nothing.
            tooltip: queueVisible
                ? 'Hide the queue'
                : 'Show the queue (${pluralize(queueLength, 'track')})',
            isSelected: queueVisible,
            onPressed: onToggleQueue,
            icon: const Icon(Icons.queue_music),
          ),
        ],
      ),
    );
  }
}

/// Artwork, title, credits and album -- and nothing the player bar already has.
class _NowPlayingPane extends ConsumerWidget {
  const _NowPlayingPane({this.onOpenArtist, this.onOpenAlbum});

  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;

  /// Room the text below the artwork needs, at most.
  static const _textHeight = 190.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerProvider.select((s) => s.current));
    final hasQueue = ref.watch(playerProvider.select((s) => s.hasQueue));
    final theme = Theme.of(context);

    if (track == null) {
      return EmptyState(
        icon: hasQueue ? Icons.play_circle_outline : Icons.queue_music_outlined,
        title: hasQueue ? 'Ready to play' : 'Nothing queued',
        message: hasQueue
            ? 'The queue is loaded. Press play below, or pick a track from it.'
            : 'Play an album or a track and it will show up here.',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Square, bounded by whichever axis runs out first. With no transport
        // or scrubber to make room for, this is nearly the whole pane -- which
        // is the point of opening the shade at all.
        final side = math
            .min(constraints.maxHeight - _textHeight, constraints.maxWidth - 96)
            .clamp(120.0, 720.0);

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 24),
          child: Column(
            children: [
              // Cross-fades between releases rather than snapping, so skipping
              // through a queue does not strobe.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                child: Artwork(
                  key: ValueKey(track.imagePath ?? track.trackId),
                  storedPath: track.imagePath,
                  size: side,
                  borderRadius: 18,
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
                const SizedBox(height: 8),
                _Link(
                  text: track.albumTitle!,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.85),
                  ),
                  onTap: track.albumId == null || onOpenAlbum == null
                      ? null
                      : () => onOpenAlbum!(track.albumId!),
                ),
              ],
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
            Text(
              ' · ',
              style: style?.copyWith(
                color:
                    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
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
      textAlign: TextAlign.center,
      style: widget.style?.copyWith(
        decoration:
            _hovering && widget.onTap != null ? TextDecoration.underline : null,
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

/// The queue panel, sliding in from the right beside the artwork.
///
/// A clip whose width is animated, rather than a translation: the artwork pane
/// gives up its room as the panel arrives, so nothing is ever drawn over.
class _QueueSlide extends StatelessWidget {
  const _QueueSlide({required this.visible, required this.width});

  final bool visible;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return TweenAnimationBuilder<double>(
      // begin and end match on purpose. A tween's begin is used only on the
      // very first build, so this mounts at its final width with no animation
      // -- the shade is already rising at that moment -- and animates from
      // wherever it is on every toggle after.
      tween: Tween(begin: visible ? 1 : 0, end: visible ? 1 : 0),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      builder: (context, progress, _) {
        if (progress == 0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: progress,
            child: SizedBox(
              width: width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.5),
                  // Rounded where it meets the shade's header, square where it
                  // meets the window edge, so it reads as a panel that slid
                  // in rather than a block that appeared.
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(18),
                  ),
                  border: Border(
                    left: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                  ),
                ),
                child: const ClipRRect(
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(18),
                  ),
                  child: _QueuePane(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The queue as a floating card, for windows too narrow to hold two panes.
class _QueueCard extends StatelessWidget {
  const _QueueCard();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: const ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(18)),
        child: _QueuePane(),
      ),
    );
  }
}

/// The queue: reorderable, removable, and playable from any point.
class _QueuePane extends ConsumerStatefulWidget {
  const _QueuePane();

  /// Height of one row, fixed so the opening scroll offset is exact.
  ///
  /// A 40px thumbnail with 8px above and below. Declaring it also lets the list
  /// skip measuring every row it scrolls past.
  static const rowExtent = 56.0;

  @override
  ConsumerState<_QueuePane> createState() => _QueuePaneState();
}

class _QueuePaneState extends ConsumerState<_QueuePane> {
  late final ScrollController _scroll;

  @override
  void initState() {
    super.initState();
    // Opens with the current track at the top. A queue of two hundred tracks
    // otherwise opens at the beginning, which is nowhere near where you are.
    final index = ref.read(playerProvider).currentIndex;
    _scroll = ScrollController(
      initialScrollOffset:
          index <= 0 ? 0 : index * _QueuePane.rowExtent,
    );
    // The offset may be past the end of a short queue, and maxScrollExtent is
    // not known until the list has been laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (_scroll.offset > max) _scroll.jumpTo(max);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final total = player.queue.fold(
      Duration.zero,
      (sum, entry) => sum + entry.duration,
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 10),
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
                icon: Icon(
                  Icons.shuffle,
                  color: player.isShuffled ? scheme.primary : null,
                ),
              ),
              IconButton(
                tooltip: 'Clear the queue',
                onPressed: player.hasQueue ? controller.clearQueue : null,
                icon: const Icon(Icons.playlist_remove),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
        Expanded(
          child: player.queue.isEmpty
              ? const EmptyState(
                  icon: Icons.queue_music_outlined,
                  title: 'The queue is empty',
                  message: 'Tracks you play or add will line up here.',
                )
              : ReorderableListView.builder(
                  scrollController: _scroll,
                  itemExtent: _QueuePane.rowExtent,
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: player.queue.length,
                  // The default handles are overlaid at the trailing edge,
                  // right on top of each row's remove button. Placing the
                  // handle inside the row instead puts both within reach.
                  buildDefaultDragHandles: false,
                  // onReorderItem, not the deprecated onReorder: it hands over
                  // an index already adjusted for the dragged row's removal,
                  // which is the index this list actually needs.
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
                      isPlaying:
                          index == player.currentIndex && player.isPlaying,
                      onPlay: () => controller.playAt(index),
                      onRemove: () => controller.removeFromQueue(entry.itemId),
                    );
                  },
                ),
        ),
      ],
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
                      ? Icon(Icons.graphic_eq, size: 16, color: scheme.primary)
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
                          color:
                              entry.isMissing ? scheme.onSurfaceVariant : null,
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
                // these in and out, or fading them to zero, would take the
                // controls out of the accessibility tree -- and a zero-area
                // interactive node is what crashed this app on the Windows
                // accessibility bridge. Always present, always reachable, just
                // quiet.
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
                              child: Icon(
                                Icons.drag_handle,
                                size: 18,
                                color: scheme.onSurfaceVariant,
                              ),
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
