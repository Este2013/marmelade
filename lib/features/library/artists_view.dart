import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../data/db/enums.dart' show QueueSource;
import '../../data/repositories/tag_repository.dart' show TagTarget;
import '../../domain/text/normalize.dart' show matchesQuery;
import '../../widgets/empty_state.dart';
import '../../widgets/filter_field.dart';
import '../../widgets/section_title.dart';
import '../../widgets/selection.dart';
import 'bulk_actions.dart';
import '../../widgets/time_text.dart';

/// Every artist, and the ones that survive the current filter.
///
/// Shared between [ArtistsToolbar] (which only needs the counts) and the
/// grid (which needs the filtered list) so the filtering itself happens once
/// regardless of which of them rebuilds.
final artistsShownProvider =
    Provider<({List<ArtistCard> all, List<ArtistCard> shown})>((ref) {
  final all = ref.watch(artistsProvider).value ?? const <ArtistCard>[];
  final filter = ref.watch(artistFilterProvider);
  final shown = [
    for (final artist in all)
      if (matchesQuery(filter, [artist.name])) artist,
  ];
  return (all: all, shown: shown);
});

/// The artists and groups list.
///
/// Groups appear here alongside people, marked as groups, because in this app a
/// group *is* an artist - the same table, the same crediting - and hiding them
/// in a separate list would misrepresent the model.
class ArtistsView extends ConsumerWidget {
  const ArtistsView({
    super.key,
    required this.onOpenArtist,
    this.onOpenReview,
  });

  final void Function(int artistId) onOpenArtist;

  /// Opens the credit review queue, when there is anything in it.
  final VoidCallback? onOpenReview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(artistsProvider);
    final filter = ref.watch(artistFilterProvider);
    final shown = ref.watch(artistsShownProvider).shown;
    final pendingCredits = ref.watch(pendingCreditCountProvider).value ?? 0;

    return Column(
      children: [
        if (pendingCredits > 0 && onOpenReview != null)
          _ReviewBanner(count: pendingCredits, onOpen: onOpenReview!),
        _ArtistSelectionBar(artists: shown, onOpenArtist: onOpenArtist),
        Expanded(
          child: artists.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not read the library',
              message: '$error',
            ),
            data: (items) {
              if (items.isEmpty) {
                return const EmptyState(
                  icon: Icons.person_outline,
                  title: 'No artists yet',
                  message: 'Artists appear once music has been indexed.',
                );
              }
              if (shown.isEmpty) {
                return FilteredEmpty(
                  query: filter,
                  noun: 'artist',
                  onClear: () =>
                      ref.read(artistFilterProvider.notifier).set(''),
                );
              }
              return _ArtistGrid(artists: shown, onOpen: onOpenArtist);
            },
          ),
        ),
      ],
    );
  }
}

/// Title, count, filter and sort -- the artists section's own toolbar,
/// merged into the window's title bar. See [AppShell] and
/// `WindowChrome.content`.
///
/// The credit-review banner is deliberately not part of this: it is
/// contextual to the list underneath (it disappears once the queue is
/// empty), not a toolbar control, so it stays in [ArtistsView]'s own body.
class ArtistsToolbar extends ConsumerWidget {
  const ArtistsToolbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sort = ref.watch(artistSortProvider);
    final filter = ref.watch(artistFilterProvider);
    final data = ref.watch(artistsShownProvider);

    return Row(
      children: [
        const SectionTitle(icon: Icons.people, label: 'Artists'),
        const SizedBox(width: 12),
        Text(
          filter.isEmpty
              ? pluralize(data.all.length, 'artist')
              : '${data.shown.length} of ${pluralize(data.all.length, 'artist')}',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: FilterField(
                value: filter,
                width: null,
                hint: 'Filter artists',
                onChanged: (value) =>
                    ref.read(artistFilterProvider.notifier).set(value),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        PopupMenuButton<LibrarySort>(
          tooltip: 'Sort',
          initialValue: sort,
          onSelected: (value) =>
              ref.read(artistSortProvider.notifier).set(value),
          icon: const Icon(Icons.sort),
          itemBuilder: (context) => [
            for (final option in const [
              LibrarySort.nameAscending,
              LibrarySort.nameDescending,
              LibrarySort.trackCount,
              LibrarySort.recentlyAdded,
            ])
              PopupMenuItem(value: option, child: Text(option.label)),
          ],
        ),
      ],
    );
  }
}

class _ArtistGrid extends StatelessWidget {
  const _ArtistGrid({required this.artists, required this.onOpen});

