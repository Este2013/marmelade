import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../domain/models/home_views.dart';
import '../../widgets/selection.dart';
import 'home_actions.dart';
import 'home_drag.dart';
import 'section_header.dart';
import 'home_tile.dart';

/// One section of the home page, in whichever layout it is set to.
class HomeSectionBlock extends ConsumerWidget {
  const HomeSectionBlock({
    super.key,
    required this.section,
    required this.actions,
    required this.onViewAll,
    required this.onAddItems,
    required this.dragIndex,
  });

  final HomeSectionView section;
  final HomeActions actions;

  /// Opens the section's full contents, for a list that had to cut itself off.
  final void Function(HomeSectionView section) onViewAll;

  final void Function(HomeSectionView section) onAddItems;

  /// This section's position in the reorderable list.
  ///
  /// Needed here rather than in the page because only the *header* starts a
  /// section drag: wrapping the whole block would mean a long press on a
  /// tile raced the tile's own drag, and which one won would come down to
  /// whose delay was shorter.
  final int dragIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched here, where a rebuild is cheap, and handed down: the end-drop
    // zones exist only while something is in flight, and the layouts below
    // are plain widgets with no provider access of their own.
    final dragging = ref.watch(homeDragProvider) != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ReorderableDelayedDragStartListener(
            index: dragIndex,
            child: SectionHeader(
              section: section,
              onViewAll: () => onViewAll(section),
              onAddItems: () => onAddItems(section),
            ),
          ),
          // AnimatedSize around a child that is genuinely absent when
          // collapsed, rather than an AnimatedCrossFade: that keeps both
          // children built, which would park a folded section's play buttons
          // at zero height -- and a zero-area interactive widget corrupts the
          // Windows accessibility bridge and eventually kills the process.
          // AnimatedSize is the one of the two that is safe here.
          AnimatedSize(
            alignment: Alignment.topCenter,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: section.collapsed
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: section.isEmpty
                        ? _EmptySection(section: section)
                        : section.layout == HomeLayout.grid
                            ? _Grid(
                                section: section,
                                actions: actions,
                                dragging: dragging,
                                ref: ref,
                              )
                            : _List(
                                section: section,
                                actions: actions,
                                dragging: dragging,
                                ref: ref,
                              ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptySection extends StatelessWidget {
  const _EmptySection({required this.section});

  final HomeSectionView section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        section.source.isCurated
            ? 'Empty. Use the + beside the title, or drag something here '
                'from anywhere in the library.'
            : 'Nothing played yet. This fills itself in as you listen.',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({
    required this.section,
    required this.actions,
    required this.dragging,
    required this.ref,
  });

  final HomeSectionView section;
  final HomeActions actions;

  /// Whether something is in flight, which is the only time the end-drop
  /// zone is worth the space it takes.
  final bool dragging;

  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final items = section.preview;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.76,
        crossAxisSpacing: 18,
        mainAxisSpacing: 18,
      ),
      // One extra cell for the end target, so the last position is reachable.
      itemCount: items.length + (_showEnd ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == items.length) {
          return Center(
            child: HomeDropEnd(
              enabled: true,
              axis: Axis.horizontal,
              onDrop: (dragged) => _move(dragged, beforeId: null),
            ),
          );
        }
        final item = items[index];
        return HomeDraggable(
          item: item,
          sectionId: section.id,
          enabled: _rearrangeable,
          axis: Axis.horizontal,
          preview: HomeDragPreview(title: item.title),
          onBefore: (dragged) => _move(dragged, beforeId: item.id),
          onInto: (dragged) => _move(dragged, parentId: item.id),
          onCombine: (dragged) => _combine(dragged, item),
          child: Builder(
            builder: (tileContext) => HomeTile(
              item: item,
              onOpen: () => actions.open(tileContext, item),
              onPlay: () => actions.play(item),
              onMenu: item.isComputed
                  ? null
                  : (at) => showItemMenu(context, at, _menuFor(ref, actions, item)),
            ),
          ),
        );
      },
    );
  }

  /// Dragging does not wait for Arrange mode.
  ///
  /// It cannot: an album dragged in from the albums grid arrives at a page
  /// that is not in Arrange mode and has no way to be put into one mid-drag,
  /// so the drop targets have to be live regardless. Once they are, making
  /// the page's *own* tiles need a mode to be picked up would be an
  /// inconsistency with nothing behind it. Arrange mode still gates the
  /// structural controls -- removing, renaming, layouts, section handles.
  ///
  /// A computed section is still out: its order is a fact about what was
  /// played, and dragging it would promise something the next play undoes.
  bool get _rearrangeable => section.source.isCurated;

  bool get _showEnd => _rearrangeable && dragging;

  void _move(HomeDrag dragged, {int? beforeId, int? parentId}) {
    applyHomeDrop(
      ref.read(homeRepositoryProvider),
      dragged,
      sectionId: section.id,
      parentId: parentId,
      beforeId: beforeId,
    );
  }

  /// Wraps the drop target and the dropped thing in a new collection.
  Future<void> _combine(HomeDrag dragged, HomeItemView target) async {
    final repository = ref.read(homeRepositoryProvider);
    final collectionId = await repository.wrapInCollection(
      sectionId: section.id,
      targetId: target.id,
    );
    if (collectionId == null) return;
    await applyHomeDrop(
      repository,
      dragged,
      sectionId: section.id,
      parentId: collectionId,
    );
  }


}

