import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../domain/models/home_views.dart';
import 'add_home_item.dart';
import 'home_drag.dart';
import '../playlists/smart_query_field.dart';
import 'home_actions.dart';
import 'home_artwork.dart';
import 'home_tile.dart';

/// Expands a collection tile into a panel showing what is inside it.
///
/// The panel grows out of the tile that was clicked rather than appearing in
/// the middle of the screen, so the thing that opened and the thing that was
/// pressed are visibly the same object. [from] is the tile's own context,
/// which is how the growth point is found.
///
/// Recursive: a collection inside a collection opens another one of these on top, and
/// closing them walks back out the way it came in. That is the whole of
/// "recursively nested" -- there is no special case for depth, because every
/// level is the same widget.
Future<void> showHomeCollection(
  BuildContext from,
  HomeItemView collection,
  HomeActions actions,
) {
  // Where on screen the tile sits, as an alignment, so the panel can scale
  // out of that point. Measured before the route is pushed, while the tile is
  // certainly still laid out.
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

  return showGeneralDialog(
    context: from,
    barrierDismissible: true,
    barrierLabel: 'Close ${collection.title}',
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (context, _, _) => _CollectionPanel(collection: collection, actions: actions),
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

/// The expanded contents of one collection.
class _CollectionPanel extends ConsumerStatefulWidget {
  const _CollectionPanel({required this.collection, required this.actions});

  final HomeItemView collection;
  final HomeActions actions;

  @override
  ConsumerState<_CollectionPanel> createState() => _CollectionPanelState();
}

class _CollectionPanelState extends ConsumerState<_CollectionPanel> {
  /// The grid is held back until the zoom has finished.
  ///
  /// Not for looks: a `ScaleTransition` is a `Transform`, and a transform
  /// rewrites the semantics geometry of every node inside it on every frame.
  /// A grid of tiles with play buttons inside a running scale is exactly the
  /// shape that floods the Windows accessibility bridge. Letting the panel
  /// zoom as a plain picture and bringing the interactive tiles in afterwards
  /// costs one frame of patience and takes that cost to nothing.
  var _settled = false;

  /// The collection's contents with any searches already run and spliced in.
  ///
  /// Null until the first resolve finishes, which is the one moment the
  /// panel has nothing truthful to show -- a collection whose middle is a
  /// search does not know its own length until that search has been asked.
  List<HomeItemView>? _contents;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 330), () {
      if (mounted) setState(() => _settled = true);
    });
    _resolve();
  }

  /// Expands every search child into what it currently matches.
  ///
  /// A collection's contents are "these, then everything that matches, then
  /// those", so a search sitting in the middle has to become its results in
  /// place rather than a tile standing for them -- otherwise what the
  /// collection *plays* and what it *shows* are two different lists.
  ///
  /// Run on open rather than cached: a search that froze what it found the
  /// first time it was looked at would stop being a search.
  Future<void> _resolve() async {
    final out = <HomeItemView>[];
    for (final child in widget.collection.children) {
      if (child.kind != HomeItemKind.query || child.query == null) {
        out.add(child);
        continue;
      }
      final ids =
          await ref.read(smartPlaylistResolverProvider).resolve(child.query!);
      out.addAll(
        await ref
            .read(homeRepositoryProvider)
            .trackItems(ids, widget.collection.sectionId),
      );
    }
    if (!mounted) return;
    setState(() => _contents = out);
  }

  @override
  void didUpdateWidget(_CollectionPanel old) {
    super.didUpdateWidget(old);
    _resolve();
  }

  /// What the grid shows: the contents, with searches already run.
  ///
  /// The searches themselves do not appear here -- they are in the header as
  /// chips (see [_Rules]). A rule that has dissolved into fifty results is a
  /// rule nobody can change or delete, so it needs somewhere of its own to
  /// live; showing it twice, once as a tile and once as its results, would
  /// just list the collection's contents twice over.
  List<HomeItemView> get _shown =>
      _contents ?? widget.collection.children;

  void _move(HomeDrag dragged, {required int parentId, int? beforeId}) {
    applyHomeDrop(
      ref.read(homeRepositoryProvider),
      dragged,
      sectionId: widget.collection.sectionId,
      parentId: parentId,
      beforeId: beforeId,
    );
  }

  /// Wraps a tile inside this collection and the dropped thing in a new
  /// collection of their own, nested one level deeper.
  Future<void> _combine(HomeDrag dragged, HomeItemView target) async {
    final sectionId = widget.collection.sectionId;
    final repository = ref.read(homeRepositoryProvider);
    final collectionId = await repository.wrapInCollection(
      sectionId: sectionId,
      targetId: target.id,
    );
    if (collectionId == null) return;
    await applyHomeDrop(
      repository,
      dragged,
      sectionId: sectionId,
      parentId: collectionId,
    );
  }

  /// Puts something new straight into this collection.
  ///
  /// The add dialog has always told people to "open it and use Add items
  /// inside" -- this is the button that sentence was describing, which the
  /// panel did not actually have until drag-and-drop made the gap obvious.
  Future<void> _addItems() async {
    final sectionId = widget.collection.sectionId;
    final parentId = widget.collection.id;
    final repository = ref.read(homeRepositoryProvider);
    while (true) {
      if (!mounted) return;
      final chosen = await addHomeItem(
        context,
        ref,
        title: 'Add to "${widget.collection.title}"',
      );
      if (chosen == null) return;
      await repository.addItem(
        sectionId: sectionId,
        parentId: parentId,
        kind: chosen.kind,
        refId: chosen.refId,
        label: chosen.label,
        query: chosen.query,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final collection = widget.collection;
    // Read here rather than passed in: the overlay outlives the tile that
    // opened it, and Arrange can be switched off while it is up.
    final dragging = ref.watch(homeDragProvider) != null;
    final shown = _shown;

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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Header(
                  collection: collection,
                  actions: widget.actions,
                  onAddItems: _addItems,
                ),
                _Rules(
                  collection: collection,
                  onChanged: _resolve,
                ),
                const Divider(height: 1),
                Flexible(
                  child: shown.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(48),
                          child: Text(
                            'Nothing in here yet.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : AnimatedOpacity(
                          opacity: _settled ? 1 : 0,
                          duration: const Duration(milliseconds: 180),
                          alwaysIncludeSemantics: true,
                          child: GridView.builder(
                            padding: const EdgeInsets.all(20),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 180,
                              childAspectRatio: 0.78,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 16,
                            ),
                            itemCount: shown.length + (dragging ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == shown.length) {
                                return Center(
                                  child: HomeDropEnd(
                                    enabled: true,
                                    axis: Axis.horizontal,
                                    onDrop: (dragged) => _move(
                                      dragged,
                                      parentId: collection.id,
                                    ),
                                  ),
                                );
                              }
                              final child = shown[index];
                              return HomeDraggable(
                                item: child,
                                sectionId: widget.collection.sectionId,
                                // Live regardless of Arrange, like the page
                                // behind it -- a drag arriving from the
                                // library has to be able to land in here.
                                enabled: !child.isComputed,
                                axis: Axis.horizontal,
                                preview: HomeDragPreview(title: child.title),
                                onBefore: (dragged) => _move(
                                  dragged,
                                  parentId: collection.id,
                                  beforeId: child.id,
                                ),
                                onInto: (dragged) =>
                                    _move(dragged, parentId: child.id),
                                onCombine: (dragged) =>
                                    _combine(dragged, child),
                                child: Builder(
                                  builder: (tileContext) => HomeTile(
                                    item: child,

                                    onOpen: () =>
                                        widget.actions.open(tileContext, child),
                                    onPlay: () => widget.actions.play(child),
                                  ),
                                ),
                              );
                            },
                          ),
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

class _Header extends StatelessWidget {
  const _Header({
    required this.collection,
    required this.actions,
    required this.onAddItems,
  });

  final HomeItemView collection;
  final HomeActions actions;

  final VoidCallback onAddItems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Row(
        children: [
          HomeArtwork(item: collection, size: 56, radius: 10),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(collection.title, style: theme.textTheme.titleLarge),
                if (collection.subtitle != null)
                  Text(
                    collection.subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: onAddItems,
            icon: const Icon(Icons.add),
            label: const Text('Add items'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () => actions.play(collection),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play all'),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// The searches a collection holds, as chips.
///
/// Their results are out in the grid, mixed in where they belong, which
/// leaves the rules themselves with nowhere to be clicked. This is that
/// somewhere: one chip per search, removable, and tapping one rewrites it.
/// Absent entirely when the collection has none, which is most of them.
class _Rules extends ConsumerWidget {
  const _Rules({required this.collection, required this.onChanged});

  final HomeItemView collection;

  /// Re-runs the searches after one has been edited or removed. The grid is
  /// built from a resolved snapshot, so it does not follow the database on
  /// its own.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searches = [
      for (final child in collection.children)
        if (child.kind == HomeItemKind.query) child,
    ];
    if (searches.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          Icon(
            Icons.search,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final search in searches)
                  InputChip(
                    label: Text(search.title),
                    tooltip: search.query,
                    onPressed: () => _edit(context, ref, search),
                    onDeleted: () async {
                      await ref
                          .read(homeRepositoryProvider)
                          .removeItem(search.id);
                      onChanged();
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    HomeItemView search,
  ) async {
    final controller = TextEditingController(text: search.query ?? '');
    final query = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit "${search.title}"'),
        content: SizedBox(
          width: 460,
          child: SmartQueryField(
            controller: controller,
            autofocus: true,
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (query == null || query.trim().isEmpty) return;
    await ref.read(homeRepositoryProvider).setItemQuery(search.id, query.trim());
    onChanged();
  }
}