  final List<ArtistCard> artists;
  final void Function(int artistId) onOpen;

  @override
  Widget build(BuildContext context) {
    final order = [for (final artist in artists) artist.id];

    return LayoutBuilder(
      builder: (context, constraints) {
        const target = 170.0;
        final columns = (constraints.maxWidth / target).floor().clamp(2, 12);
        return GridView.builder(
          // A few pixels of headroom at the top: the hover lift scales a
          // tile up in place, and with no top padding the top row's lift
          // pokes past the grid's own clip boundary and gets cut off.
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 18,
            mainAxisSpacing: 22,
            childAspectRatio: 1 / 1.28,
          ),
          itemCount: artists.length,
          itemBuilder: (context, index) => _ArtistTile(
            artist: artists[index],
            order: order,
            onOpen: onOpen,
          ),
        );
      },
    );
  }
}

class _ArtistTile extends ConsumerStatefulWidget {
  const _ArtistTile({
    required this.artist,
    required this.order,
    required this.onOpen,
  });

  final ArtistCard artist;
  final List<int> order;
  final void Function(int artistId) onOpen;

  @override
  ConsumerState<_ArtistTile> createState() => _ArtistTileState();
}

class _ArtistTileState extends ConsumerState<_ArtistTile> {
  var _hovering = false;