/// The right-click menu on one tile or row.
///
/// Where removing lives now that the page has no arranging mode. Shared by
/// both layouts rather than written twice: a list row and a grid tile stand
/// for exactly the same thing, and a menu that differed between them would
/// be a difference with no meaning behind it.
List<MenuAction> _menuFor(
  WidgetRef ref,
  HomeActions actions,
  HomeItemView item,
) =>
    [
      MenuAction(
        label: 'Play',
        icon: Icons.play_arrow,
        onSelected: () => actions.play(item),
      ),
      const MenuAction.separator(),
      MenuAction(
        label: 'Remove from home',
        icon: Icons.close,
        isDestructive: true,
        onSelected: () => ref.read(homeRepositoryProvider).removeItem(item.id),
      ),
    ];

class _List extends StatelessWidget {
  const _List({
    required this.section,
    required this.actions,
    required this.dragging,
    required this.ref,
  });

  final HomeSectionView section;
  final HomeActions actions;

  /// Whether something is in flight, which is the only time the end-drop
  /// zone is worth the space it takes.
  final bool dragging;

  final WidgetRef ref;

  /// How wide a list is allowed to get.
  ///
  /// A row is a thumbnail, a name and a play button, and letting that stretch
  /// across a maximised window puts the button most of a screen away from the
  /// name it belongs to. A grid has the opposite need -- more width is more
  /// tiles -- which is why only this half is capped.
  static const _maxWidth = 720.0;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: Column(
        children: [
          for (final item in section.preview)
            HomeDraggable(
              item: item,
              sectionId: section.id,
              enabled: _rearrangeable,
              axis: Axis.vertical,
              preview: HomeDragPreview(title: item.title),
              onBefore: (dragged) => _move(dragged, beforeId: item.id),
              onInto: (dragged) => _move(dragged, parentId: item.id),
              onCombine: (dragged) => _combine(dragged, item),
              child: Builder(
                builder: (rowContext) => HomeRow(
                  item: item,
                  onOpen: () => actions.open(rowContext, item),
                  onPlay: () => actions.play(item),
                  onMenu: item.isComputed
                      ? null
                      : (at) => showItemMenu(context, at, _menuFor(ref, actions, item)),
                ),
              ),
            ),
          if (_showEnd) ...[
            const SizedBox(height: 8),
            HomeDropEnd(
              enabled: true,
              axis: Axis.vertical,
              onDrop: (dragged) => _move(dragged, beforeId: null),
            ),
          ],
        ],
      ),
    );
  }

  /// See the grid's own note: dragging is always live, computed sections
  /// never are.
  bool get _rearrangeable => section.source.isCurated;

  bool get _showEnd => _rearrangeable && dragging;

  void _move(HomeDrag dragged, {int? beforeId, int? parentId}) {
    applyHomeDrop(
      ref.read(homeRepositoryProvider),
      dragged,
      sectionId: section.id,
      parentId: parentId,
      beforeId: beforeId,
    );
  }

  /// Wraps the drop target and the dropped thing in a new collection.
  Future<void> _combine(HomeDrag dragged, HomeItemView target) async {
    final repository = ref.read(homeRepositoryProvider);
    final collectionId = await repository.wrapInCollection(
      sectionId: section.id,
      targetId: target.id,
    );
    if (collectionId == null) return;
    await applyHomeDrop(
      repository,
      dragged,
      sectionId: section.id,
      parentId: collectionId,
    );
  }

}
