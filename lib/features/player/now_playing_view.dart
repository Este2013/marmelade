import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../services/audio/player_controller.dart';
import 'lyrics_pane.dart';
import '../../data/repositories/queue_repository.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/expandable_artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';

/// The now-playing shade: artwork at full size, with the queue beside it.
///
/// Drawn up over the content by the player bar rather than reached from the
/// navigation rail, because it is the player and not a place in the library.
/// That also means it deliberately repeats none of the transport controls --
/// they are a few pixels below, in the bar that opened this -- so the freed
/// space goes to the artwork instead.
///
/// It has no header of its own either. Closing it, naming it and showing or
/// hiding the queue all live in the window's caption strip, which is already at
/// the top of the screen and already where the window's own controls are. One
/// strip of controls, not two stacked on each other.
class NowPlayingView extends ConsumerWidget {
  const NowPlayingView({
    super.key,
    this.topInset = 0,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  /// Space to leave clear at the top for the window's caption strip.
  ///
  /// The shade covers the whole window and the strip is drawn over it, so
  /// without this the artwork would start underneath the window buttons.
  final double topInset;

  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;

  /// Below this width the artwork and the side pane are shown one at a time.
  ///
  /// Both at once in the app's minimum window leaves neither usable.
  static const _twoPaneBreakpoint = 980.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final queueVisible = ref.watch(queuePaneVisibleProvider);
    final lyricsVisible = ref.watch(lyricsPaneVisibleProvider);

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

          // One slot, two possible contents. Three columns in the app's
          // minimum window leaves none of them readable, and the toggles keep
          // meaning the same thing at every width because of it.
          final sideVisible = queueVisible || lyricsVisible;
          final side = lyricsVisible ? const LyricsPane() : const _QueuePane();

          return Column(
            children: [
              SizedBox(height: topInset),
              Expanded(
                child: twoPane
                    // Side by side: the queue slides in from the right edge
                    // and the artwork gives up the room as it arrives.
                    ? Row(
                        children: [
                          Expanded(child: artwork),
                          _SideSlide(
                            visible: sideVisible,
                            width: lyricsVisible ? 480 : 400,
                            child: side,
                          ),
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
                        child: sideVisible
                            ? Padding(
                                key: ValueKey(
                                  lyricsVisible ? 'lyrics' : 'queue',
                                ),
                                padding:
                                    const EdgeInsets.fromLTRB(12, 4, 12, 12),
                                child: _SideCard(child: side),
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

/// Artwork, title, credits and album -- and nothing the player bar already has.
class _NowPlayingPane extends ConsumerWidget {
  const _NowPlayingPane({this.onOpenArtist, this.onOpenAlbum});

  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;

  /// Room the block under the artwork needs, in each of its two shapes.
  ///
  /// The title is not in either of them any more -- it names the whole view
  /// from the caption strip now, and a headline repeating it here cost the
  /// artwork eighty pixels for nothing.
  static const _twoLineText = 130.0;
  static const _oneLineText = 90.0;

  /// Below this, the second line is not worth what it costs.
  ///
  /// Chosen against the picture rather than against a screen size: what
  /// matters is how much artwork is left, and a 1080x720 window maximised on
  /// a second monitor runs out of height long before it runs out of width.
  static const _comfortableSide = 460.0;

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
        double sideWith(double text) => math
            .min(constraints.maxHeight - text, constraints.maxWidth - 96)
            .clamp(120.0, 720.0);

        // Roomy first, and collapse only when the picture would suffer for
        // it: artists on their own line, the album under them, is the better
        // read when there is space for it.
        var side = sideWith(_twoLineText);
        final oneLine = side < _comfortableSide;
        if (oneLine) side = sideWith(_oneLineText);

        final albumLink = track.albumTitle == null
            ? null
            : _Link(
                // Says which shape it ended up in -- the tests read it, and
                // it is the one thing about this layout worth asserting.
                key: ValueKey(oneLine ? 'album-inline' : 'album-stacked'),
                text: track.albumTitle!,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.85),
                ),
                onTap: track.albumId == null || onOpenAlbum == null
                    ? null
                    : () => onOpenAlbum!(track.albumId!),
              );

        return SingleChildScrollView(
          // Named so a test can ask about this half of the view without
          // catching the queue beside it, which lists these same titles.
          key: const Key('now-playing-details'),
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 24),
          child: Column(
            children: [
              // Cross-fades between releases rather than snapping, so skipping
              // through a queue does not strobe.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                child: ExpandableArtwork(
                  key: ValueKey(track.imagePath ?? track.trackId),
                  storedPath: track.imagePath,
                  size: side,
                  borderRadius: 18,
                  owner: PictureOwner.track,
                  id: track.trackId,
                  title: track.title,
                  fallbackIcon: Icons.music_note_outlined,
                  // Still opens large on a click; just does not offer to
                  // change the picture. This is the view you look at while
                  // listening, and a hover button over the artwork is an
                  // editing affordance in a place nobody is editing -- the
                  // album, artist and track pages all still have it.
                  editable: false,
                ),
              ),
              SizedBox(height: oneLine ? 20 : 28),
              _Credits(
                trackId: track.trackId,
                fallback: track.artistLine,
                onOpenArtist: onOpenArtist,
                // Folded onto the artists' own line when height is short,
                // separated the way two artists already are, so one glance
                // reads "who, from what" instead of three stacked lines.
                trailing: oneLine ? albumLink : null,
              ),
              if (!oneLine && albumLink != null) ...[
                const SizedBox(height: 8),
                albumLink,
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
    this.trailing,
  });

  final int trackId;
  final String fallback;
  final void Function(int artistId)? onOpenArtist;

  /// Something to sit on the same line, after the artists and one more
  /// separator -- the album, when there is no height for its own line.
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = ref.watch(trackRowProvider(trackId)).value;
    final theme = Theme.of(context);
    final style = theme.textTheme.titleMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    final dot = Text(
      ' · ',
      style: style?.copyWith(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
      ),
    );

    final credits = row?.credits ?? const <TrackCreditRef>[];
    if (credits.isEmpty) {
      // The joined line from the player snapshot, until the credits load.
      return Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(fallback, style: style, textAlign: TextAlign.center),
          if (trailing != null) ...[dot, trailing!],
        ],
      );
    }

    // The same artist can be credited more than once on one track -- main
    // artist and composer, say -- and a link for each role would read as two
    // different people got equal billing instead of one with two roles.
    final seen = <int>{};
    final unique = [
      for (final credit in credits)
        if (seen.add(credit.artistId)) credit,
    ];

    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < unique.length; i++) ...[
          if (i > 0) dot,
          _Link(
            text: unique[i].creditedAs ?? unique[i].name,
            style: style,
            onTap: onOpenArtist == null
                ? null
                : () => onOpenArtist!(unique[i].artistId),
          ),
        ],
        if (trailing != null) ...[dot, trailing!],
      ],
    );
  }
}

