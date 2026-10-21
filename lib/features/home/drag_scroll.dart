import 'dart:async';

import 'package:flutter/material.dart';

import 'home_drag.dart';

/// Scrolls a list while something is being dragged near its edges.
///
/// Without this, reordering is only possible between things already on
/// screen: a drag holds the pointer captive, so the usual ways of scrolling
/// -- the wheel, a scrollbar, a flick -- are all unavailable for exactly as
/// long as you need them. Dragging to the top or bottom edge is the gesture
/// everything else uses to mean "keep going", so that is what this listens
/// for.
///
/// Implemented as two thin drop targets rather than by watching the raw
/// pointer: a drag that is over a target is a drag the framework is already
/// telling us about, and the alternative means tracking global pointer
/// positions for a widget that mostly does nothing.
class DragScroll extends StatefulWidget {
  const DragScroll({
    super.key,
    required this.controller,
    required this.child,
    this.active = true,
  });

  final ScrollController controller;

  /// Whether anything is in flight. The strips are removed entirely when not
  /// -- never parked at zero size, which on Windows corrupts the
  /// accessibility bridge and eventually kills the process.
  final bool active;

  final Widget child;

  /// How tall the hot strip at each edge is.
  static const _edge = 56.0;

  /// Pixels per tick. Paired with [_interval] this is about 450 a second,
  /// which crosses a panel in a couple of seconds -- fast enough not to feel
  /// stuck, slow enough to stop where you meant to.
  static const _step = 14.0;
  static const _interval = Duration(milliseconds: 30);

  @override
  State<DragScroll> createState() => _DragScrollState();
}

class _DragScrollState extends State<DragScroll> {
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start(double direction) {
    _timer?.cancel();
    _timer = Timer.periodic(DragScroll._interval, (_) {
      if (!widget.controller.hasClients) return;
      final position = widget.controller.position;
      final to = (position.pixels + direction * DragScroll._step)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (to == position.pixels) return;
      widget.controller.jumpTo(to);
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Filled rather than left unpositioned: a Stack hands a loose child
        // whatever it asks for, and a scrollable that is allowed to size
        // itself to its content is a scrollable that cannot scroll.
        Positioned.fill(child: widget.child),
        if (widget.active) ...[
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: DragScroll._edge,
            child: _Edge(onEnter: () => _start(-1), onLeave: _stop),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: DragScroll._edge,
            child: _Edge(onEnter: () => _start(1), onLeave: _stop),
          ),
        ],
      ],
    );
  }
}

/// One hot strip. Refuses every drop, so a release over it falls through to
/// whatever is underneath rather than being swallowed by a scroll helper.
class _Edge extends StatelessWidget {
  const _Edge({required this.onEnter, required this.onLeave});

  final VoidCallback onEnter;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    return DragTarget<HomeDrag>(
      hitTestBehavior: HitTestBehavior.translucent,
      onWillAcceptWithDetails: (_) {
        onEnter();
        // False on purpose: this is a place to pass through, not to land.
        // A rejected target is still entered and still left -- which is all
        // the scrolling needs -- and the drop carries on to whatever is
        // underneath instead of being swallowed by a scroll helper.
        return false;
      },
      onLeave: (_) => onLeave(),
      builder: (context, candidate, rejected) => const SizedBox.expand(),
    );
  }
}
