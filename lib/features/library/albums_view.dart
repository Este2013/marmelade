import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart' show QueueSource;
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../data/repositories/tag_repository.dart' show TagTarget;
import '../../domain/text/normalize.dart' show matchesQuery;
import '../../widgets/empty_state.dart';
import '../../widgets/filter_field.dart';
import '../../widgets/section_title.dart';
import '../../widgets/selection.dart';
import 'bulk_actions.dart';
import '../../widgets/time_text.dart';

/// Every album, and the ones that survive the current filter.
///
/// Shared between [AlbumsToolbar] (which only needs the counts) and the grid
/// (which needs the filtered list) so the filtering itself -- matched on the
/// two things visible on a card -- happens once regardless of which of them
/// rebuilds. Kept beside the view it belongs to rather than in the shared
/// providers file: this is this view's own derived state, not library data.
final albumsShownProvider =
    Provider<({List<AlbumCard> all, List<AlbumCard> shown})>((ref) {
  final all = ref.watch(albumsProvider).value ?? const <AlbumCard>[];
  final filter = ref.watch(albumFilterProvider);
  final shown = [
    for (final album in all)
      if (matchesQuery(filter, [album.title, album.artistName])) album,
  ];
  return (all: all, shown: shown);
});

/// The albums grid. The app's default view.
class AlbumsView extends ConsumerWidget {
  const AlbumsView({super.key, required this.onOpenAlbum, this.onOpenTrack});

  final void Function(int albumId) onOpenAlbum;

  /// Called when a synthetic single card is tapped.
  final void Function(int trackId)? onOpenTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(albumsProvider);
    final filter = ref.watch(albumFilterProvider);
    final shown = ref.watch(albumsShownProvider).shown;

