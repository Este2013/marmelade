import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../services/audio/playback_engine.dart';

/// A bar spectrum driven by the engine's FFT tap.
///
/// Drawn on a canvas rather than as widgets: sixty-four animated bars at
/// animation rate would otherwise mean sixty-four widget rebuilds per frame for
/// something purely decorative.
class SpectrumBars extends ConsumerStatefulWidget {
  const SpectrumBars({
    super.key,
    this.barCount = 48,
    this.opacity = 1,
    this.color,
    this.alignment = Alignment.bottomCenter,
    this.barSpacing = 2,
    this.minBarHeight = 2,
    this.mirrored = false,
  });

  /// How many bars to draw. The 256 FFT bins are grouped down to this many.
  final int barCount;

  final double opacity;

  /// Bar colour. Defaults to the theme's primary.
  final Color? color;

  /// Where bars grow from.
  final Alignment alignment;

  final double barSpacing;
  final double minBarHeight;

  /// When true, bars grow from the centre in both directions.
  final bool mirrored;

  @override
  ConsumerState<SpectrumBars> createState() => _SpectrumBarsState();
}

class _SpectrumBarsState extends ConsumerState<SpectrumBars> {
  /// Smoothed bar heights, 0..1.
  late List<double> _levels = List.filled(widget.barCount, 0);

  /// Slowly-falling peak markers, which make transients readable.
  late List<double> _peaks = List.filled(widget.barCount, 0);

  @override
  void didUpdateWidget(SpectrumBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.barCount != oldWidget.barCount) {
      _levels = List.filled(widget.barCount, 0);
      _peaks = List.filled(widget.barCount, 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final frame = ref.watch(spectrumProvider).value;
    if (frame != null) _absorb(frame);

    final color = widget.color ?? Theme.of(context).colorScheme.primary;

    return RepaintBoundary(
      child: CustomPaint(
        painter: _SpectrumPainter(
          levels: _levels,
          peaks: _peaks,
          color: color.withValues(alpha: widget.opacity),
          peakColor: color.withValues(alpha: widget.opacity * 0.55),
          alignment: widget.alignment,
          barSpacing: widget.barSpacing,
          minBarHeight: widget.minBarHeight,
          mirrored: widget.mirrored,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  /// Folds a new FFT frame into the smoothed levels.
  void _absorb(SpectrumFrame frame) {
    final magnitudes = frame.magnitudes;
    final bins = magnitudes.length;
    if (bins == 0) return;

    for (var i = 0; i < widget.barCount; i++) {
      // Bins are grouped logarithmically, because linear grouping puts almost
      // all of the visible movement in the first few bars and leaves the rest
      // of the display flat.
      final start = _binForBar(i, widget.barCount, bins);
      final end = _binForBar(i + 1, widget.barCount, bins);
      var peak = 0.0;
      for (var bin = start; bin < end && bin < bins; bin++) {
        final value = magnitudes[bin];
        if (value > peak) peak = value;
      }

      // A mild curve, then a tilt that lifts the quiet high end so the top
      // octaves are visible at all.
      final tilt = 1 + (i / widget.barCount) * 1.4;
      final level = math.pow(peak.clamp(0.0, 1.0), 0.6).toDouble() * tilt;
      final target = level.clamp(0.0, 1.0);

      // Rise quickly, fall slowly: the opposite reads as sluggish and mushy.
      _levels[i] = target > _levels[i]
          ? _levels[i] + (target - _levels[i]) * 0.55
          : _levels[i] + (target - _levels[i]) * 0.16;

      _peaks[i] = _levels[i] > _peaks[i]
          ? _levels[i]
          : math.max(0, _peaks[i] - 0.012);
    }
  }

  /// First FFT bin belonging to bar [index], spaced logarithmically.
  static int _binForBar(int index, int barCount, int bins) {
    if (barCount <= 1) return 0;
    final fraction = index / barCount;
    // Skip the lowest bin: it carries DC offset rather than audible content.
    const lowest = 1.0;
    final value = lowest * math.pow(bins / lowest, fraction);
    return value.floor().clamp(0, bins);
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.levels,
    required this.peaks,
    required this.color,
    required this.peakColor,
    required this.alignment,
    required this.barSpacing,
    required this.minBarHeight,
    required this.mirrored,
  });

  final List<double> levels;
  final List<double> peaks;
  final Color color;
  final Color peakColor;
  final Alignment alignment;
  final double barSpacing;
  final double minBarHeight;
  final bool mirrored;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.isEmpty) return;

    final barWidth =
        (size.width - barSpacing * (levels.length - 1)) / levels.length;
    if (barWidth <= 0) return;

    final paint = Paint()..color = color;
    final peakPaint = Paint()..color = peakColor;
    final radius = Radius.circular(math.min(barWidth / 2, 3));

    for (var i = 0; i < levels.length; i++) {
      final x = i * (barWidth + barSpacing);
      final height =
          math.max(minBarHeight, levels[i] * size.height * (mirrored ? 0.5 : 1));

      if (mirrored) {
        final centre = size.height / 2;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, centre - height, barWidth, height * 2),
            radius,
          ),
          paint,
        );
        continue;
      }

      final fromTop = alignment.y < 0;
      final rect = fromTop
          ? Rect.fromLTWH(x, 0, barWidth, height)
          : Rect.fromLTWH(x, size.height - height, barWidth, height);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paint);

      // Peak marker, only once it has separated from the bar.
      final peakHeight = peaks[i] * size.height;
      if (peakHeight > height + 3) {
        final peakRect = fromTop
            ? Rect.fromLTWH(x, peakHeight - 2, barWidth, 2)
            : Rect.fromLTWH(x, size.height - peakHeight, barWidth, 2);
        canvas.drawRect(peakRect, peakPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) => true;
}

/// A compact three-bar "now playing" indicator for list rows.
///
/// Not driven by the FFT: in a list of a thousand rows the point is to say
/// *which* row is playing, and a shared animation is both cheaper and calmer
/// than a real spectrum in every row.
class PlayingIndicator extends StatefulWidget {
  const PlayingIndicator({super.key, this.isPlaying = true, this.size = 14});

  final bool isPlaying;
  final double size;

  @override
  State<PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<PlayingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 900),
    vsync: this,
  );

  @override
  void initState() {
    super.initState();
    if (widget.isPlaying) _controller.repeat();
  }

  @override
  void didUpdateWidget(PlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      widget.isPlaying ? _controller.repeat() : _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _IndicatorPainter(
            phase: _controller.value,
            color: color,
            animate: widget.isPlaying,
          ),
        ),
      ),
    );
  }
}

class _IndicatorPainter extends CustomPainter {
  _IndicatorPainter({
    required this.phase,
    required this.color,
    required this.animate,
  });

  final double phase;
  final Color color;
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const bars = 3;
    final barWidth = size.width / (bars * 2 - 1);

    for (var i = 0; i < bars; i++) {
      // Offset phases so the bars do not move as one block.
      final offset = i / bars;
      final wave = animate
          ? (math.sin((phase + offset) * 2 * math.pi) + 1) / 2
          : 0.35;
      final height = size.height * (0.25 + wave * 0.75);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            i * barWidth * 2,
            size.height - height,
            barWidth,
            height,
          ),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_IndicatorPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.animate != animate;
}
