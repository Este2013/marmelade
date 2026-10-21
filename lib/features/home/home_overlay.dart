import 'package:flutter/material.dart';

/// Opens a panel that grows out of the thing that was clicked.
///
/// Shared by every panel the home page puts on top of itself -- a collection
/// expanding, an album opened from inside one -- so they all arrive the same
/// way. The growth point is what ties the panel to the tile: a dialog that
/// simply appears in the middle leaves you working out what you just opened.
///
/// [from] is the tile's own context, measured before the route is pushed
/// while that tile is certainly still laid out.
Future<T?> showHomeOverlay<T>(
  BuildContext from, {
  required String label,
  required WidgetBuilder builder,
}) {
  final box = from.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(from).context.findRenderObject() as RenderBox?;
  var origin = Alignment.center;
  if (box != null && box.hasSize && overlay != null && overlay.hasSize) {
    final centre = box.localToGlobal(box.size.center(Offset.zero));
    origin = Alignment(
      (centre.dx / overlay.size.width) * 2 - 1,
      (centre.dy / overlay.size.height) * 2 - 1,
    );
  }

  return showGeneralDialog<T>(
    context: from,
    barrierDismissible: true,
    barrierLabel: label,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, _, _) => builder(context),
    transitionBuilder: (context, animation, _, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          // Anchored at the tile, so the panel reads as that tile opening
          // rather than as a dialog that happens to grow.
          alignment: origin,
          scale: Tween<double>(begin: 0.35, end: 1).animate(curve),
          child: child,
        ),
      );
    },
  );
}

/// The card every home panel is drawn on.
///
/// One place, so a collection and an album opened from inside it are
/// visibly the same kind of thing rather than two dialogs that happen to be
/// stacked.
class HomeOverlayCard extends StatelessWidget {
  const HomeOverlayCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 940, maxHeight: 720),
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(20),
            clipBehavior: Clip.antiAlias,
            elevation: 12,
            child: child,
          ),
        ),
      ),
    );
  }
}
