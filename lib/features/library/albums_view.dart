import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart' show QueueSource;
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';

/// The albums grid. The app's default view.
class AlbumsView extends ConsumerWidget {
  const AlbumsView({super.key, required this.onOpenAlbum, this.onOpenTrack});

  final void Function(int albumId) onOpenAlbum;

  /// Called when a synthetic single card is tapped.
  final void Function(int trackId)? onOpenTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(albumsProvider);
    final showSingles = ref.watch(showSinglesProvider);
    final sort = ref.watch(albumSortProvider);

    return Column(
      children: [
        _AlbumsToolbar(
          sort: sort,
          showSingles: showSingles,
          count: albums.value?.length ?? 0,
        ),
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
              return _AlbumGrid(
                albums: items,
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

/// Sort control, singles toggle and a count.
class _AlbumsToolbar extends ConsumerWidget {
  const _AlbumsToolbar({
    required this.sort,
    required this.showSingles,
    required this.count,
  });

  final LibrarySort sort;
  final bool showSingles;
  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Row(
        children: [
          Text('Albums', style: theme.textTheme.headlineSmall),
          const SizedBox(width: 12),
          Text(
            pluralize(count, 'album'),
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const Spacer(),
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
      ),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // Aim for cards around 190 px: big enough for the artwork to carry the
        // view, small enough that a wide window shows a lot of library.
        const target = 190.0;
        final columns =
            (constraints.maxWidth / target).floor().clamp(2, 12);

        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
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
              onTap: () {
                // Negative ids mark synthetic single cards.
                if (album.id < 0) {
                  onOpenTrack?.call(-album.id);
                } else {
                  onOpenAlbum(album.id);
                }
              },
            );
          },
        );
      },
    );
  }
}

/// One album card: cover, title, artist.
class _AlbumTile extends ConsumerStatefulWidget {
  const _AlbumTile({required this.album, required this.onTap});

  final AlbumCard album;
  final VoidCallback onTap;

  @override
  ConsumerState<_AlbumTile> createState() => _AlbumTileState();
}

class _AlbumTileState extends ConsumerState<_AlbumTile> {
  var _hovering = false;

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
        onTap: widget.onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: AnimatedScale(
                // A restrained lift on hover: enough to feel alive, not enough
                // to make a scrolling grid feel unstable.
                scale: _hovering ? 1.03 : 1,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
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
                    // Play affordance, revealed on hover so the grid stays
                    // about the artwork until the user reaches for it.
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
