import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/enums.dart' show QueueSource;
import '../../data/repositories/tag_repository.dart';
import '../../domain/models/library_views.dart';
import '../tags/tag_line.dart';
import '../../widgets/artwork.dart';
import '../../widgets/expandable_artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import '../../widgets/title_with_actions.dart';
import '../../features/playlists/playlist_pickers.dart';
import '../../widgets/track_list.dart';

/// One album: large artwork, its details, and its tracks.
class AlbumDetailView extends ConsumerWidget {
  const AlbumDetailView({
    super.key,
    required this.albumId,
    required this.onOpenArtist,
    this.onOpenTag,
    this.onEditAlbum,
    this.onEditTrack,
    this.topInset = 0,
  });

  final int albumId;
  final void Function(int artistId) onOpenArtist;

  /// Opens a tag's page, when there is somewhere to open it.
  final void Function(int tagId)? onOpenTag;

  /// Opens the album editor. Reaches the page rather than the window's
  /// caption strip now, because the button sits beside the album's title.
  final void Function(int albumId)? onEditAlbum;
  final void Function(int trackId)? onEditTrack;

  /// Space to leave clear at the top for the window's caption strip.
  ///
  /// The blurred backdrop bleeds all the way to the top of the window now
  /// that its own back/edit row lives in the strip (see [AlbumDetailChrome]
  /// and [AppShell]), so without this the title and Play/Shuffle row would
  /// start underneath the window buttons.
  final double topInset;

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
                  onOpenTag: onOpenTag,
                  onEdit: onEditAlbum == null
                      ? null
                      : () => onEditAlbum!(albumId),
                  topInset: topInset,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// An album page's back, add-to-playlist and sort controls, merged into the
/// window's title bar rather than sitting as the first row of the page
/// itself.
///
/// Editing the album is no longer here: it acts on the album, so it sits
/// beside the album's title (see [TitleWithActions]). What is left is about
/// the page -- going back, queueing the whole thing, and how the list below
/// is ordered -- and all three have to stay reachable after the header has
/// scrolled away.
///
/// A [ConsumerWidget] rather than taking the album's title as a parameter:
/// the chrome is built before the page's own data has necessarily loaded
/// (see [AppShell]), so it watches [albumDetailProvider] itself and simply
/// disables the add-to-playlist button until there is a title to show.
class AlbumDetailChrome extends ConsumerWidget {
  const AlbumDetailChrome({
    super.key,
    required this.albumId,
    required this.onBack,
  });

  final int albumId;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref.watch(albumDetailProvider(albumId)).value;

    return Row(
      children: [
        IconButton(
          tooltip: 'Back',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Add this album to a playlist',
          onPressed: album == null
              ? null
              : () => showAddAlbumToPlaylist(
                    context,
                    ref,
                    album.id,
                    albumTitle: album.title,
                  ),
          icon: const Icon(Icons.library_add_outlined),
        ),
        // Track order is what an album is normally read in, but a long
        // compilation is easier to search alphabetically and a soundtrack is
        // sometimes easier by length.
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
    );
  }
}

/// Cover, title, artist and the album-level actions.
class _AlbumHeader extends ConsumerWidget {
  const _AlbumHeader({
    required this.album,
    required this.tracks,
    required this.onOpenArtist,
    this.onOpenTag,
    this.onEdit,
    this.topInset = 0,
  });

  final AlbumCard album;
  final List<TrackRow> tracks;
  final void Function(int artistId) onOpenArtist;
  final void Function(int tagId)? onOpenTag;

  /// Opens the album editor.
  final VoidCallback? onEdit;
  final double topInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final player = ref.read(playerProvider.notifier);
    final trackIds = tracks.map((t) => t.id).toList();
    // Watched here as well as inside the TagLine, so the header can drop the
    // whole row when there is nothing on it. Riverpod hands both the same
    // cached list.
    final tags = ref
            .watch(attachedTagsProvider((target: TagTarget.album, id: album.id)))
            .value ??
        const <AttachedTag>[];
    // Synthetic single cards carry a negative id and are not rows anything
    // can be written to.
    final canEdit = onEdit != null && album.id > 0;

    return Padding(
      padding: EdgeInsets.only(top: topInset + 20, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ExpandableArtwork(
                storedPath: album.imagePath,
                size: 200,
                borderRadius: 12,
                owner: PictureOwner.album,
                id: album.id,
                title: album.title,
                heroTag: 'album-art-${album.id}',
                // Synthetic single cards carry a negative id and are not rows
                // anything can be written to.
                editable: album.id > 0,
              ),
              const SizedBox(width: 28),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TitleWithActions(
                      title: Text(
                        album.title,
                        style: theme.textTheme.displaySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      actions: [
                        if (canEdit)
                          IconButton(
                            tooltip: 'Edit this album',
                            onPressed: onEdit,
                            icon: const Icon(Icons.edit_outlined),
                            iconSize: 20,
                          ),
                        // Only while there is nothing tagged; once there is,
                        // the tag line below carries its own add chip.
                        if (album.id > 0 && tags.isEmpty)
                          IconButton(
                            tooltip: 'Add a tag',
                            onPressed: () => addTagTo(
                              context,
                              ref,
                              TagTarget.album,
                              album.id,
                            ),
                            icon: const Icon(Icons.new_label_outlined),
                            iconSize: 20,
                          ),
                      ],
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
                    // What this album is, before what you can do with it --
                    // and nothing at all when it is untagged, since an empty
                    // row is a line of header spent saying nothing. Adding
                    // the first one happens beside the title instead.
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      TagLine(
                        target: TagTarget.album,
                        id: album.id,
                        onOpenTag: onOpenTag,
                      ),
                    ],
                    const SizedBox(height: 14),
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
