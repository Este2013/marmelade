import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart';
import '../../domain/models/home_views.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/section_title.dart';
import 'add_home_item.dart';
import 'collection_overlay.dart';
import 'home_actions.dart';
import 'drag_scroll.dart';
import 'home_drag.dart';
import 'home_section.dart';

/// The home page: whatever the user decided should be here.
///
/// Deliberately opinionless about music. Every other view in the app is
/// organised by a fact about the library -- these are the albums, these are
/// the artists -- and this one is organised by nothing except what somebody
/// put where. That is the whole point of it, and it is why there is an
/// arranging mode rather than a settings page: the arrangement is the content.
class HomeView extends ConsumerWidget {
  const HomeView({super.key, required this.onOpenAlbum, required this.onOpenArtist, required this.onOpenPlaylist, this.onOpenSettings});

  final void Function(int albumId) onOpenAlbum;
  final void Function(int artistId) onOpenArtist;
  final void Function(int playlistId) onOpenPlaylist;

  /// Offered on the empty state, where adding music is the actual next step.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref.watch(homeProvider);

    final actions = HomeActions(
      openAlbum: onOpenAlbum,
      openArtist: onOpenArtist,
      openPlaylist: onOpenPlaylist,
      play: (item) => _play(ref, item),
      openCollection: (from, collection) => showHomeCollection(from, collection, _actionsFor(ref)),
    );

    return sections.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(icon: Icons.error_outline, title: 'The home page could not be read', message: '$error'),
      data: (data) => _Page(sections: data, actions: actions, onOpenSettings: onOpenSettings),
    );
  }

  /// Rebuilt rather than captured, because the collection overlay hands these back
  /// down to tiles that can open further collections -- and a closure capturing a
  /// half-built object is how that recursion ends up with a null in it.
  HomeActions _actionsFor(WidgetRef ref) => HomeActions(
    openAlbum: onOpenAlbum,
    openArtist: onOpenArtist,
    openPlaylist: onOpenPlaylist,
    play: (item) => _play(ref, item),
    openCollection: (from, collection) => showHomeCollection(from, collection, _actionsFor(ref)),
  );

  Future<void> _play(WidgetRef ref, HomeItemView item) async {
    final tracks = await ref.read(homeTracksProvider)(item);
    if (tracks.isEmpty) return;
    await ref.read(playerProvider.notifier).playAll(tracks, source: _sourceFor(item.kind), sourceRefId: item.refId);
  }

  /// What the queue records as the origin, so `from <album>` keeps working.
  ///
  /// A collection and a query have no library row behind them, so they queue as
  /// the user's own choice -- which is exactly what they are.
  static QueueSource _sourceFor(HomeItemKind kind) => switch (kind) {
    HomeItemKind.album => QueueSource.album,
    HomeItemKind.artist => QueueSource.artist,
    HomeItemKind.playlist => QueueSource.playlist,
    HomeItemKind.query => QueueSource.search,
    HomeItemKind.track || HomeItemKind.collection => QueueSource.user,
  };
}

class _Page extends ConsumerStatefulWidget {
  const _Page({required this.sections, required this.actions, required this.onOpenSettings});

  final List<HomeSectionView> sections;
  final HomeActions actions;
  final VoidCallback? onOpenSettings;

  @override
  ConsumerState<_Page> createState() => _PageState();
}

