import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart' show QueueSource;
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/collapsing_header.dart';
import '../../widgets/title_with_actions.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import '../../widgets/track_list.dart';
import '../library/bulk_actions.dart';
import 'category_dialog.dart';
import 'tag_visuals.dart';

/// Everything carrying one tag.
///
/// Includes tracks that inherit it from their album or from a playlist, because
/// that is what the tag means. A page that showed only directly-tagged tracks
/// would disagree with the count in the tag list and with search.
class TagDetailView extends ConsumerStatefulWidget {
  const TagDetailView({
    super.key,
    required this.tagId,
    required this.onBack,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onEditTrack,
  });

  final int tagId;
  final VoidCallback onBack;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int trackId)? onEditTrack;

  @override
  ConsumerState<TagDetailView> createState() => _TagDetailViewState();
}

class _TagDetailViewState extends ConsumerState<TagDetailView> {
  @override
  Widget build(BuildContext context) {
    final tagId = widget.tagId;
    final onBack = widget.onBack;
    final onOpenArtist = widget.onOpenArtist;
    final onOpenAlbum = widget.onOpenAlbum;
    final onEditTrack = widget.onEditTrack;
    final tracks = ref.watch(tagTrackListProvider(tagId));
    final tag = ref
        .watch(taggedProvider)
        .value
        ?.where((t) => t.id == tagId)
        .firstOrNull;

    return tracks.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load that tag',
        message: '$error',
      ),
      data: (items) {
        if (tag == null) {
          return EmptyState(
            icon: Icons.label_off_outlined,
            title: 'That tag is gone',
            message: 'It was deleted.',
            action:
                FilledButton(onPressed: onBack, child: const Text('Back')),
          );
        }
        return CollapsingHeader(
          child: TrackList(
          tracks: items,
          onOpenArtist: onOpenArtist,
          onOpenAlbum: onOpenAlbum,
          onEditTrack: onEditTrack,
          menuFor: (track) => trackContextMenu(
            context,
            ref,
            track,
            onOpenAlbum: onOpenAlbum,
            onOpenArtist: onOpenArtist,
            onEditTrack: onEditTrack,
          ),
          queueSource: QueueSource.tag,
          queueSourceId: tagId,
          header: _Header(
            tag: tag,
            tracks: items,
            onOpenArtist: onOpenArtist,
            onOpenAlbum: onOpenAlbum,
          ),
        ),
        );
      },
    );
  }
}

/// A tag page's back, edit and delete controls, merged into the window's
/// title bar rather than sitting as the first row of the page itself.
///
/// A [ConsumerWidget] rather than taking the tag as a parameter: the chrome
/// is built before the page's own data has necessarily loaded (see
/// [AppShell]), so it watches [taggedProvider] itself and simply disables
/// the edit and menu buttons until there is a tag to act on.
class TagDetailChrome extends ConsumerWidget {
  const TagDetailChrome({super.key, required this.tagId, required this.onBack});

  final int tagId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tag = ref
        .watch(taggedProvider)
        .value
        ?.where((t) => t.id == tagId)
        .firstOrNull;

    // Taken over from the page once its own title row has scrolled away, so
    // the name and the play controls are reachable the whole way down a long
    // tag rather than only at the top of it.
    final collapsed = ref.watch(detailHeaderCollapsedProvider) && tag != null;
    final visuals = tag == null
        ? null
        : tagVisuals(
            context,
            categoryIcon: tag.categoryIcon,
            color: tag.color,
          );