/// Text that underlines on hover when it leads somewhere.
class _Link extends StatefulWidget {
  const _Link({super.key, required this.text, this.style, this.onTap});

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
class _SideSlide extends StatelessWidget {
  const _SideSlide({
    required this.visible,
    required this.width,
    required this.child,
  });

  final bool visible;
  final double width;

  /// The queue or the lyrics: one pane, two possible contents.
  final Widget child;

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
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(18),
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A side pane as a floating card, for windows too narrow to hold two.
class _SideCard extends StatelessWidget {
  const _SideCard({required this.child});

  final Widget child;

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
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        child: child,
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

/// Where the playing row sits relative to what is on screen.
enum _Playing { visible, above, below }

class _QueuePaneState extends ConsumerState<_QueuePane> {
  late final ScrollController _scroll;

  /// Recomputed on every scroll, so the button offering to go back to the
  /// playing row can appear at the end it actually went off.
  var _playing = _Playing.visible;

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
    _scroll.addListener(_syncPlayingPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (_scroll.offset > max) _scroll.jumpTo(max);
      _syncPlayingPosition();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_syncPlayingPosition);
    _scroll.dispose();
    super.dispose();
  }

  /// Where the row at [index] sits relative to the viewport.
  _Playing _whereIs(int index) {
    if (index < 0 || !_scroll.hasClients) return _Playing.visible;
    final top = index * _QueuePane.rowExtent;
    final viewTop = _scroll.offset;
    final viewBottom = viewTop + _scroll.position.viewportDimension;
    // Half a row's worth of overlap counts as visible: a row peeking in at
    // the edge is on screen as far as anybody looking at it is concerned.
    if (top + _QueuePane.rowExtent / 2 <= viewTop) return _Playing.above;
    if (top + _QueuePane.rowExtent / 2 >= viewBottom) return _Playing.below;
    return _Playing.visible;
  }

