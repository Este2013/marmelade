import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../data/repositories/home_repository.dart';
import '../../domain/models/home_views.dart';

/// Something on its way onto, or around, the home page.
///
/// One type for both journeys because every drop target has to accept both:
/// an album dragged in from the library and a tile dragged from two rows
/// over mean the same thing once they land, and a target that knew the
/// difference would be two targets that could disagree.
sealed class HomeDrag {
  const HomeDrag();

  /// What the drag chip says.
  String get title;

  /// Whether [candidate] sits somewhere inside what is being dragged.
  ///
  /// Always false for something arriving from the library, which is not on
  /// the page yet and so contains nothing on it.
  bool contains(HomeItemView candidate) => false;
}

/// A tile already on the page, being moved.
class HomeMove extends HomeDrag {
  const HomeMove({required this.item, required this.sectionId});

  final HomeItemView item;
  final int sectionId;

  @override
  String get title => item.title;

  /// Checked in the UI as well as in the repository, which already refuses
  /// the move: refusing silently is the right backstop, but a drop target
  /// that lights up and then does nothing reads as a bug. The two guards
  /// answer different questions -- "may this happen" and "should this look
  /// like it can happen".
  @override
  bool contains(HomeItemView candidate) {
    if (candidate.id == item.id) return true;
    bool walk(List<HomeItemView> children, int depth) {
      if (depth > 8) return false;
      for (final child in children) {
        if (child.id == candidate.id) return true;
        if (walk(child.children, depth + 1)) return true;
      }
      return false;
    }

    return walk(item.children, 0);
  }
}

/// Something from the library, not yet on the page.
///
/// Carries the title so a drag chip and a newly created section can be
/// named without a round trip to whichever table the id belongs to.
class HomeAdd extends HomeDrag {
  const HomeAdd({
    required this.kind,
    required this.refId,
    required this.title,
  });

  final HomeItemKind kind;
  final int refId;

  @override
  final String title;
}

/// Where a drop would land.
enum HomeDropMode {
  /// Inserted ahead of the item being hovered.
  before,

  /// Put inside the collection being hovered.
  into,

  /// Wrapped together with the item being hovered into a new collection.
  ///
  /// The natural reading of dropping one thing squarely on top of another
  /// when neither is a container yet: the two belong together, so make
  /// somewhere for them to be together.
  combine,
}

/// Wraps a tile or row so it can be picked up and dropped on.
///
/// One widget for both halves of the gesture because every target is also a
/// source: anything on the page can be dragged, and anything can be dropped
/// near. Keeping them together is what guarantees a tile cannot accidentally
/// become one without the other.
///
/// The mode is decided by *where* on the target the pointer is, not by a
/// modifier key: the leading edge inserts before, and the middle of a collection
/// drops inside it. That keeps reordering a collection among its neighbours
/// possible, which a plain "drop on a collection means into it" rule would make
/// impossible -- there would be nowhere left to aim.
class HomeDraggable extends ConsumerStatefulWidget {
  const HomeDraggable({
    super.key,
    required this.item,
    required this.sectionId,
    required this.enabled,
    required this.axis,
    required this.onBefore,
    required this.onInto,
    required this.onCombine,
    required this.child,
    required this.preview,
  });

  final HomeItemView item;
  final int sectionId;

  /// Arranging mode. Off, this is an ordinary widget with no gestures of its
  /// own, so a plain click keeps behaving as it always did.
  final bool enabled;

  /// Which way the surrounding run flows, which decides whether the
  /// insertion marker is a vertical bar or a horizontal one.
  final Axis axis;

  final void Function(HomeDrag dragged) onBefore;
  final void Function(HomeDrag dragged) onInto;

  /// Wrap this item and the dropped one in a new collection.
  final void Function(HomeDrag dragged) onCombine;

  final Widget child;

  /// What follows the pointer. Deliberately small and plain -- a full-size
  /// tile under the cursor hides the thing being aimed at.
  final Widget preview;

  @override
  ConsumerState<HomeDraggable> createState() => _HomeDraggableState();
}

class _HomeDraggableState extends ConsumerState<HomeDraggable> {
  HomeDropMode? _hovering;

  /// Proportion of the target's leading edge that means "insert before".
  ///
  /// Only applies to a collection, which is the one kind with two possible
  /// meanings. Everything else is "before" wherever it is hit.
  static const _edgeBand = 0.3;