class _PageState extends ConsumerState<_Page> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sections = widget.sections;
    final dragging = ref.watch(homeDragProvider);

    // A section made from the title bar is put at the top, which is no use if
    // the page is scrolled somewhere else -- it would be created out of
    // sight. The counter is a signal rather than a value: what matters is
    // that one just happened, not which one.
    ref.listen(homeScrollToTopProvider, (_, _) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(0, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    });

    if (sections.isEmpty) {
      return EmptyState(
        icon: Icons.dashboard_customize_outlined,
        title: 'Nothing here yet',
        message: 'Add a section and fill it with whatever you reach for most.',
        action: FilledButton.icon(onPressed: () => newHomeSection(context, ref), icon: const Icon(Icons.add), label: const Text('New section')),
      );
    }

    final blocks = [
      for (var i = 0; i < sections.length; i++)
        HomeSectionBlock(key: ValueKey(sections[i].id), section: sections[i], actions: widget.actions, onViewAll: _viewAll, onAddItems: _addItems, dragIndex: i),
    ];

    // Always reorderable now, with no mode to switch on: the drag starts from
    // a long press on a section's own header (see
    // ReorderableDelayedDragStartListener below), so an ordinary click,
    // right-click and hover all keep working and nothing has to be armed
    // first.
    return DragScroll(
      controller: _scroll,
      // Only while an *item* is in flight. A section drag is the
      // ReorderableListView's own, and it scrolls itself.
      active: dragging != null,
      child: ReorderableListView.builder(
      scrollController: _scroll,
      // Dragging a section is the framework's own gesture and brings its own
      // edge scrolling; DragScroll above only ever sees a HomeDrag.
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 48),
      buildDefaultDragHandles: false,
      itemCount: blocks.length,
      onReorderItem: (oldIndex, newIndex) => _reorderSections(sections, oldIndex, newIndex),
      itemBuilder: (context, i) => Column(
        key: ValueKey('section-${sections[i].id}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Gaps only while something is in flight, so the resting page is
          // unchanged. Before every section as well as after the last: a new
          // section is as likely to belong at the top as anywhere.
          NewSectionGap(
            active: dragging != null,
            onDrop: (dropped) => _newSectionWith(dropped, beforeId: sections[i].id),
          ),
          blocks[i],
          if (i == blocks.length - 1) NewSectionGap(active: dragging != null, onDrop: _newSectionWith),
        ],
      ),
      ),
    );
  }

  /// Makes a section out of whatever was dropped in a gap.
  ///
  /// Named after the item rather than asking: the thing was already in hand
  /// and the name can be changed from the header a moment later, so stopping
  /// to ask would interrupt the one gesture this is for.
  Future<void> _newSectionWith(HomeDrag dropped, {int? beforeId}) async {
    final repository = ref.read(homeRepositoryProvider);
    final sectionId = await repository.addSectionAt(title: dropped.title, beforeId: beforeId);
    await applyHomeDrop(repository, dropped, sectionId: sectionId);
  }

  /// Writes a section drag through to storage.
  ///
  /// [newIndex] arrives already adjusted for the dragged row's removal, so it
  /// indexes straight into the remaining sections -- which is exactly the
  /// "before this id" the repository works in. Past the end means last.
  void _reorderSections(List<HomeSectionView> sections, int oldIndex, int newIndex) {
    final rest = [...sections]..removeAt(oldIndex);
    ref.read(homeRepositoryProvider).moveSection(sections[oldIndex].id, beforeId: newIndex >= rest.length ? null : rest[newIndex].id);
  }

  /// Adds items one after another until the picker is dismissed.
  ///
  /// Looping rather than closing after one: somebody opening this has a
  /// handful of things in mind, and making them reopen the dialog for each is
  /// the difference between arranging a home page and giving up on it.
  Future<void> _addItems(HomeSectionView section) async {
    final repository = ref.read(homeRepositoryProvider);
    while (true) {
      if (!mounted) return;
      final chosen = await addHomeItem(context, ref, title: 'Add to "${section.title}"');
      if (chosen == null) return;
      await repository.addItem(
        sectionId: section.id,
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

  /// Shows everything a list had to cut off at ten.
  void _viewAll(HomeSectionView section) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(section.title),
        content: SizedBox(
          width: 520,
          height: 520,
          child: ListView(
            children: [
              for (final item in section.items)
                Builder(
                  builder: (rowContext) => ListTile(
                    dense: true,
                    title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: item.displaySubtitle == null ? null : Text(item.displaySubtitle!),
                    trailing: IconButton(tooltip: 'Play ${item.title}', icon: const Icon(Icons.play_arrow), onPressed: () => widget.actions.play(item)),
                    onTap: () {
                      Navigator.of(context).pop();
                      widget.actions.open(rowContext, item);
                    },
                  ),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }
}

/// The home page's own caption-strip row.
///
/// One control, because the home page has one mode: either you are listening
/// from it or you are arranging it. Everything else an arrangement needs --
/// layouts, renaming, removing, adding -- appears inside the page itself once
/// Arrange is on, next to the thing it acts on, rather than in a toolbar that
/// would have to name what it was acting on.
class HomeToolbar extends ConsumerWidget {
  const HomeToolbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SectionTitle(icon: Icons.home, label: 'Home'),
        const Spacer(),
        // The only thing here that is not about one particular section.
        // Everything else a section needs now hangs off its own title bar,
        // which is why this page has no arranging mode any more: there was
        // nothing left for the mode to reveal.
        OutlinedButton.icon(onPressed: () => newHomeSection(context, ref), icon: const Icon(Icons.add, size: 18), label: const Text('New section')),
      ],
    );
  }
}

/// Creates a section and puts it at the top of the page.
///
/// At the top rather than at the end because a page is built by adding to the
/// front of it: whatever was just made is the thing being thought about, and
/// a new section appended below eleven others is one nobody sees land. The
/// page scrolls itself up to meet it (see [homeScrollToTopProvider]).
Future<void> newHomeSection(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  var layout = HomeLayout.grid;
  var source = HomeSectionSource.curated;

  final made = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('New section'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
                onSubmitted: (_) => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 16),
              SegmentedButton<HomeLayout>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: HomeLayout.grid, icon: Icon(Icons.grid_view, size: 16), label: Text('Grid')),
                  ButtonSegment(value: HomeLayout.list, icon: Icon(Icons.view_list, size: 16), label: Text('List')),
                ],
                selected: {layout},
                onSelectionChanged: (set) => setState(() => layout = set.first),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: source == HomeSectionSource.recentlyPlayed,
                onChanged: (on) => setState(() => source = on ? HomeSectionSource.recentlyPlayed : HomeSectionSource.curated),
                title: const Text('Fill it from recent listening'),
                subtitle: const Text(
                  'Keeps itself up to date instead of holding what you put '
                  'in it.',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Create')),
        ],
      ),
    ),
  );

  if (made != true) return;
  final repository = ref.read(homeRepositoryProvider);
  final name = controller.text.trim();
  final first = (await repository.watchHome().first).firstOrNull;
  await repository.addSectionAt(title: name.isEmpty ? 'New section' : name, layout: layout, beforeId: first?.id);
  if (source == HomeSectionSource.recentlyPlayed) {
    // addSectionAt has no source of its own: a computed section is rare
    // enough that threading it through would be a parameter nothing else
    // ever passes.
    final made = (await repository.watchHome().first).first;
    await repository.setSectionSource(made.id, source);
  }
  ref.read(homeScrollToTopProvider.notifier).request();
}