  void _syncPlayingPosition() {
    final next = _whereIs(ref.read(playerProvider).currentIndex);
    if (next != _playing && mounted) setState(() => _playing = next);
  }

  /// Reacts to the viewport itself changing shape -- the window being
  /// resized, principally -- rather than to a scroll or a track change.
  ///
  /// [_scroll]'s own listener only fires on an offset change, so a resize
  /// that left the offset untouched but moved the playing row relative to
  /// the (now different-sized) viewport went unnoticed entirely: the "jump
  /// to playing" button could point the wrong way, or fail to appear for a
  /// row the resize had actually pushed off screen. If the row was visible
  /// before the resize, it is nudged back into view rather than left behind
  /// for the button to fix; if it already was not, only the button's own
  /// direction is corrected.
  void _syncAfterResize() {
    if (!_scroll.hasClients) return;
    final index = ref.read(playerProvider).currentIndex;
    final wasVisible = _playing == _Playing.visible;
    var next = _whereIs(index);

    if (wasVisible && next != _Playing.visible && index >= 0) {
      final top = index * _QueuePane.rowExtent;
      final viewport = _scroll.position.viewportDimension;
      final target = (next == _Playing.above
              ? top
              : top + _QueuePane.rowExtent - viewport)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(target);
      next = _whereIs(index);
    }

    if (next != _playing && mounted) setState(() => _playing = next);
  }

  /// Keeps the playing row where it is on screen as the queue moves under it.
  ///
  /// Only for a step to the next or previous track, and only when the row that
  /// was playing could be seen. Following a jump -- someone clicking a row
  /// eight down -- would drag the list eight rows to put that one where the
  /// old one had been, which is a lurch, not a follow. And following a track
  /// change while the queue is scrolled somewhere else entirely would yank
  /// the list out from under whatever is being read; that is what the button
  /// is for instead.
  void _followTrackChange(int? previous, int next) {
    if (previous == null || !_scroll.hasClients) return;
    final step = next - previous;
    if (step.abs() != 1) return;
    if (_whereIs(previous) != _Playing.visible) return;

    final target = (_scroll.offset + step * _QueuePane.rowExtent)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  /// Puts the playing row at the top, the way opening the pane does.
  void _scrollToPlaying() {
    if (!_scroll.hasClients) return;
    final index = ref.read(playerProvider).currentIndex;
    if (index < 0) return;
    _scroll.animateTo(
      (index * _QueuePane.rowExtent).clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider);
    // Listened rather than compared against a remembered index: this pane is
    // rebuilt for plenty of reasons that are not a track change, and acting
    // on the ones that are is exactly what listen is for.
    ref.listen(
      playerProvider.select((s) => s.currentIndex),
      (previous, next) {
        _followTrackChange(previous, next);
        // After the follow, so the button reflects where the row ended up.
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _syncPlayingPosition());
      },
    );
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
              : Stack(
                  children: [
                    Positioned.fill(
                      child: NotificationListener<ScrollMetricsNotification>(
                        // Fires when the viewport's own dimensions change --
                        // a window resize, chiefly -- without a scroll
                        // offset change to trigger _scroll's own listener.
                        onNotification: (_) {
                          WidgetsBinding.instance
                              .addPostFrameCallback((_) => _syncAfterResize());
                          return false;
                        },
                        child: _queueList(player, controller),
                      ),
                    ),
                    // At the end it went off, pointing the way back, so the
                    // button says which direction it is without reading it.
                    if (_playing != _Playing.visible && player.currentIndex >= 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: _playing == _Playing.above ? 8 : null,
                        bottom: _playing == _Playing.below ? 28 : null,
                        child: Center(
                          child: _ScrollToPlaying(
                            above: _playing == _Playing.above,
                            onPressed: _scrollToPlaying,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _queueList(PlayerSnapshot player, PlayerController controller) {
    return ReorderableListView.builder(
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
    );
  }
}

/// A way back to the row that is playing, once it has scrolled out of sight.
class _ScrollToPlaying extends StatelessWidget {
  const _ScrollToPlaying({required this.above, required this.onPressed});

  /// True when the playing row is off the top, which decides both which way
  /// the arrow points and which edge this sits at.
  final bool above;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(above ? Icons.arrow_upward : Icons.arrow_downward, size: 16),
      label: const Text('Jump to playing'),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        elevation: 3,
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
