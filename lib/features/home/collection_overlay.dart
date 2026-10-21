import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../domain/models/home_views.dart';
import 'add_home_item.dart';
import '../../widgets/selection.dart';
import 'collection_picture.dart';
import 'detail_overlay.dart';
import 'drag_scroll.dart';
import 'home_drag.dart';
import 'home_overlay.dart';
import 'query_fields.dart';
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
  return showHomeOverlay<void>(
    from,
    label: 'Close ${collection.title}',
    builder: (context) =>
        _CollectionPanel(collection: collection, actions: actions),
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

  /// What each search in this collection currently matches, by its item id.
  final _resolved = <int, List<HomeItemView>>{};

  /// The rule each entry in [_resolved] was produced from, so rewriting one
  /// re-runs it rather than showing what the old one found.
  final _resolvedFor = <int, String>{};

  /// All three parts of a rule, so changing the type or the order re-runs it
  /// too -- the query text alone would call "albums where X" and "artists
  /// where X, by name" the same question.
  static String _ruleOf(HomeItemView search) =>
      '${search.queryType.name}/${search.querySort.name}'
      '/${search.queryInverted}:${search.query ?? ''}';

  final _scroll = ScrollController();
  var _running = false;

  /// Set when the page changed while a resolve was already running, so the
  /// loop below takes another pass instead of dropping that change.
  var _again = false;

  /// The actions this panel hands to its tiles.
  ///
  /// Everything except the three kinds with a page of their own is passed
  /// straight through; those open on top instead, so clicking an album
  /// inside a collection does not bury it under the collection.
  ///
  /// A panel opened from here hands the same rule on by itself -- the detail
  /// panel's own links call back into [showHomeDetail] -- so this needs no
  /// recursion of its own.
  HomeActions get _actions => widget.actions.copyWith(
        openAlbum: (id) =>
            showHomeDetail(context, kind: HomeItemKind.album, refId: id),
        openArtist: (id) =>
            showHomeDetail(context, kind: HomeItemKind.artist, refId: id),
        openPlaylist: (id) =>
            showHomeDetail(context, kind: HomeItemKind.playlist, refId: id),
      );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 330), () {
      if (mounted) setState(() => _settled = true);
    });

    // fireImmediately, because the page almost certainly already has its
    // data by the time this panel opens -- waiting for a *change* would mean
    // the searches never ran at all on a collection nobody edits.
    ref.listenManual(
      homeProvider,
      (_, _) => _syncSearches(),
      fireImmediately: true,
    );
  }

  /// The collection as it is now, rather than as it was when the panel opened.
  ///
  /// The panel is a dialog route: nothing rebuilds it when the page behind
  /// changes, so holding the [HomeItemView] it was handed meant a search
  /// added from in here was written to the database and never shown. Looking
  /// the collection up by id on every build is what makes the panel live.
  HomeItemView? _lookUp(List<HomeSectionView>? page) {
    if (page == null) return null;
    HomeItemView? walk(List<HomeItemView> items, int depth) {
      if (depth > 8) return null;
      for (final item in items) {
        if (item.id == widget.collection.id) return item;
        final found = walk(item.children, depth + 1);
        if (found != null) return found;
      }
      return null;
    }

    for (final section in page) {
      final found = walk(section.items, 0);
      if (found != null) return found;
    }
    return null;
  }

  /// Runs any search whose results are missing or were found for an older
  /// version of its query, and forgets the ones whose rule has been deleted.
  ///
  /// Driven from a listen on the page rather than from [initState]: a rule
  /// can be added, rewritten or removed while the panel is open, and each of
  /// those is a different list of results a moment later.
  ///
  /// Loops rather than returning early when one is already running. Two edits
  /// in quick succession -- adding a rule and then another -- would otherwise
  /// see the second arrive mid-resolve and be dropped, leaving results that
  /// are correct for a collection nobody has any more.
  Future<void> _syncSearches() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    do {
      _again = false;
      // Re-read every pass: the whole point of looping is that it changed.
      final collection = _lookUp(ref.read(homeProvider).value);
      if (collection == null) break;

      final present = {for (final child in collection.children) child.id};
      _resolved.removeWhere((id, _) => !present.contains(id));
      _resolvedFor.removeWhere((id, _) => !present.contains(id));

      final stale = [
        for (final child in collection.children)
          if (child.kind == HomeItemKind.query &&
              _resolvedFor[child.id] != _ruleOf(child))
            child,
      ];
      for (final child in stale) {
        _resolved[child.id] = await ref.read(homeQueryItemsProvider)(child);
        _resolvedFor[child.id] = _ruleOf(child);
      }
    } while (_again && mounted);
    _running = false;
    if (mounted) setState(() {});
  }

  /// Rewrites one search: what it looks for, what makes a match, and how it
  /// is ordered.
  ///
  /// Lives on the panel now that the rule has a block of its own -- it used
  /// to hang off a chip in the header, which is the thing that had to go.
  Future<void> _edit(HomeItemView search) async {
    final controller = TextEditingController(text: search.query ?? '');
    final titleController = TextEditingController(text: search.label ?? '');
    var type = search.queryType;
    var sort = search.querySort;
    var inverted = search.queryInverted;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Edit the search'),
          content: SizedBox(
            width: 460,
            child: QueryFields(
              controller: controller,
              titleController: titleController,
              type: type,
              sort: sort,
              onTypeChanged: (chosen) => setState(() => type = chosen),
              onSortChanged: (chosen) => setState(() => sort = chosen),
              inverted: inverted,
              onInvertedChanged: (chosen) =>
                  setState(() => inverted = chosen),
              autofocus: true,
              onSubmitted: () => Navigator.of(context).pop(true),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved != true || controller.text.trim().isEmpty) return;
    final repository = ref.read(homeRepositoryProvider);
    await repository.setItemQuery(
      search.id,
      controller.text.trim(),
      type: type,
      sort: sort,
      inverted: inverted,
    );
    // Emptied means "go back to showing the rule", which is a different
    // answer from leaving it alone -- so it is written either way.
    final title = titleController.text.trim();
    await repository.renameItem(search.id, title.isEmpty ? null : title);
  }

  /// Drops something after the last item of a run.
  ///
  /// "After this run" is "before whatever follows it", which is how the rest
  /// of the ordering already works -- and when nothing follows, it is the
  /// end of the collection and needs no anchor at all.
  void _afterRun(HomeDrag dragged, HomeItemView collection, _Block run) {
    final children = collection.children;
    final last = run.items.isEmpty ? null : run.items.last;
    final at = last == null ? -1 : children.indexWhere((c) => c.id == last.id);
    final next = at >= 0 && at + 1 < children.length ? children[at + 1] : null;
    _move(dragged, parentId: collection.id, beforeId: next?.id);
  }

  /// The collection's contents, broken into the blocks that make it up.
  ///
  /// A run of hand-picked items is one block; each search is a block of its
  /// own, headed by the rule and filled with what it currently finds. That is
  /// what makes a search movable: it is a thing on the page with a handle,
  /// rather than a chip in the header describing something spliced invisibly
  /// into a flat grid.
  ///
  /// Order comes straight from the children, so moving a search among them is
  /// an ordinary reorder and needs no separate notion of where blocks sit.
  List<_Block> _blocks(HomeItemView collection) {
    final blocks = <_Block>[];
    var picked = <HomeItemView>[];

    void flush() {
      if (picked.isEmpty) return;
      blocks.add((search: null, items: picked));
      picked = [];
    }

    for (final child in collection.children) {
      if (child.kind == HomeItemKind.query) {
        flush();
        blocks.add((search: child, items: _resolved[child.id] ?? const []));
      } else {
        picked.add(child);
      }
    }
    flush();
    return blocks;
  }

  Widget _body(ThemeData theme, HomeItemView collection, bool dragging) {
    final blocks = _blocks(collection);
    if (blocks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(48),
        child: Text(
          'Nothing in here yet.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    return AnimatedOpacity(
      opacity: _settled ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      alwaysIncludeSemantics: true,
      child: DragScroll(
        controller: _scroll,
        active: dragging,
        child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(20),
        children: [
          for (final block in blocks)
            if (block.search case final search?)
              _SearchBlock(
                search: search,
                results: block.items,
                actions: _actions,
                onEdit: () => _edit(search),
                onRemove: () =>
                    ref.read(homeRepositoryProvider).removeItem(search.id),
                onDropBefore: (dragged) => _move(
                  dragged,
                  parentId: collection.id,
                  beforeId: search.id,
                ),
                onToggleCollapsed: () => ref
                    .read(homeRepositoryProvider)
                    .setItemCollapsed(search.id, !search.collapsed),
              )
            else
              _PickedBlock(
                items: block.items,
                collection: collection,
                dragging: dragging,
                actions: _actions,
                onOpenMenu: _menuForChild,
                onBefore: (dragged, before) => _move(
                  dragged,
                  parentId: collection.id,
                  beforeId: before.id,
                ),
                onInto: (dragged, target) =>
                    _move(dragged, parentId: target.id),
                onCombine: _combine,
                onAfterLast: (dragged) => _afterRun(dragged, collection, block),
              ),
          // The way to put something at the very end, which every other
          // target's "before this one" leaves unreachable.
          if (dragging)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: HomeDropEnd(
                enabled: true,
                axis: Axis.vertical,
                onDrop: (dragged) =>
                    _move(dragged, parentId: collection.id),
              ),
            ),
        ],
        ),
      ),
    );
  }

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

  /// The right-click menu on a tile inside this panel.
  ///
  /// The same offers a tile on the page gets -- a collection two levels down
  /// is still a collection, and having to close the panel to rename its
  /// picture would be a rule with no reason behind it.
  List<MenuAction> _menuForChild(HomeItemView child) => [
        MenuAction(
          label: 'Play',
          icon: Icons.play_arrow,
          onSelected: () => _actions.play(child),
        ),
        if (child.isCollection) ...[
          const MenuAction.separator(),
          MenuAction(
            label: 'Change picture',
            icon: Icons.image_outlined,
            onSelected: () => pickCollectionPicture(context, ref, child),
          ),
        ],
        const MenuAction.separator(),
        MenuAction(
          label: 'Remove from home',
          icon: Icons.close,
          isDestructive: true,
          onSelected: () =>
              ref.read(homeRepositoryProvider).removeItem(child.id),
        ),
      ];

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
        queryType: chosen.queryType,
        querySort: chosen.querySort,
        queryInverted: chosen.queryInverted,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = ref.watch(homeProvider).value;
    final collection = _lookUp(page) ?? widget.collection;
    final dragging = ref.watch(homeDragProvider) != null;



    return HomeOverlayCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            collection: collection,
            actions: _actions,
            onAddItems: _addItems,
            onPickPicture: () =>
                pickCollectionPicture(context, ref, collection),
          ),
          const Divider(height: 1),
          Flexible(child: _body(theme, collection, dragging)),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.collection,
    required this.actions,
    required this.onAddItems,
    required this.onPickPicture,
  });

  final HomeItemView collection;
  final HomeActions actions;

  final VoidCallback onAddItems;
  final VoidCallback onPickPicture;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Row(
        children: [
          _EditablePicture(
            collection: collection,
            onPressed: onPickPicture,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(collection.title, style: theme.textTheme.titleLarge),
                if (collection.displaySubtitle != null)
                  Text(
                    collection.displaySubtitle!,
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

/// The collection's picture, with the way to change it laid over it.
///
/// On the artwork rather than beside it, the way the album grid puts play on
/// a cover and the editors put their camera button on a portrait: the thing
/// being changed is the thing you point at, and a button in the row would be
/// one more control competing with Add items and Play all for the eye.
class _EditablePicture extends StatefulWidget {
  const _EditablePicture({required this.collection, required this.onPressed});

  final HomeItemView collection;
  final VoidCallback onPressed;

  @override
  State<_EditablePicture> createState() => _EditablePictureState();
}

class _EditablePictureState extends State<_EditablePicture> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: SizedBox(
        width: 56,
        height: 56,
        child: Stack(
          fit: StackFit.expand,
          children: [
            HomeArtwork(item: widget.collection, radius: 10),
            // Opacity rather than presence, and never `onPressed: null`:
            // adding and removing a button rewrites its semantics node
            // instead of updating it, which is what floods the Windows
            // accessibility bridge. alwaysIncludeSemantics keeps it
            // reachable without a pointer at all.
            AnimatedOpacity(
              opacity: _hovering ? 1 : 0,
              duration: const Duration(milliseconds: 140),
              alwaysIncludeSemantics: true,
              child: Material(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: widget.onPressed,
                  child: Tooltip(
                    message: 'Change picture',
                    child: Icon(
                      Icons.edit_outlined,
                      size: 20,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One run of a collection's contents: either hand-picked items, or a search
/// and what it found.
typedef _Block = ({HomeItemView? search, List<HomeItemView> items});

/// A run of hand-picked items, as a grid.
class _PickedBlock extends StatelessWidget {
  const _PickedBlock({
    required this.items,
    required this.collection,
    required this.dragging,
    required this.actions,
    required this.onOpenMenu,
    required this.onBefore,
    required this.onInto,
    required this.onCombine,
    required this.onAfterLast,
  });

  final List<HomeItemView> items;
  final HomeItemView collection;

  /// Whether something is in flight, which is the only time the trailing
  /// slot is worth the space it takes.
  final bool dragging;

  final HomeActions actions;
  final List<MenuAction> Function(HomeItemView) onOpenMenu;
  final void Function(HomeDrag dragged, HomeItemView before) onBefore;
  final void Function(HomeDrag dragged, HomeItemView target) onInto;
  final void Function(HomeDrag dragged, HomeItemView target) onCombine;

  /// Drops something at the end of this run, which for the last run in a
  /// collection is the end of the collection.
  final void Function(HomeDrag dragged) onAfterLast;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.78,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      // One extra cell while dragging, so the position *after* the last item
      // is reachable -- every other target means "before this one", which
      // leaves the end of a run with nothing to aim at.
      itemCount: items.length + (dragging ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == items.length) {
          return Center(
            child: HomeDropEnd(
              enabled: true,
              axis: Axis.horizontal,
              onDrop: onAfterLast,
            ),
          );
        }
        final child = items[index];
        return HomeDraggable(
          item: child,
          sectionId: collection.sectionId,
          // Live regardless of anything: a drag arriving from the library has
          // to be able to land in here.
          enabled: true,
          axis: Axis.horizontal,
          preview: HomeDragPreview(title: child.title),
          onBefore: (dragged) => onBefore(dragged, child),
          onInto: (dragged) => onInto(dragged, child),
          onCombine: (dragged) => onCombine(dragged, child),
          child: Builder(
            builder: (tileContext) => HomeTile(
              item: child,
              onOpen: () => actions.open(tileContext, child),
              onPlay: () => actions.play(child),
              onMenu: (at) => showItemMenu(context, at, onOpenMenu(child)),
            ),
          ),
        );
      },
    );
  }
}

/// A search, headed by its rule and filled with what it currently finds.
///
/// Shaped after a section on the home page, and for the same reason: it is a
/// run of things with a title that says where they came from, and it has to
/// be movable among its neighbours. Holding the header picks the whole block
/// up; right-clicking it offers the two things a rule can have done to it.
class _SearchBlock extends ConsumerStatefulWidget {
  const _SearchBlock({
    required this.search,
    required this.results,
    required this.actions,
    required this.onEdit,
    required this.onRemove,
    required this.onDropBefore,
    required this.onToggleCollapsed,
  });

  final HomeItemView search;
  final List<HomeItemView> results;
  final HomeActions actions;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final void Function(HomeDrag dragged) onDropBefore;
  final VoidCallback onToggleCollapsed;

  @override
  ConsumerState<_SearchBlock> createState() => _SearchBlockState();
}

class _SearchBlockState extends ConsumerState<_SearchBlock> {
  var _dragOver = false;

  List<MenuAction> get _menu => [
        MenuAction(
          label: 'Play what it found',
          icon: Icons.play_arrow,
          onSelected: () => widget.actions.play(widget.search),
        ),
        const MenuAction.separator(),
        MenuAction(
          label: 'Edit the search',
          icon: Icons.edit_outlined,
          onSelected: widget.onEdit,
        ),
        MenuAction(
          label: 'Remove the search',
          icon: Icons.close,
          isDestructive: true,
          onSelected: widget.onRemove,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final search = widget.search;
    final payload = HomeMove(item: search, sectionId: search.sectionId);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // An insertion bar above the header, so a drag can be aimed at the
          // gap before this block rather than only at a tile inside one.
          DragTarget<HomeDrag>(
            onWillAcceptWithDetails: (_) {
              setState(() => _dragOver = true);
              return true;
            },
            onLeave: (_) => setState(() => _dragOver = false),
            onAcceptWithDetails: (details) {
              setState(() => _dragOver = false);
              widget.onDropBefore(details.data);
            },
            builder: (context, candidate, rejected) => AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: _dragOver ? 6 : 3,
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: _dragOver ? scheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          LongPressDraggable<HomeDrag>(
            data: payload,
            delay: const Duration(milliseconds: 220),
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: HomeDragPreview(
              title: search.displayTitle,
              icon: Icons.search,
            ),
            // Announced, like every other draggable on the page. Without it
            // nothing that depends on "something is in flight" existed while
            // a search block was being moved: no trailing slot on the run
            // below it, no gaps between sections, and no edge scrolling --
            // which is three symptoms of one omission.
            onDragStarted: () =>
                ref.read(homeDragProvider.notifier).start(payload),
            onDragEnd: (_) => ref.read(homeDragProvider.notifier).stop(),
            onDraggableCanceled: (_, _) =>
                ref.read(homeDragProvider.notifier).stop(),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                // The whole row, like a section's title bar on the page:
                // hitting the few characters of a rule is a worse target
                // than the line it sits on.
                onTap: widget.onToggleCollapsed,
                onSecondaryTapUp: (details) =>
                    showItemMenu(context, details.globalPosition, _menu),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        search.collapsed
                            ? Icons.chevron_right
                            : Icons.expand_more,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.search,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          // Its own name when it has one, otherwise the rule
                          // -- which is the only honest thing to call a
                          // search nobody has named.
                          search.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (search.collapsed)
            const SizedBox.shrink()
          else if (widget.results.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Nothing matches it right now.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 180,
                childAspectRatio: 0.78,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: widget.results.length,
              itemBuilder: (context, index) {
                final found = widget.results[index];
                // Not draggable: these are not rows anybody placed, they are
                // what the rule above currently says. Moving one would be
                // undone by the next time it ran.
                return Builder(
                  builder: (tileContext) => HomeTile(
                    item: found,
                    onOpen: () => widget.actions.open(tileContext, found),
                    onPlay: () => widget.actions.play(found),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
