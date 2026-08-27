import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart' show QueueSource;
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import '../../widgets/track_list.dart';

/// One album: large artwork, its details, and its tracks.
class AlbumDetailView extends ConsumerWidget {
  const AlbumDetailView({
    super.key,
    required this.albumId,
    required this.onOpenArtist,
    required this.onBack,
    this.onEditAlbum,
    this.onEditTrack,
  });

  final int albumId;
  final void Function(int artistId) onOpenArtist;
  final VoidCallback onBack;
  final void Function(int albumId)? onEditAlbum;
  final void Function(int trackId)? onEditTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref.watch(albumDetailProvider(albumId));
    final tracks = ref.watch(albumTracksProvider(albumId));

    return album.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load that album',
        message: '$error',
      ),
      data: (card) {
        if (card == null) {
          return const EmptyState(
            icon: Icons.album_outlined,
            title: 'Album not found',
          );
        }
        return Stack(
          children: [
            // The blurred cover behind everything is what makes an album page
            // feel like that album rather than a generic table.
            Positioned.fill(
              child: ArtworkBackdrop(
                storedPath: card.imagePath,
                blur: 90,
                overlayOpacity: 0.86,
              ),
            ),
            tracks.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyState(
                icon: Icons.error_outline,
                title: 'Could not load tracks',
                message: '$error',
              ),
              data: (items) => TrackList(
                tracks: items,
                showArtwork: false,
                showAlbum: false,
                showTrackNumbers: true,
                onOpenArtist: onOpenArtist,
                onEditTrack: onEditTrack,
                queueSource: QueueSource.album,
                queueSourceId: albumId,
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                header: _AlbumHeader(
                  album: card,
                  tracks: items,
                  onOpenArtist: onOpenArtist,
                  onBack: onBack,
                  onEdit: onEditAlbum == null
                      ? null
                      : () => onEditAlbum!(albumId),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Cover, title, artist and the album-level actions.
class _AlbumHeader extends ConsumerWidget {
  const _AlbumHeader({
    required this.album,
    required this.tracks,
    required this.onOpenArtist,
    required this.onBack,
    this.onEdit,
  });

  final AlbumCard album;
  final List<TrackRow> tracks;
  final void Function(int artistId) onOpenArtist;
  final VoidCallback onBack;

  /// Opens the album editor.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final player = ref.read(playerProvider.notifier);
    final trackIds = tracks.map((t) => t.id).toList();

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
                const Spacer(),
                if (onEdit != null)
                  IconButton(
                    tooltip: 'Edit this album',
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                // Track order is what an album is normally read in, but a
                // long compilation is easier to search alphabetically and a
                // soundtrack is sometimes easier by length.
                PopupMenuButton<LibrarySort>(
                  tooltip: 'Sort tracks',
                  initialValue: ref.watch(albumTrackSortProvider),
                  onSelected: (value) =>
                      ref.read(albumTrackSortProvider.notifier).set(value),
                  icon: const Icon(Icons.sort),
                  itemBuilder: (context) => [
                    for (final option in const [
                      LibrarySort.trackNumber,
                      LibrarySort.nameAscending,
                      LibrarySort.duration,
                      LibrarySort.mostPlayed,
                      LibrarySort.random,
                    ])
                      PopupMenuItem(value: option, child: Text(option.label)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Artwork(
                storedPath: album.imagePath,
                size: 200,
                borderRadius: 12,
                fallbackSeed: '${album.title}${album.artistName}',
                heroTag: 'album-art-${album.id}',
              ),
              const SizedBox(width: 28),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      album.title,
                      style: theme.textTheme.displaySmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                    // The album artist is a link, not decoration.
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (album.artistId != null)
                          _HeaderLink(
                            text: album.artistName,
                            onTap: () => onOpenArtist(album.artistId!),
                          )
                        else
                          Text(
                            album.artistName,
                            style: theme.textTheme.titleMedium,
                          ),
                        Text(
                          '  ·  ${[
                            if (album.releaseYear != null) '${album.releaseYear}',
                            pluralize(album.trackCount, 'track'),
                            formatDurationLong(album.totalDuration),
                          ].join('  ·  ')}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: trackIds.isEmpty
                              ? null
                              : () => player.playAll(
                                    trackIds,
                                    source: QueueSource.album,
                                    sourceRefId: album.id,
                                  ),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play'),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: trackIds.isEmpty
                              ? null
                              : () async {
                                  await player.playAll(
                                    trackIds,
                                    source: QueueSource.album,
                                    sourceRefId: album.id,
                                  );
                                  await player.shuffleQueue();
                                  await player.playAt(0);
                                },
                          icon: const Icon(Icons.shuffle),
                          label: const Text('Shuffle'),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          tooltip: 'Add to queue',
                          onPressed: trackIds.isEmpty
                              ? null
                              : () => player.addToQueue(
                                    trackIds,
                                    source: QueueSource.album,
                                    sourceRefId: album.id,
                                  ),
                          icon: const Icon(Icons.playlist_add),
                        ),
                        IconButton(
                          tooltip: album.isFavorite
                              ? 'Remove from favourites'
                              : 'Favourite',
                          onPressed: () => ref
                              .read(databaseProvider)
                              .customStatement(
                                'UPDATE albums SET is_favorite = '
                                'NOT is_favorite WHERE id = ?',
                                [album.id],
                              ),
                          icon: Icon(
                            album.isFavorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: album.isFavorite
                                ? theme.colorScheme.primary
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A heading-sized link.
class _HeaderLink extends StatefulWidget {
  const _HeaderLink({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  State<_HeaderLink> createState() => _HeaderLinkState();
}

class _HeaderLinkState extends State<_HeaderLink> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.text,
          style: theme.textTheme.titleMedium?.copyWith(
            color: _hovering ? theme.colorScheme.primary : null,
            decoration:
                _hovering ? TextDecoration.underline : TextDecoration.none,
            decorationColor: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
