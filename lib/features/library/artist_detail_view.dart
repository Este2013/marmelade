import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart' show QueueSource;
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/expandable_artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import '../../widgets/track_list.dart';

/// One artist: their portrait, their releases, and everything they appear on.
///
/// "Everything they appear on" is the point. Because credits are rows rather
/// than a string on the track, a guest appearance shows up here without the UI
/// doing anything special.
class ArtistDetailView extends ConsumerWidget {
  const ArtistDetailView({
    super.key,
    required this.artistId,
    required this.onOpenAlbum,
    required this.onOpenArtist,
    required this.onBack,
    this.onEditArtist,
    this.onEditTrack,
  });

  final int artistId;
  final void Function(int albumId) onOpenAlbum;
  final void Function(int artistId) onOpenArtist;
  final VoidCallback onBack;
  final void Function(int artistId)? onEditArtist;
  final void Function(int trackId)? onEditTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(artistTracksProvider(artistId));
    final albums = ref.watch(artistAlbumsProvider(artistId));
    final artists = ref.watch(artistsProvider);
    final artist = artists.value?.where((a) => a.id == artistId).firstOrNull;

    return tracks.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load that artist',
        message: '$error',
      ),
      data: (items) => Stack(
        children: [
          Positioned.fill(
            child: ArtworkBackdrop(
              storedPath: artist?.imagePath,
              blur: 90,
              overlayOpacity: 0.88,
            ),
          ),
          TrackList(
            tracks: items,
            onOpenAlbum: onOpenAlbum,
            onOpenArtist: onOpenArtist,
            onEditTrack: onEditTrack,
            // Headed sections per release, which is also the play order: the
            // list is what gets queued, so scattering an album's running order
            // scatters playback too.
            groupByAlbum:
                ref.watch(artistTrackSortProvider) ==
                    LibrarySort.albumThenTrack,
            queueSource: QueueSource.artist,
            queueSourceId: artistId,
            header: _ArtistHeader(
              artist: artist,
              albums: albums.value ?? const [],
              tracks: items,
              onOpenAlbum: onOpenAlbum,
              onBack: onBack,
              onEdit: onEditArtist == null
                  ? null
                  : () => onEditArtist!(artistId),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtistHeader extends ConsumerWidget {
  const _ArtistHeader({
    this.onEdit,
    required this.artist,
    required this.albums,
    required this.tracks,
    required this.onOpenAlbum,
    required this.onBack,
  });

  final ArtistCard? artist;
  final List<AlbumCard> albums;
  final List<TrackRow> tracks;
  /// Opens the artist editor.
  final VoidCallback? onEdit;

  final void Function(int albumId) onOpenAlbum;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final player = ref.read(playerProvider.notifier);
    final trackIds = tracks.map((t) => t.id).toList();

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 20),
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
                    tooltip: 'Edit this artist',
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Not clipped to a circle any more: the hover button sits in
              // the corner, and a clip would cut it in half.
              ExpandableArtwork(
                storedPath: artist?.imagePath,
                size: 168,
                borderRadius: 999,
                owner: PictureOwner.artist,
                id: artist?.id ?? 0,
                title: artist?.name ?? 'Artist',
                fallbackIcon: (artist?.isGroup ?? false)
                    ? Icons.groups_outlined
                    : Icons.person_outline,
                heroTag: artist == null ? null : 'artist-art-${artist!.id}',
                editable: artist != null,
              ),
              const SizedBox(width: 28),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (artist?.isGroup ?? false)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          'GROUP',
                          style: theme.textTheme.labelSmall?.copyWith(
                            letterSpacing: 1.4,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    Text(
                      artist?.name ?? 'Unknown artist',
                      style: theme.textTheme.displaySmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        pluralize(tracks.length, 'track'),
                        pluralize(albums.length, 'release'),
                        if ((artist?.aliasCount ?? 0) > 0)
                          pluralize(artist!.aliasCount, 'alias', 'aliases'),
                      ].join('  ·  '),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: trackIds.isEmpty
                              ? null
                              : () => player.playAll(
                                    trackIds,
                                    source: QueueSource.artist,
                                    sourceRefId: artist?.id,
                                  ),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play'),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: trackIds.isEmpty
                              ? null
                              : () async {
                                  await player.playAll(trackIds,
                                      source: QueueSource.artist,
                                      sourceRefId: artist?.id);
                                  await player.shuffleQueue();
                                  await player.playAt(0);
                                },
                          icon: const Icon(Icons.shuffle),
                          label: const Text('Shuffle'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (albums.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('Releases', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            // A horizontal strip rather than a second grid: the track list is
            // the substance of the page, and releases are a way into it.
            SizedBox(
              height: 176,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: albums.length,
                separatorBuilder: (_, _) => const SizedBox(width: 16),
                itemBuilder: (context, index) {
                  final album = albums[index];
                  return SizedBox(
                    width: 128,
                    child: GestureDetector(
                      onTap: () => onOpenAlbum(album.id),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Artwork(
                            storedPath: album.imagePath,
                            size: 128,
                            borderRadius: 8,
                            fallbackSeed: album.title,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            album.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (album.releaseYear != null)
                            Text(
                              '${album.releaseYear}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Text('All tracks', style: theme.textTheme.titleMedium),
                const Spacer(),
                PopupMenuButton<LibrarySort>(
                  tooltip: 'Sort tracks',
                  initialValue: ref.watch(artistTrackSortProvider),
                  onSelected: (value) =>
                      ref.read(artistTrackSortProvider.notifier).set(value),
                  icon: const Icon(Icons.sort),
                  itemBuilder: (context) => [
                    for (final option in const [
                      LibrarySort.albumThenTrack,
                      LibrarySort.nameAscending,
                      LibrarySort.releaseYear,
                      LibrarySort.mostPlayed,
                      LibrarySort.duration,
                    ])
                      PopupMenuItem(value: option, child: Text(option.label)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}