  List<MenuAction> _menu() {
    final ids = ref.read(selectionProvider(SelectionScope.artists)).ids;
    final many = ids.length > 1;
    final player = ref.read(playerProvider.notifier);
    final bulk = BulkActions(ref);

    return [
      if (!many)
        MenuAction(
          label: 'Open',
          icon: Icons.open_in_new,
          onSelected: () => widget.onOpen(widget.artist.id),
        ),
      MenuAction(
        label: many ? 'Play everything by these ${ids.length}' : 'Play all',
        icon: Icons.play_arrow,
        onSelected: () async {
          final tracks = await bulk.tracksOfArtists(ids);
          if (tracks.isNotEmpty) {
            await player.playAll(tracks, source: QueueSource.artist);
          }
        },
      ),
      MenuAction(
        label: 'Add to the queue',
        icon: Icons.playlist_add,
        onSelected: () async =>
            player.addToQueue(await bulk.tracksOfArtists(ids)),
      ),
      const MenuAction.separator(),
      MenuAction(
        label: 'Add to a playlist',
        icon: Icons.library_add_outlined,
        onSelected: () async {
          final tracks = await bulk.tracksOfArtists(ids);
          if (mounted) await addTracksToPlaylist(context, ref, tracks);
        },
      ),
      MenuAction(
        label: many ? 'Tag these ${ids.length} artists' : 'Add a tag',
        icon: Icons.label_outline,
        onSelected: () => tagSelection(
          context,
          ref,
          target: TagTarget.artist,
          ids: ids,
          noun: 'artist',
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artist = widget.artist;
    final selected = ref.watch(
      selectionProvider(SelectionScope.artists)
          .select((s) => s.contains(artist.id)),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: () {
          if (applyClick(
            ref,
            SelectionScope.artists,
            artist.id,
            widget.order,
          )) {
            widget.onOpen(artist.id);
          }
        },
        onSecondaryTapUp: (details) {
          prepareContextMenu(ref, SelectionScope.artists, artist.id);
          showItemMenu(context, details.globalPosition, _menu());
        },
        child: Column(
          children: [
            Expanded(
              child: AnimatedScale(
                scale: _hovering ? 1.04 : 1,
                duration: const Duration(milliseconds: 160),
                // A ring rather than a rectangle: the portrait is round, and a
                // square highlight around a circle reads as a rendering bug.
                curve: Curves.easeOutCubic,
                // Circular for people, rounded-square for groups: a shape
                // difference reads faster than a label.
                child: Container(
                  padding: selected ? const EdgeInsets.all(3) : EdgeInsets.zero,
                  decoration: selected
                      ? BoxDecoration(
                          shape: artist.isGroup
                              ? BoxShape.rectangle
                              : BoxShape.circle,
                          borderRadius:
                              artist.isGroup ? BorderRadius.circular(15) : null,
                          color: theme.colorScheme.primary,
                        )
                      : null,
                  child: ClipPath(
                    clipper: artist.isGroup ? null : const _CircleClipper(),
                    child: Artwork(
                      storedPath: artist.imagePath,
                      borderRadius: artist.isGroup ? 12 : 999,
                      fallbackSeed: artist.name,
                      fallbackIcon: artist.isGroup
                          ? Icons.groups_outlined
                          : Icons.person_outline,
                      heroTag: 'artist-art-${artist.id}',
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              artist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              [
                pluralize(artist.trackCount, 'track'),
                if (artist.isGroup && artist.memberCount > 0)
                  pluralize(artist.memberCount, 'member'),
                if (artist.aliasCount > 0) '${artist.aliasCount} alias',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Clips a widget to a circle inscribed in its box.
class _CircleClipper extends CustomClipper<Path> {
  const _CircleClipper();

  @override
  Path getClip(Size size) => Path()
    ..addOval(Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: size.shortestSide / 2,
    ));

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => false;
}

/// Says how many credits the resolver could not decide, and opens the queue.
///
/// This list is where an unsplit credit does its damage -- a composite name
/// sitting among the real artists -- so this is where the offer to fix it
/// belongs. It disappears entirely once the queue is empty.
class _ReviewBanner extends StatelessWidget {
  const _ReviewBanner({required this.count, required this.onOpen});

  final int count;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      color: scheme.secondaryContainer,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 16, 12),
          child: Row(
            children: [
              Icon(Icons.rule, size: 20, color: scheme.onSecondaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${pluralize(count, 'credit')} could not be split '
                  'confidently, so ${count == 1 ? 'it is' : 'they are'} '
                  'waiting on you.',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSecondaryContainer),
                ),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: onOpen, child: const Text('Review')),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bulk actions for a selection of artists.
class _ArtistSelectionBar extends ConsumerWidget {
  const _ArtistSelectionBar({
    required this.artists,
    required this.onOpenArtist,
  });

  final List<ArtistCard> artists;
  final void Function(int artistId) onOpenArtist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider(SelectionScope.artists));
    final ids = selection.ids;
    final player = ref.read(playerProvider.notifier);
    final bulk = BulkActions(ref);

    return SelectionBar(
      scope: SelectionScope.artists,
      noun: 'artist',
      onSelectAll: () => ref
          .read(selectionProvider(SelectionScope.artists).notifier)
          .selectAll([for (final artist in artists) artist.id]),
      actions: [
        MenuAction(
          label: 'Queue',
          icon: Icons.playlist_add,
          onSelected: () async =>
              player.addToQueue(await bulk.tracksOfArtists(ids)),
        ),
        MenuAction(
          label: 'Playlist',
          icon: Icons.library_add_outlined,
          onSelected: () async {
            final tracks = await bulk.tracksOfArtists(ids);
            if (context.mounted) {
              await addTracksToPlaylist(context, ref, tracks);
            }
          },
        ),
        MenuAction(
          label: 'Tag',
          icon: Icons.label_outline,
          onSelected: () => tagSelection(
            context,
            ref,
            target: TagTarget.artist,
            ids: ids,
            noun: 'artist',
          ),
        ),
        // Two or more of the same person under different spellings is the
        // reason this library needs an artist editor at all, and selecting
        // them is the fastest way to say so.
        if (ids.length > 1)
          MenuAction(
            label: 'Merge',
            icon: Icons.merge_type,
            onSelected: () => _merge(context, ref, ids),
          ),
      ],
    );
  }

  /// Asks which artist to keep, then moves every reference onto it.
  Future<void> _merge(
    BuildContext context,
    WidgetRef ref,
    Set<int> ids,
  ) async {
    final candidates = [
      for (final artist in artists)
        if (ids.contains(artist.id)) artist,
    ]..sort((a, b) => b.trackCount.compareTo(a.trackCount));
    if (candidates.length < 2) return;

    final keep = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Merge ${candidates.length} artists'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Which name should survive? Every credit, alias, album and '
                'tag from the others moves onto it, and the others are '
                'deleted.',
              ),
              const SizedBox(height: 16),
              for (final artist in candidates)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.person_outline),
                  title: Text(artist.name),
                  subtitle: Text(pluralize(artist.trackCount, 'track')),
                  onTap: () => Navigator.of(context).pop(artist.id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (keep == null) return;

    await ref.read(editRepositoryProvider).mergeArtists(
          keep,
          ids.where((id) => id != keep).toList(),
        );
    ref.read(selectionProvider(SelectionScope.artists).notifier).clear();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Merged ${ids.length} artists into one.'),
      ),
    );
  }
}