    return Column(
      children: [
        _AlbumSelectionBar(albums: shown),
        Expanded(
          child: albums.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => EmptyState(
              icon: Icons.error_outline,
              title: 'Could not read the library',
              message: '$error',
            ),
            data: (items) {
              if (items.isEmpty) {
                return const LibraryEmptyState();
              }
              if (shown.isEmpty) {
                return FilteredEmpty(
                  query: filter,
                  noun: 'album',
                  onClear: () =>
                      ref.read(albumFilterProvider.notifier).set(''),
                );
              }
              return _AlbumGrid(
                albums: shown,
                onOpenAlbum: onOpenAlbum,
                onOpenTrack: onOpenTrack,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Title, count, filter, singles toggle and sort -- the albums section's own
/// toolbar, merged into the window's title bar rather than sitting in a
/// separate row underneath it. See [AppShell] and `WindowChrome.content`.
class AlbumsToolbar extends ConsumerWidget {
  const AlbumsToolbar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final showSingles = ref.watch(showSinglesProvider);
    final sort = ref.watch(albumSortProvider);
    final filter = ref.watch(albumFilterProvider);
    final data = ref.watch(albumsShownProvider);

    return Row(
      children: [
        const SectionTitle(icon: Icons.album, label: 'Albums'),
        const SizedBox(width: 12),
        Text(
          filter.isEmpty
              ? pluralize(data.all.length, 'album')
              : '${data.shown.length} of ${pluralize(data.all.length, 'album')}',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(width: 16),
        // Takes the slack rather than a fixed width, and capped so it does
        // not sprawl across a wide window.
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: FilterField(
                value: filter,
                width: null,
                hint: 'Filter albums',
                onChanged: (value) =>
                    ref.read(albumFilterProvider.notifier).set(value),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // A plain visible toggle rather than something buried in a menu: the
        // user asked for singles to be one click away.
        FilterChip(
          selected: showSingles,
          onSelected: (value) =>
              ref.read(showSinglesProvider.notifier).set(value),
          avatar: const Icon(Icons.music_note_outlined, size: 18),
          label: const Text('Singles'),
          tooltip: 'Also show tracks that belong to no album',
        ),
        const SizedBox(width: 8),
        PopupMenuButton<LibrarySort>(
          tooltip: 'Sort',
          initialValue: sort,
          onSelected: (value) =>
              ref.read(albumSortProvider.notifier).set(value),
          icon: const Icon(Icons.sort),
          itemBuilder: (context) => [
            for (final option in const [
              LibrarySort.nameAscending,
              LibrarySort.nameDescending,
              LibrarySort.recentlyAdded,
              LibrarySort.releaseYear,
              LibrarySort.trackCount,
              LibrarySort.duration,
              LibrarySort.random,
            ])
              PopupMenuItem(value: option, child: Text(option.label)),
          ],
        ),
      ],
    );
  }
}

/// A responsive grid of album cards.
class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({
    required this.albums,
    required this.onOpenAlbum,
    required this.onOpenTrack,
  });

  final List<AlbumCard> albums;
  final void Function(int albumId) onOpenAlbum;
  final void Function(int trackId)? onOpenTrack;

  @override
  Widget build(BuildContext context) {
    // The ids in the order shown, so a Shift-click means "between these two on
    // screen" rather than between by id, which after any sort is meaningless.
    final order = [for (final album in albums) album.id];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Aim for cards around 190 px: big enough for the artwork to carry the
        // view, small enough that a wide window shows a lot of library.
        const target = 190.0;
        final columns =
            (constraints.maxWidth / target).floor().clamp(2, 12);

        return GridView.builder(
          // A few pixels of headroom at the top: the hover lift scales a
          // tile up in place, and with no top padding the top row's lift
          // pokes past the grid's own clip boundary and gets cut off.
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 18,
            mainAxisSpacing: 22,
            // Extra height for the two text lines beneath the square cover.
            childAspectRatio: 1 / 1.30,
          ),
          itemCount: albums.length,
          itemBuilder: (context, index) {
            final album = albums[index];
            return _AlbumTile(
              album: album,
              order: order,
              onOpenAlbum: onOpenAlbum,
              onOpenTrack: onOpenTrack,
            );
          },
        );
      },
    );
  }
}

/// One album card: cover, title, artist.
class _AlbumTile extends ConsumerStatefulWidget {
  const _AlbumTile({
    required this.album,
    required this.order,
    required this.onOpenAlbum,
    required this.onOpenTrack,
  });

  final AlbumCard album;
  final List<int> order;
  final void Function(int albumId) onOpenAlbum;
  final void Function(int trackId)? onOpenTrack;

  @override
  ConsumerState<_AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends ConsumerState<_AlbumTile> {
  var _hovering = false;

  bool get _selected => ref.watch(
        selectionProvider(SelectionScope.albums)
            .select((s) => s.contains(widget.album.id)),
      );

  /// Negative ids mark synthetic single cards, which open their track.
  void _open() {
    final album = widget.album;
    if (album.id < 0) {
      widget.onOpenTrack?.call(-album.id);
    } else {
      widget.onOpenAlbum(album.id);
    }
  }

  List<MenuAction> _menu() {
    final selection = ref.read(selectionProvider(SelectionScope.albums));
    final ids = selection.ids.where((id) => id > 0).toSet();
    final many = ids.length > 1;
    final player = ref.read(playerProvider.notifier);
    final bulk = BulkActions(ref);

    return [
      if (!many)
        MenuAction(
          label: 'Open',
          icon: Icons.open_in_new,
          onSelected: _open,
        ),
      MenuAction(
        label: many ? 'Play these ${ids.length} albums' : 'Play',
        icon: Icons.play_arrow,
        onSelected: () async {
          final tracks = await bulk.tracksOfAlbums(ids);
          if (tracks.isNotEmpty) {
            await player.playAll(tracks, source: QueueSource.album);
          }
        },
      ),
      MenuAction(
        label: 'Play next',
        icon: Icons.playlist_play,
        onSelected: () async =>
            player.playNext(await bulk.tracksOfAlbums(ids)),
      ),
      MenuAction(
        label: 'Add to the queue',
        icon: Icons.playlist_add,
        onSelected: () async =>
            player.addToQueue(await bulk.tracksOfAlbums(ids)),
      ),
      const MenuAction.separator(),
      MenuAction(
        label: 'Add to a playlist',
        icon: Icons.library_add_outlined,
        onSelected: () async {
          final tracks = await bulk.tracksOfAlbums(ids);
          if (mounted) {
            await addTracksToPlaylist(context, ref, tracks);
          }
        },
      ),
      MenuAction(
        label: many ? 'Tag these ${ids.length} albums' : 'Add a tag',
        icon: Icons.label_outline,
        onSelected: () => tagSelection(
          context,
          ref,
          target: TagTarget.album,
          ids: ids,
          noun: 'album',
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final album = widget.album;
    final isSingle = album.id < 0;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          // Ctrl and Shift manage the selection; a plain click keeps doing
          // what this grid has always done, and clears it.
          if (applyClick(ref, SelectionScope.albums, album.id, widget.order)) {
            _open();
          }
        },
        onSecondaryTapUp: (details) {
          prepareContextMenu(ref, SelectionScope.albums, album.id);
          showItemMenu(context, details.globalPosition, _menu());
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedScale(
                    // A restrained lift on hover: enough to feel alive, not
                    // enough to make a scrolling grid feel unstable.
                    //
                    // Around the cover alone, not the whole tile. A transform
                    // moves the semantics of everything inside it, and moving
                    // an interactive node every frame of an animation is what
                    // floods the Windows accessibility bridge -- the play
                    // button was inside this, and hovering the grid threw
                    // hundreds of AXTree errors. The cover has no semantics of
                    // its own, so scaling it costs nothing.
                    scale: _hovering ? 1.03 : 1,
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: _selected
                            ? Border.all(
                                color: theme.colorScheme.primary,
                                width: 3,
                              )
                            : null,
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
                      child: Artwork(
                        storedPath: album.imagePath,
                        borderRadius: 10,
                        fallbackSeed: '${album.title}${album.artistName}',
                        fallbackIcon: isSingle
                            ? Icons.music_note_outlined
                            : Icons.album_outlined,
                        heroTag: isSingle ? null : 'album-art-${album.id}',
                      ),
                    ),
                  ),
                  // Play affordance, revealed on hover so the grid stays
                  // about the artwork until the user reaches for it. Outside
                  // the scale, so it holds still while the cover lifts.
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: AnimatedOpacity(
                      opacity: _hovering ? 1 : 0,
                      duration: const Duration(milliseconds: 140),
                      // Kept in the semantics tree at every opacity. By
                      // default AnimatedOpacity drops its child's semantics
                      // at zero, so hovering added and removed a node per
                      // tile per frame - which floods the Windows
                      // accessibility bridge with tree updates it cannot
                      // apply, and eventually crashes it. Always including
                      // it is also plainly better: a screen reader can reach
                      // the play button without having to hover.
                      alwaysIncludeSemantics: true,
                      child: _PlayOverlayButton(album: album),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    album.artistName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                if (album.releaseYear != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    '${album.releaseYear}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The circular play button that appears over a hovered cover.
class _PlayOverlayButton extends ConsumerWidget {
  const _PlayOverlayButton({required this.album});

  final AlbumCard album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      shape: const CircleBorder(),
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _play(ref),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.play_arrow, color: scheme.onPrimary, size: 24),
        ),
      ),
    );
  }

  Future<void> _play(WidgetRef ref) async {
    final player = ref.read(playerProvider.notifier);
    if (album.id < 0) {
      await player.playTrack(-album.id);
      return;
    }
    // Read the album's tracks in playing order and queue the lot, so pressing
    // play on a cover means "play this album" rather than "play one track".
    final tracks = await ref
        .read(libraryRepositoryProvider)
        .watchTracks(albumId: album.id)
        .first;
    if (tracks.isEmpty) return;
    await player.playAll(
      tracks.map((t) => t.id).toList(),
      source: QueueSource.album,
      sourceRefId: album.id,
    );
  }
}

/// The bulk actions for a selection of albums.
class _AlbumSelectionBar extends ConsumerWidget {
  const _AlbumSelectionBar({required this.albums});

  /// The albums currently shown, so "Select all" means what is on screen --
  /// including after a filter has narrowed it.
  final List<AlbumCard> albums;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider(SelectionScope.albums));
    // Synthetic single cards have negative ids and are not albums; they cannot
    // be tagged or opened as one.
    final ids = selection.ids.where((id) => id > 0).toSet();
    final player = ref.read(playerProvider.notifier);
    final bulk = BulkActions(ref);

    return SelectionBar(
      scope: SelectionScope.albums,
      noun: 'album',
      onSelectAll: () => ref
          .read(selectionProvider(SelectionScope.albums).notifier)
          .selectAll([for (final album in albums) album.id]),
      actions: [
        MenuAction(
          label: 'Queue',
          icon: Icons.playlist_add,
          onSelected: () async =>
              player.addToQueue(await bulk.tracksOfAlbums(ids)),
        ),
        MenuAction(
          label: 'Playlist',
          icon: Icons.library_add_outlined,
          onSelected: () async {
            final tracks = await bulk.tracksOfAlbums(ids);
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
            target: TagTarget.album,
            ids: ids,
            noun: 'album',
          ),
        ),
      ],
    );
  }
}
