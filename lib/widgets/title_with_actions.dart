import 'package:flutter/material.dart';

/// A page's name, with the actions that act on *it*, revealed on hover.
///
/// Detail pages used to keep Edit -- and an artist's links -- up in the
/// window's caption strip. That put them a long way from the thing they
/// change, and made them compete with Back and the window buttons for the
/// same strip. Here they sit beside the name they edit, and stay out of sight
/// until the pointer is on that row, so the page still reads as a name and a
/// picture rather than as a toolbar.
///
/// The buttons are faded rather than added and removed. Adding an interactive
/// widget on every hover churns the Windows accessibility tree, which this app
/// has crashed over before (see `docs/ARCHITECTURE.md`), and a control that is
/// always in the tree can be reached by keyboard and screen reader without
/// needing a pointer to exist first. They stay clickable while invisible,
/// matching the album grid's play button and the tag line's add chip -- the
/// cost is a click landing on an unseen button, and the actions here all open
/// something that can be closed again.
class TitleWithActions extends StatefulWidget {
  const TitleWithActions({
    super.key,
    required this.title,
    required this.actions,
  });

  /// Usually the big name itself, styled by the caller: this widget decides
  /// where it sits, not what it looks like.
  final Widget title;

  /// Shown after [title]. An empty list is fine -- the row then behaves
  /// exactly as the bare title did.
  final List<Widget> actions;

  @override
  State<TitleWithActions> createState() => _TitleWithActionsState();
}

class _TitleWithActionsState extends State<TitleWithActions> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (widget.actions.isEmpty) return widget.title;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Row(
        children: [
          // Flexible rather than Expanded: a short name takes the width it
          // needs and the buttons follow immediately, while a long one still
          // wraps inside the space available instead of overflowing.
          Flexible(child: widget.title),
          const SizedBox(width: 6),
          AnimatedOpacity(
            opacity: _hovering ? 1 : 0,
            duration: const Duration(milliseconds: 140),
            alwaysIncludeSemantics: true,
            child: Row(mainAxisSize: MainAxisSize.min, children: widget.actions),
          ),
        ],
      ),
    );
  }
}