  HomeDropMode _modeFor(HomeDrag dragged, Offset globalPosition) {
    // A collection cannot go inside itself or its own descendant; aiming at
    // the middle of one still has to mean something, so it falls back to
    // before rather than to nothing.
    if (dragged.contains(widget.item)) return HomeDropMode.before;

    final box = context.findRenderObject() as RenderBox?;
    final middle = widget.item.isCollection
        ? HomeDropMode.into
        : HomeDropMode.combine;
    if (box == null || !box.hasSize) return middle;
    final local = box.globalToLocal(globalPosition);
    final along = widget.axis == Axis.horizontal ? local.dx : local.dy;
    final extent =
        widget.axis == Axis.horizontal ? box.size.width : box.size.height;
    if (extent <= 0) return middle;
    return along < extent * _edgeBand ? HomeDropMode.before : middle;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final scheme = Theme.of(context).colorScheme;
    final payload = HomeMove(item: widget.item, sectionId: widget.sectionId);

    return DragTarget<HomeDrag>(
      onWillAcceptWithDetails: (details) {
        final data = details.data;
        if (data is HomeMove && data.item.id == widget.item.id) return false;
        // Dropping a collection onto something inside itself would detach the
        // branch; the repository refuses it, so do not light up for it.
        if (details.data.contains(widget.item) &&
            _modeFor(details.data, details.offset) == HomeDropMode.into) {
          return false;
        }
        setState(() => _hovering = _modeFor(details.data, details.offset));
        return true;
      },
      onMove: (details) {
        final mode = _modeFor(details.data, details.offset);
        if (mode != _hovering) setState(() => _hovering = mode);
      },
      onLeave: (_) => setState(() => _hovering = null),
      onAcceptWithDetails: (details) {
        final mode = _modeFor(details.data, details.offset);
        setState(() => _hovering = null);
        switch (mode) {
          case HomeDropMode.into:
            widget.onInto(details.data);
          case HomeDropMode.combine:
            widget.onCombine(details.data);
          case HomeDropMode.before:
            widget.onBefore(details.data);
        }
      },
      builder: (context, candidate, rejected) {
        return Stack(
          children: [
            // The dragged tile keeps its place at reduced opacity rather than
            // vanishing, so the row does not reflow under the pointer while
            // it is being aimed.
            LongPressDraggable<HomeDrag>(
              data: payload,
              delay: const Duration(milliseconds: 120),
              // Anchored at the pointer, which is not cosmetic: a
              // DragTargetDetails.offset is the *feedback widget's* top-left,
              // not the pointer, and with the default child anchor that is
              // displaced by wherever inside the tile the press began. The
              // whole before-or-into decision reads that offset, so under the
              // default it would answer a question about a point the user is
              // not aiming at. Anchoring at the pointer makes the two the
              // same, and incidentally makes the little drag chip hang off
              // the cursor the way such a chip is expected to.
              dragAnchorStrategy: pointerDragAnchorStrategy,
              feedback: widget.preview,
              // Announced for the same reason a library drag is: the gaps
              // between sections and the logo both react to a drag they
              // cannot see from where they sit.
              onDragStarted: () =>
                  ref.read(homeDragProvider.notifier).start(payload),
              onDragEnd: (_) => ref.read(homeDragProvider.notifier).stop(),
              onDraggableCanceled: (_, _) =>
                  ref.read(homeDragProvider.notifier).stop(),
              childWhenDragging: Opacity(opacity: 0.3, child: widget.child),
              child: _IntoHighlight(
                mode: _hovering,
                child: widget.child,
              ),
            ),
            if (_hovering == HomeDropMode.before)
              Positioned(
                left: 0,
                top: 0,
                right: widget.axis == Axis.horizontal ? null : 0,
                bottom: widget.axis == Axis.horizontal ? 0 : null,
                child: _InsertionMarker(axis: widget.axis, color: scheme.primary),
              ),
          ],
        );
      },
    );
  }
}

/// Shows that a drop would land inside this item, or make a collection of it.
///
/// Two different colours rather than one: "goes into the collection you are
/// pointing at" and "makes a new collection out of these two" are different
/// outcomes, and a single highlight for both would make the second a
/// surprise.
class _IntoHighlight extends StatelessWidget {
  const _IntoHighlight({required this.mode, required this.child});

