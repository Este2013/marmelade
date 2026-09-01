import 'dart:async';

import 'package:flutter/material.dart';

/// Scrolls a list while something is dragged over its top or bottom edge.
///
/// Dragging cannot reach what is off the screen, and a list of categories is
/// taller than the window long before it is long enough to feel long. Without
/// this, moving a tag into a category further down means dropping it somewhere
/// wrong, scrolling, and dragging again.
///
/// The strips sense the drag but never take it. A [DragTarget] that refuses is
/// still told about every move over it, and refusing means the heading
/// underneath stays the one that would receive the drop -- so the edges can
/// overlap real targets without shadowing them.
class DragScrollEdges extends StatefulWidget {
  const DragScrollEdges({
    super.key,
    required this.controller,
    required this.child,
    this.edge = 72,
    this.speed = 420,
  });

  final ScrollController controller;
  final Widget child;

  /// How deep the sensitive band at each end is.
  final double edge;

  /// Pixels a second at the outer limit of the band.
  final double speed;

  @override
  State<DragScrollEdges> createState() => _DragScrollEdgesState();
}

class _DragScrollEdgesState extends State<DragScrollEdges> {
  Timer? _ticker;
  double _velocity = 0;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// [depth] is how far into the band the pointer is, from 0 at the inner lip
  /// to 1 at the very edge.
  ///
  /// Scaled rather than fixed, so easing towards the edge creeps and pushing
  /// right up against it moves properly. A single speed makes the list feel
  /// like it is either stuck or bolting.
  void _run(double depth, {required bool up}) {
    final wanted = widget.speed * depth.clamp(0.0, 1.0) * (up ? -1 : 1);
    _velocity = wanted;
    _ticker ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final controller = widget.controller;
      if (!controller.hasClients || _velocity == 0) return;
      final position = controller.position;
      final next = (position.pixels + _velocity * 0.016).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (next != position.pixels) controller.jumpTo(next);
    });
  }

  void _stop() {
    _velocity = 0;
    _ticker?.cancel();
    _ticker = null;
  }

  Widget _band({required bool up}) => SizedBox(
        height: widget.edge,
        child: DragTarget<Object>(
          // Never: this is a sensor, not a destination. Refusing is also what
          // leaves the drop to whatever the strip is covering.
          onWillAcceptWithDetails: (_) => false,
          onMove: (details) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            final local = box.globalToLocal(details.offset).dy;
            final depth = up
                ? (widget.edge - local) / widget.edge
                : (local - (box.size.height - widget.edge)) / widget.edge;
            _run(depth, up: up);
          },
          onLeave: (_) => _stop(),
          builder: (context, _, _) => const SizedBox.expand(),
        ),
      );

  @override
  Widget build(BuildContext context) => Stack(
        children: [
          widget.child,
          Positioned(top: 0, left: 0, right: 0, child: _band(up: true)),
          Positioned(bottom: 0, left: 0, right: 0, child: _band(up: false)),
        ],
      );
}
