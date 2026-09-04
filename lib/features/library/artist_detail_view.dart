import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart' show QueueSource;
import '../../data/repositories/edit_repository.dart' show LinkRow;
import '../../data/repositories/tag_repository.dart' show AttachedTag, TagTarget;
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/expandable_artwork.dart';
import '../../widgets/time_text.dart';
import '../../widgets/title_with_actions.dart';
import '../../widgets/track_list.dart';
import '../edit/artist_links_dialog.dart';
import '../edit/link_icon_button.dart';
import '../tags/tag_line.dart';

/// One artist: their portrait, their releases, and everything they appear on.
///
/// "Everything they appear on" is the point. Because credits are rows rather
/// than a string on the track, a guest appearance shows up here without the UI
/// doing anything special.
class ArtistDetailView extends ConsumerWidget {
  const ArtistDetailView({super.key, required this.artistId, required this.onOpenAlbum, required this.onOpenArtist, this.onEditArtist, this.onEditTrack, this.onOpenTag, this.topInset = 0});

  final int artistId;
  final void Function(int albumId) onOpenAlbum;
  final void Function(int artistId) onOpenArtist;
  final void Function(int artistId)? onEditArtist;
  final void Function(int trackId)? onEditTrack;

  /// Opens a tag's page, when there is somewhere to open it.
  final void Function(int tagId)? onOpenTag;

  /// Space to leave clear at the top for the window's caption strip.
  ///
  /// The blurred backdrop bleeds all the way to the top of the window now
  /// that its own back/edit row lives in the strip (see [ArtistDetailChrome]
  /// and [AppShell]), so without this the name and Play/Shuffle row would
  /// start underneath the window buttons.
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(artistTracksProvider(artistId));
    final albums = ref.watch(artistAlbumsProvider(artistId));
    final artists = ref.watch(artistsProvider);
    final artist = artists.value?.where((a) => a.id == artistId).firstOrNull;

    return tracks.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(icon: Icons.error_outline, title: 'Could not load that artist', message: '$error'),
      data: (items) => Stack(
        children: [
          Positioned.fill(child: ArtworkBackdrop(storedPath: artist?.imagePath, blur: 90, overlayOpacity: 0.88)),
          TrackList(
            tracks: items,
            onOpenAlbum: onOpenAlbum,
            onOpenArtist: onOpenArtist,
            onEditTrack: onEditTrack,
            // Headed sections per release, which is also the play order: the
            // list is what gets queued, so scattering an album's running order
            // scatters playback too.
            groupByAlbum: ref.watch(artistTrackSortProvider) == LibrarySort.albumThenTrack,
            queueSource: QueueSource.artist,
            queueSourceId: artistId,
            header: _ArtistHeader(
              artist: artist,
              albums: albums.value ?? const [],
              tracks: items,
              onOpenAlbum: onOpenAlbum,
              onEdit: onEditArtist == null ? null : () => onEditArtist!(artistId),
              onOpenTag: onOpenTag,
              topInset: topInset,
            ),
          ),
        ],
      ),
    );
  }
}

/// An artist page's way back, in the window's title bar.
///
/// Only Back. Editing the artist and editing their links used to sit here
/// too, but an action on the artist belongs next to the artist's name, not up
/// among the window buttons -- see [TitleWithActions]. Back stays because it
/// is about the page rather than the artist, and because it has to be
/// reachable after the header has scrolled away.
class ArtistDetailChrome extends StatelessWidget {
  const ArtistDetailChrome({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(tooltip: 'Back', onPressed: onBack, icon: const Icon(Icons.arrow_back)),
      ],
    );
  }
}

class _ArtistHeader extends ConsumerWidget {
  const _ArtistHeader({this.onEdit, required this.artist, required this.albums, required this.tracks, required this.onOpenAlbum, this.onOpenTag, this.topInset = 0});

  final ArtistCard? artist;
  final List<AlbumCard> albums;
  final List<TrackRow> tracks;

  /// Opens the artist editor. Also gates whether the links dialog is offered,
  /// since both are "edit this artist" and a page that cannot do one has no
  /// business offering the other.
  final VoidCallback? onEdit;