  final HomeDropMode? mode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final combining = mode == HomeDropMode.combine;
    final active = combining || mode == HomeDropMode.into;
    final tint = combining ? scheme.tertiary : scheme.primary;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active ? tint : Colors.transparent,
          width: 2,
        ),
        color: active ? tint.withValues(alpha: 0.12) : Colors.transparent,
      ),
      child: Stack(
        children: [
          child,
          if (combining)
            Positioned(
              left: 8,
              top: 8,
              child: Tooltip(
                message: 'Make a collection of these two',
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: tint,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.create_new_folder_outlined,
                    size: 14,
                    color: scheme.onTertiary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The bar showing where an insertion would go.
class _InsertionMarker extends StatelessWidget {
  const _InsertionMarker({required this.axis, required this.color});

  final Axis axis;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const thickness = 3.0;
    return Container(
      width: axis == Axis.horizontal ? thickness : null,
      height: axis == Axis.horizontal ? null : thickness,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(thickness),
      ),
    );
  }
}

/// The drop target that sits after the last item, so something can be moved
/// to the end of a run.
///
/// Every other target means "before this one", which leaves the final
/// position unreachable. A run of tiles with nothing after them is exactly
/// where somebody will try to drop, so there has to be something there.
class HomeDropEnd extends StatefulWidget {
  const HomeDropEnd({
    super.key,
    required this.enabled,
    required this.axis,
    required this.onDrop,
  });

  final bool enabled;
  final Axis axis;
  final void Function(HomeDrag dragged) onDrop;

  @override
  State<HomeDropEnd> createState() => _HomeDropEndState();
}

class _HomeDropEndState extends State<HomeDropEnd> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return DragTarget<HomeDrag>(
      onWillAcceptWithDetails: (_) {
        setState(() => _hovering = true);
        return true;
      },
      onLeave: (_) => setState(() => _hovering = false),
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        widget.onDrop(details.data);
      },
      builder: (context, candidate, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: widget.axis == Axis.horizontal ? 44 : double.infinity,
        height: widget.axis == Axis.horizontal ? double.infinity : 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _hovering ? scheme.primary : scheme.outlineVariant,
            width: _hovering ? 2 : 1,
          ),
          color: _hovering
              ? scheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
        ),
        child: Icon(
          Icons.south_east,
          size: 16,
          color: _hovering ? scheme.primary : scheme.outlineVariant,
        ),
      ),
    );
  }
}

/// A compact stand-in for a tile while it is being dragged.
class HomeDragPreview extends StatelessWidget {
  const HomeDragPreview({super.key, required this.title, this.icon});

  final String title;

  /// Shown instead of the generic grip when the drag says what it is -- an
  /// album leaving the albums grid looks like an album all the way across.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? Icons.drag_indicator,
              size: 16,
              color: scheme.onPrimaryContainer,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Carries out a drop.
///
/// The one place that knows the difference between the two kinds of drag:
/// something already on the page is moved, something from the library is
/// inserted. Every drop target calls this rather than branching itself, so a
/// target cannot handle one kind and quietly ignore the other.
Future<void> applyHomeDrop(
  HomeRepository repository,
  HomeDrag dragged, {
  required int sectionId,
  int? parentId,
  int? beforeId,
}) async {
  switch (dragged) {
    case HomeMove(:final item):
      await repository.moveItem(
        item.id,
        sectionId: sectionId,
        newParentId: parentId,
        beforeId: beforeId,
      );
    case HomeAdd(:final kind, :final refId):
      await repository.addItemAt(
        sectionId: sectionId,
        kind: kind,
        refId: refId,
        parentId: parentId,
        beforeId: beforeId,
      );
  }
}

/// The gap between two sections, offered as a place to start a new one.
///
/// Only exists while something is being dragged, and that is the point:
/// "make a section out of this" is a thought people have *with the thing
/// already in hand", so the offer belongs in the moment rather than behind a
/// button somewhere that would need the item chosen all over again
/// afterwards.
class NewSectionGap extends StatefulWidget {
  const NewSectionGap({
    super.key,
    required this.active,
    required this.onDrop,
  });

  /// Whether a drag is in flight. Collapsed to nothing when it is not --
  /// removed from the tree rather than parked at zero height, because a
  /// zero-area interactive widget corrupts the Windows accessibility bridge
  /// and eventually hard-crashes the process.
  final bool active;

  final void Function(HomeDrag dragged) onDrop;

  @override
  State<NewSectionGap> createState() => _NewSectionGapState();
}

class _NewSectionGapState extends State<NewSectionGap> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox(height: 4);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DragTarget<HomeDrag>(
      onWillAcceptWithDetails: (_) {
        setState(() => _hovering = true);
        return true;
      },
      onLeave: (_) => setState(() => _hovering = false),
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        widget.onDrop(details.data);
      },
      builder: (context, candidate, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: _hovering ? 76 : 52,
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: _hovering
              ? scheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          border: Border.all(
            color: _hovering ? scheme.primary : scheme.outlineVariant,
            width: _hovering ? 2 : 1,
          ),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add,
                size: 18,
                color: _hovering ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                'New section here',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _hovering ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