    return Row(
      children: [
        IconButton(
          tooltip: 'Back',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
        ),
        // One flexible element either way: the title takes the room when it
        // is there, and a plain Spacer holds it open when it is not.
        if (collapsed)
          Expanded(
            child: CollapsedTitle(
              leading: Icon(visuals!.icon, size: 20, color: visuals.color),
              title: tag.name,
              actions: [
                IconButton(
                  tooltip: 'Edit this tag',
                  onPressed: () => editTag(
                    context,
                    ref,
                    tagId: tag.id,
                    name: tag.name,
                    categoryId: tag.categoryId,
                  ),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
          )
        else
          const Spacer(),
        if (collapsed) ...[
          CollapsedTransport(
            trackIds: [
              for (final track
                  in ref.watch(tagTrackListProvider(tag.id)).value ?? const [])
                track.id,
            ],
            source: QueueSource.tag,
            sourceRefId: tag.id,
          ),
          const SizedBox(width: 4),
        ],
        PopupMenuButton<String>(
          tooltip: 'More',
          enabled: tag != null,
          icon: const Icon(Icons.more_vert),
          onSelected: (action) async {
            if (action != 'delete') return;
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text('Delete ${tag!.name}?'),
                content: Text(
                  'It comes off everything carrying it -- '
                  '${pluralize(tag.trackCount, 'track')}. The music itself '
                  'is untouched.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );
            if (confirmed != true) return;
            await ref.read(tagRepositoryProvider).deleteTag(tag!.id);
            // Back, because this page is about a tag that no longer exists --
            // staying would show the "that tag is gone" card where a page
            // used to be.
            onBack();
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ],
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.tag,
    required this.tracks,
    this.onOpenArtist,
    this.onOpenAlbum,
  });

  final TagCard tag;
  final List<TrackRow> tracks;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = ref.read(playerProvider.notifier);
    final trackIds = tracks.map((t) => t.id).toList();
    final visuals = tagVisuals(
      context,
      categoryIcon: tag.categoryIcon,
      color: tag.color,
    );

    final total = tracks.fold(
      Duration.zero,
      (sum, track) => sum + track.duration,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(visuals.icon, size: 34, color: visuals.color),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TitleWithActions(
                      title: Text(
                        tag.name,
                        style: theme.textTheme.displaySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      actions: [
                        IconButton(
                          tooltip: 'Edit this tag',
                          onPressed: () => editTag(
                            context,
                            ref,
                            tagId: tag.id,
                            name: tag.name,
                            categoryId: tag.categoryId,
                          ),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (tag.categoryName != null) tag.categoryName!,
                        pluralize(tracks.length, 'track'),
                        if (total > Duration.zero) formatDurationLong(total),
                      ].join(' · '),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: trackIds.isEmpty
                    ? null
                    : () => player.playAll(
                          trackIds,
                          source: QueueSource.tag,
                          sourceRefId: tag.id,
                        ),
                icon: const Icon(Icons.play_arrow, size: 20),
                label: const Text('Play'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: trackIds.isEmpty
                    ? null
                    : () async {
                        await player.playAll(
                          trackIds,
                          source: QueueSource.tag,
                          sourceRefId: tag.id,
                        );
                        await player.shuffleQueue();
                      },
                icon: const Icon(Icons.shuffle, size: 18),
                label: const Text('Shuffle'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _TaggedAlbums(
            tagId: tag.id,
            singles: tracks.where((t) => t.albumId == null).length,
            onOpen: onOpenAlbum,
          ),
          _TaggedArtists(tagId: tag.id, onOpen: onOpenArtist),
          Text(
            'Tracks carrying this tag, including through an album, a playlist '
            'or someone credited on them',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}


/// The artists this tag reaches, below the albums row.
///
/// A tag on an artist is a statement about a person, not about a recording,
/// so it deserves saying in its own right rather than being visible only as
/// the reason several hundred tracks turned up below. Artists who wear the
/// tag themselves come first (most-tagged tracks first among them); after
/// them, artists nobody tagged directly but whose entire output happens to
/// carry it anyway -- same "most tracks first" rule, second group. No visual
/// split between the two: the order already says which is which. Absent
/// entirely when nobody qualifies, which is most tags.
class _TaggedArtists extends ConsumerWidget {
  const _TaggedArtists({required this.tagId, this.onOpen});

  final int tagId;
  final void Function(int artistId)? onOpen;

  static const _tile = 132.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final direct = ref.watch(tagArtistsProvider(tagId)).value ?? const [];
    final byTracks =
        ref.watch(tagArtistsByTracksProvider(tagId)).value ?? const [];
    if (direct.isEmpty && byTracks.isEmpty) return const SizedBox.shrink();
    final artists = [...direct, ...byTracks];

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          pluralize(artists.length, 'artist'),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: _tile + 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final artist in artists)
                _ArtistSquare(
                  artist: artist,
                  onTap: onOpen == null ? null : () => onOpen!(artist.id),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _ArtistSquare extends StatelessWidget {
  const _ArtistSquare({required this.artist, this.onTap});

  final ArtistCard artist;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: SizedBox(
        width: _TaggedArtists._tile,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Artwork(
                storedPath: artist.imagePath,
                size: _TaggedArtists._tile,
                // Circular, matching every other artist portrait in the app.
                borderRadius: _TaggedArtists._tile / 2,
                fallbackSeed: artist.name,
                fallbackIcon: Icons.person_outline,
              ),
              const SizedBox(height: 6),
              Text(
                artist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                pluralize(artist.trackCount, 'track'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// The albums this tag reaches, and what is left over.
///
/// A tag's page is a long list of songs, and a list of songs is a poor way to
/// see that most of them come from four records. The row says that at a
/// glance, and the "Singles" card at the end accounts for the rest rather
/// than leaving the arithmetic to the reader -- without it, a row of four
/// albums over a list of ninety tracks looks like a bug.
class _TaggedAlbums extends ConsumerWidget {
  const _TaggedAlbums({
    required this.tagId,
    required this.singles,
    this.onOpen,
  });

  final int tagId;

  /// Tagged tracks belonging to no album at all.
  final int singles;

  final void Function(int albumId)? onOpen;

  static const _tile = 132.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albums = ref.watch(tagAlbumsProvider(tagId)).value ?? const [];
    if (albums.isEmpty && singles == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            if (albums.isNotEmpty) pluralize(albums.length, 'album'),
            if (singles > 0) pluralize(singles, 'single'),
          ].join(' and '),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: _tile + 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final album in albums)
                _AlbumSquare(
                  album: album,
                  onTap: onOpen == null ? null : () => onOpen!(album.id),
                ),
              // Last, and deliberately not a link: there is no page for "the
              // rest of them", and a card that looks tappable and is not is
              // worse than one that plainly is not.
              if (singles > 0) _SinglesSquare(count: singles),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _AlbumSquare extends StatelessWidget {
  const _AlbumSquare({required this.album, this.onTap});

  final AlbumCard album;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: SizedBox(
        width: _TaggedAlbums._tile,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Artwork(
                storedPath: album.imagePath,
                size: _TaggedAlbums._tile,
                borderRadius: 10,
                fallbackSeed: album.title,
              ),
              const SizedBox(height: 6),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              Text(
                album.artistName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The leftovers, counted rather than listed.
class _SinglesSquare extends StatelessWidget {
  const _SinglesSquare({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Tooltip(
      message: 'Tagged tracks that are not on any album',
      child: SizedBox(
        width: _TaggedAlbums._tile,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: _TaggedAlbums._tile,
              height: _TaggedAlbums._tile,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Icon(
                Icons.music_note_outlined,
                color: scheme.onSurfaceVariant,
                size: 32,
              ),
            ),
            const SizedBox(height: 6),
            Text('Singles', style: theme.textTheme.bodyMedium),
            Text(
              pluralize(count, 'track'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}


