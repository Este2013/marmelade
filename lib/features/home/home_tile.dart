import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/home_views.dart';
import 'home_artwork.dart';

/// One tile in a home grid.
///
/// Shaped after the albums grid on purpose: cover, a lift on hover, a play
/// button revealed in the corner, the name underneath. Somebody who has used
/// Albums already knows how to use this, and a home page that invented its own
/// tile would be asking them to learn the same thing twice.
///
/// The hover lift is scoped to the artwork alone and the play button is
/// hoisted out of it. A `Transform` moves the semantics geometry of everything
/// inside it on every frame, which on Flutter Windows floods the accessibility
/// bridge -- measured at 316 errors against a baseline of 2 when the album
/// tile had its play button inside the scale. The artwork has no semantics of
/// its own, so scaling it costs nothing.
class HomeTile extends ConsumerStatefulWidget {
  const HomeTile({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onPlay,
    this.onMenu,
  });

  final HomeItemView item;

  /// Opening a collection expands it; opening anything else goes to its page.
  final VoidCallback onOpen;

  final VoidCallback onPlay;

  /// The right-click menu, built when it opens.
  ///
  /// Where removing lives now that the page has no arranging mode: an X in
  /// the corner of every tile was a permanent reminder of a thing almost
  /// nobody is about to do, and the menu is where the rest of the app already
  /// puts it.
  final void Function(Offset at)? onMenu;

  @override
  ConsumerState<HomeTile> createState() => _HomeTileState();
}

class _HomeTileState extends ConsumerState<HomeTile> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;
    final round = item.kind.isRound;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onOpen,
        onSecondaryTapUp: widget.onMenu == null
            ? null
            : (details) => widget.onMenu!(details.globalPosition),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedScale(
                    scale: _hovering ? 1.03 : 1,
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(round ? 999 : 10),
                        boxShadow: _hovering
                            ? [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.32),
                                  blurRadius: 18,
                                  offset: const Offset(0, 6),
                                ),
                              ]
                            : const [],
                      ),
                      child: HomeArtwork(item: item),
                    ),
                  ),

                  // A collection says so even before it is hovered: a tile that
                  // opens into more tiles behaves differently from one that
                  // goes to a page, and finding that out by clicking is a
                  // worse way to learn it.
                  //
                  // Shown while arranging too, where it matters more rather
                  // than less: a collection is the one tile a drag can be dropped
                  // *into*, so hiding the mark would hide the target.
                  if (item.isCollection)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: _Pip(
                        icon: Icons.unfold_more,
                        tooltip: '${item.children.length} inside',
                      ),
                    ),

                  // Opacity, never `onPressed: null`: toggling a button
                  // between enabled and disabled rewrites its semantics node
                  // rather than updating it, which is the same bridge problem
                  // as the transform. alwaysIncludeSemantics keeps it
                  // reachable without a mouse.
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: AnimatedOpacity(
                      opacity: _hovering ? 1 : 0,
                      duration: const Duration(milliseconds: 140),
                      alwaysIncludeSemantics: true,
                      child: _PlayButton(
                        onPressed: widget.onPlay,
                        label: 'Play ${item.title}',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: round ? TextAlign.center : TextAlign.start,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (item.subtitle != null)
              Text(
                item.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: round ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small badge in a tile's corner.
class _Pip extends StatelessWidget {
  const _Pip({required this.icon, required this.tooltip});

  final IconData icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 14, color: scheme.onSurface),
      ),
    );
  }
}

/// The round play affordance, matching the albums grid's.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.onPressed, required this.label});

  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      shape: const CircleBorder(),
      color: scheme.primary,
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Tooltip(
          message: label,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(Icons.play_arrow, size: 20, color: scheme.onPrimary),
          ),
        ),
      ),
    );
  }
}

/// One row in a home list.
///
/// The list layout is for sections where the name matters more than the
/// picture -- a run of songs, a set of playlists -- so artwork shrinks to a
/// thumbnail and the title gets the width.
class HomeRow extends StatefulWidget {
  const HomeRow({
    super.key,
    required this.item,
    required this.onOpen,
    required this.onPlay,
    this.onMenu,
  });

  final HomeItemView item;
  final VoidCallback onOpen;
  final VoidCallback onPlay;
  final void Function(Offset at)? onMenu;

  @override
  State<HomeRow> createState() => _HomeRowState();
}

class _HomeRowState extends State<HomeRow> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        color: _hovering
            ? theme.colorScheme.surfaceContainerHighest
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onOpen,
          onSecondaryTapUp: widget.onMenu == null
              ? null
              : (details) => widget.onMenu!(details.globalPosition),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                HomeArtwork(item: item, size: 44, radius: 6),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (item.subtitle != null)
                        Text(
                          item.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                  AnimatedOpacity(
                    opacity: _hovering ? 1 : 0,
                    duration: const Duration(milliseconds: 140),
                    alwaysIncludeSemantics: true,
                    child: IconButton(
                      tooltip: 'Play ${item.title}',
                      onPressed: widget.onPlay,
                      icon: const Icon(Icons.play_arrow),
                    ),
                  ),
                if (item.isCollection)
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