  final void Function(int albumId) onOpenAlbum;
  final void Function(int tagId)? onOpenTag;
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final player = ref.read(playerProvider.notifier);
    final trackIds = tracks.map((t) => t.id).toList();
    final links = artist == null ? const <LinkRow>[] : ref.watch(artistLinksProvider(artist!.id)).value ?? const [];
    // Watched here as well as inside the TagLine, because the header has to
    // decide whether there is a line to show at all -- and Riverpod hands
    // both readers the same cached list.
    final tags = artist == null
        ? const <AttachedTag>[]
        : ref.watch(attachedTagsProvider((target: TagTarget.artist, id: artist!.id))).value ?? const [];
    final canEdit = artist != null && onEdit != null;

    return Padding(
      padding: EdgeInsets.only(top: topInset + 20, bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                fallbackIcon: (artist?.isGroup ?? false) ? Icons.groups_outlined : Icons.person_outline,
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
                        child: Text('GROUP', style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.4, color: theme.colorScheme.primary)),
                      ),
                    TitleWithActions(
                      title: Text(artist?.name ?? 'Unknown artist', style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600)),
                      actions: [
                        if (canEdit)
                          IconButton(
                            tooltip: 'Edit this artist',
                            onPressed: onEdit,
                            icon: const Icon(Icons.edit_outlined),
                            iconSize: 20,
                          ),
                        if (canEdit)
                          IconButton(
                            // The links themselves are in the tag line now, so
                            // this button is only ever about changing them.
                            tooltip: links.isEmpty ? 'Add a link' : 'Edit links',
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (context) => ArtistLinksDialog(
                                artistId: artist!.id,
                                artistName: artist!.name,
                              ),
                            ),
                            icon: const Icon(Icons.link),
                            iconSize: 20,
                          ),
                        // Only while there is nothing tagged. Once there is,
                        // the tag line below is visible and carries its own
                        // add chip.
                        if (artist != null && tags.isEmpty)
                          IconButton(
                            tooltip: 'Add a tag',
                            onPressed: () => addTagTo(context, ref, TagTarget.artist, artist!.id),
                            icon: const Icon(Icons.new_label_outlined),
                            iconSize: 20,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [pluralize(tracks.length, 'track'), pluralize(albums.length, 'release'), if ((artist?.aliasCount ?? 0) > 0) pluralize(artist!.aliasCount, 'alias', 'aliases')].join('  ·  '),
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    // Links first, then tags: where somebody lives on the
                    // internet and what their music is are the same kind of
                    // fact about them, and the links are the shorter list.
                    // Gone entirely when there is neither, so an artist with
                    // no tags and no links does not carry an empty row.
                    if (artist != null && (tags.isNotEmpty || links.isNotEmpty)) ...[
                      const SizedBox(height: 14),
                      TagLine(
                        target: TagTarget.artist,
                        id: artist!.id,
                        onOpenTag: onOpenTag,
                        leading: [for (final link in links) LinkIconButton(link: link)],
                        offerAdd: tags.isNotEmpty,
                      ),
                    ],
                    const SizedBox(height: 20),
                    Row(
                      spacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: trackIds.isEmpty ? null : () => player.playAll(trackIds, source: QueueSource.artist, sourceRefId: artist?.id),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play'),
                        ),
                        OutlinedButton.icon(
                          onPressed: trackIds.isEmpty
                              ? null
                              : () async {
                                  await player.playAll(trackIds, source: QueueSource.artist, sourceRefId: artist?.id);
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
                          Artwork(storedPath: album.imagePath, size: 128, borderRadius: 8, fallbackSeed: album.title),
                          const SizedBox(height: 8),
                          Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                          if (album.releaseYear != null) Text('${album.releaseYear}', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
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
                  onSelected: (value) => ref.read(artistTrackSortProvider.notifier).set(value),
                  icon: const Icon(Icons.sort),
                  itemBuilder: (context) => [
                    for (final option in const [LibrarySort.albumThenTrack, LibrarySort.nameAscending, LibrarySort.releaseYear, LibrarySort.mostPlayed, LibrarySort.duration])
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
