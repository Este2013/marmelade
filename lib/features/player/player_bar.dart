import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../services/audio/player_controller.dart';
import '../../widgets/artwork.dart';
import '../../widgets/spectrum_bars.dart';
import '../../widgets/time_text.dart';

/// The persistent player strip along the bottom of the window.
///
/// Tapping anywhere that is not a control opens the full now-playing view, so
/// the bar doubles as the entry point to it.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({
    super.key,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onOpenQueue,
  });

  /// Whether the now-playing shade is currently drawn up over the content.
  final bool expanded;

  /// Opens the shade, or closes it when it is already up.
  final VoidCallback onToggleExpanded;

  /// Opens the shade with the queue panel showing.
  final VoidCallback onOpenQueue;

  static const height = 84.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainer,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SeekBar(),
          SizedBox(
            height: height,
            child: Stack(
              children: [
                // The visualiser sits behind the controls as a semi-transparent
                // band, so it reads as ambience rather than as a widget
                // competing with the buttons.
                if (player.isPlaying)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: SpectrumBars(
                          opacity: 0.22,
                          alignment: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: _NowPlayingSummary(onTap: onToggleExpanded),
                      ),
                      const _TransportControls(),
                      Expanded(
                        child: _RightControls(
                          expanded: expanded,
                          onToggleExpanded: onToggleExpanded,
                          onOpenQueue: onOpenQueue,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Title, artist and artwork for the current track.
class _NowPlayingSummary extends ConsumerWidget {
  const _NowPlayingSummary({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final track = player.current;
    final theme = Theme.of(context);

    if (track == null) {
      return Row(
        children: [
          const SizedBox(width: 4),
          Icon(
            Icons.music_note_outlined,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Text(
            player.hasQueue ? 'Ready to play' : 'Nothing playing',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Artwork(
              storedPath: track.imagePath,
              size: 56,
              borderRadius: 6,
              fallbackSeed: track.albumTitle ?? track.title,
              heroTag: 'now-playing-art',
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.artistLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// Previous, play/pause, next.
class _TransportControls extends ConsumerWidget {
  const _TransportControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Shuffle the queue once',
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
          tooltip: 'Previous',
          onPressed: player.hasTrack ? controller.previous : null,
          icon: const Icon(Icons.skip_previous),
        ),
        const SizedBox(width: 4),
        _PlayPauseButton(
          isPlaying: player.isPlaying,
          enabled: player.hasTrack || player.hasQueue,
          onPressed: controller.togglePlayPause,
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Next',
          onPressed: player.canGoNext ? () => controller.next() : null,
          icon: const Icon(Icons.skip_next),
        ),
        IconButton(
          tooltip: switch (player.repeat) {
            QueueRepeat.off => 'Repeat off',
            QueueRepeat.all => 'Repeat queue',
            QueueRepeat.one => 'Repeat track',
          },
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

/// A filled play button whose glyph animates between play and pause.
class _PlayPauseButton extends StatefulWidget {
  const _PlayPauseButton({
    required this.isPlaying,
    required this.enabled,
    required this.onPressed,
  });

  final bool isPlaying;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 220),
    vsync: this,
    value: widget.isPlaying ? 1 : 0,
  );

  @override
  void didUpdateWidget(_PlayPauseButton oldWidget) {
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
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.enabled ? widget.onPressed : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: AnimatedIcon(
                icon: AnimatedIcons.play_pause,
                progress: _controller,
                size: 28,
                color: widget.enabled
                    ? scheme.onPrimary
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Volume, queue and expand controls.
class _RightControls extends ConsumerWidget {
  const _RightControls({
    required this.expanded,
    required this.onToggleExpanded,
    required this.onOpenQueue,
  });

  final bool expanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onOpenQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const _PositionLabel(),
        const SizedBox(width: 12),
        _VolumeControl(value: player.volume, onChanged: controller.setVolume),
        IconButton(
          tooltip: 'Play queue',
          onPressed: onOpenQueue,
          icon: Badge(
            isLabelVisible: player.queue.length > 1,
            label: Text('${player.queue.length}'),
            child: const Icon(Icons.queue_music),
          ),
        ),
        IconButton(
          tooltip: expanded ? 'Close now playing' : 'Open now playing',
          // Enabled whenever there is anything to look at. Requiring a loaded
          // track meant a restored queue could not be opened before pressing
          // play, which is the one moment you most want to look at it.
          onPressed: player.hasTrack || player.hasQueue
              ? onToggleExpanded
              : null,
          // Rotates rather than swapping glyphs, so the button reads as the
          // same control in two states instead of two different buttons.
          icon: AnimatedRotation(
            turns: expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: const Icon(Icons.expand_less),
          ),
        ),
      ],
    );
  }
}

/// "1:23 / 4:56", updated from the position stream only.
class _PositionLabel extends ConsumerWidget {
  const _PositionLabel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duration = ref.watch(playerProvider.select((s) => s.duration));
    final position = ref.watch(playbackPositionProvider).value ?? Duration.zero;
    if (duration == Duration.zero) return const SizedBox.shrink();

    return Text(
      '${formatDuration(position)} / ${formatDuration(duration)}',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}

/// A speaker icon that expands into a slider on hover.
class _VolumeControl extends StatefulWidget {
  const _VolumeControl({required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Row(
        children: [
          IconButton(
            tooltip: widget.value == 0 ? 'Unmute' : 'Mute',
            onPressed: () => widget.onChanged(widget.value == 0 ? 0.7 : 0),
            icon: Icon(switch (widget.value) {
              0 => Icons.volume_off,
              < 0.4 => Icons.volume_down,
              _ => Icons.volume_up,
            }),
          ),
          // Expanding on hover keeps the bar uncluttered while leaving the
          // slider one movement away rather than behind a menu.
          //
          // The collapsed state must leave the slider out of the tree, not
          // keep it at zero width. A zero-area Slider is a control that
          // cannot be seen, pointed at or described, and Windows'
          // accessibility bridge rejects the node it produces: the update is
          // dropped with "will not be in the tree and is not the new root",
          // the bridge's tree diverges from Flutter's, and the process dies
          // in native code on the next full semantics rebuild -- which is
          // what dragging the window to another monitor triggers. The
          // symptom was a hard, silent crash with nothing in the Dart log.
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: _hovering
                ? SizedBox(
                    width: 96,
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                      ),
                      child: Slider(
                        value: widget.value,
                        onChanged: widget.onChanged,
                      ),
                    ),
                  )
                : const SizedBox(width: 0, height: 24),
          ),
        ],
      ),
    );
  }
}

/// The scrub bar across the top of the player.
class _SeekBar extends ConsumerStatefulWidget {
  const _SeekBar();

  @override
  ConsumerState<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<_SeekBar> {
  /// Set while dragging, so the thumb follows the pointer instead of snapping
  /// back to whatever the engine last reported.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final duration = ref.watch(playerProvider.select((s) => s.duration));
    final position = ref.watch(playbackPositionProvider).value ?? Duration.zero;
    final scheme = Theme.of(context).colorScheme;

    final totalMs = duration.inMilliseconds;
    final value =
        _dragValue ??
        (totalMs == 0
            ? 0.0
            : (position.inMilliseconds / totalMs).clamp(0.0, 1.0));

    return SizedBox(
      height: 12,
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 3,
          thumbShape: RoundSliderThumbShape(
            enabledThumbRadius: _dragValue == null ? 0 : 7,
            disabledThumbRadius: 0,
          ),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
          activeTrackColor: scheme.primary,
          inactiveTrackColor: scheme.surfaceContainerHighest,
          padding: EdgeInsets.zero,
        ),
        child: Slider(
          value: value,
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
    );
  }
}
