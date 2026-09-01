import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart' show SearchEntity;
import '../../data/db/enums.dart' show QueueSource;
import '../../data/repositories/search_repository.dart';
import '../../domain/models/library_views.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import '../../widgets/track_list.dart';
import '../tags/category_icons.dart';

/// One field, and everything in the library it could mean.
///
/// Results are grouped by kind rather than mixed into one list: "which artist"
/// and "which song" are different questions, and a single ranked list answers
/// neither well. The one exception is the top result, which leads because most
/// searches have an obvious answer and scanning five headings for it is work.
class SearchView extends ConsumerStatefulWidget {
  const SearchView({
    super.key,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onOpenTag,
    this.onOpenPlaylist,
    this.onEditTrack,
  });

  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int tagId)? onOpenTag;
  final void Function(int playlistId)? onOpenPlaylist;
  final void Function(int trackId)? onEditTrack;

  @override
  ConsumerState<SearchView> createState() => SearchViewState();
}

class SearchViewState extends ConsumerState<SearchView> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // The query outlives the view, so coming back shows what was typed.
    _controller.text = ref.read(searchQueryProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => focusField());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Puts the caret in the field and selects what is there.
  ///
  /// Selecting rather than appending: arriving at search with something already
  /// typed almost always means a new search, and typing replaces it.
  void focusField() {
    if (!mounted) return;
    _focus.requestFocus();
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  void _clear() {
    _controller.clear();
    ref.read(searchQueryProvider.notifier).set('');
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final results = ref.watch(searchResultsProvider);
    final theme = Theme.of(context);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autocorrect: false,
                  textInputAction: TextInputAction.search,
                  style: theme.textTheme.titleMedium,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            onPressed: _clear,
                            icon: const Icon(Icons.close),
                          ),
                    hintText: 'An artist, a song, an album, a tag, a playlist',
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) =>
                      ref.read(searchQueryProvider.notifier).set(value),
                  // Escape clears rather than leaving: the field is the page.
                  onSubmitted: (_) => _focus.requestFocus(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _clear,
            },
            child: switch (results) {
              AsyncValue(hasError: true, :final error) => EmptyState(
                  icon: Icons.error_outline,
                  title: 'The search failed',
                  message: '$error',
                ),
              // Previous results stay visible while the next search runs, so
              // the page does not flash empty between keystrokes.
              AsyncValue(:final value?) => _Results(
                  results: value,
                  query: query,
                  onOpenArtist: widget.onOpenArtist,
                  onOpenAlbum: widget.onOpenAlbum,
                  onOpenTag: widget.onOpenTag,
                  onOpenPlaylist: widget.onOpenPlaylist,
                  onEditTrack: widget.onEditTrack,
                ),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ),
      ],
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({
    required this.results,
    required this.query,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onOpenTag,
    this.onOpenPlaylist,
    this.onEditTrack,
  });

  final SearchResults results;
  final String query;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int tagId)? onOpenTag;
  final void Function(int playlistId)? onOpenPlaylist;
  final void Function(int trackId)? onEditTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (searchTerms(query).isEmpty) {
      return const EmptyState(
        icon: Icons.search,
        title: 'Search the library',
        message: 'Any name it holds: an artist, a song, an album, a tag or a '
            'playlist. Part of a word is enough, another script is fine, and a '
            'song shows up under every artist credited on it.',
      );
    }

    if (results.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'Nothing matched',
        message: 'No artist, song, album, tag or playlist matches "$query".',
      );
    }

    final sections = <Widget>[
      if (results.best case final best?)
        _TopResult(
          best: best,
          results: results,
          onOpenArtist: onOpenArtist,
          onOpenAlbum: onOpenAlbum,
          onOpenTag: onOpenTag,
          onOpenPlaylist: onOpenPlaylist,
        ),
      if (results.artists.isNotEmpty)
        _Section(
          title: 'Artists',
          hidden: results.hidden(SearchEntity.artist, results.artists.length),
          children: [
            for (final artist in results.artists)
              _ResultRow(
                imagePath: artist.imagePath,
                fallbackSeed: artist.name,
                fallbackIcon: Icons.person_outline,
                rounded: true,
                title: artist.name,
                subtitle: [
                  ?_kindLabel(artist.kind),
                  pluralize(artist.trackCount, 'track'),
                  if (artist.albumCount > 0)
                    pluralize(artist.albumCount, 'album'),
                ].join(' · '),
                onTap: onOpenArtist == null
                    ? null
                    : () => onOpenArtist!(artist.id),
              ),
          ],
        ),
      if (results.albums.isNotEmpty)
        _Section(
          title: 'Albums',
          hidden: results.hidden(SearchEntity.album, results.albums.length),
          children: [
            for (final album in results.albums)
              _ResultRow(
                imagePath: album.imagePath,
                fallbackSeed: album.title,
                title: album.title,
                subtitle: [
                  album.artistName,
                  if (album.releaseYear != null) '${album.releaseYear}',
                  pluralize(album.trackCount, 'track'),
                ].join(' · '),
                onTap:
                    onOpenAlbum == null ? null : () => onOpenAlbum!(album.id),
              ),
          ],
        ),
      if (results.tracks.isNotEmpty)
        _Section(
          title: 'Songs',
          hidden: results.hidden(SearchEntity.track, results.tracks.length),
          children: [
            // Reusing the library's row, so a song looks and behaves the same
            // here as everywhere else -- play, queue, rate, open, edit.
            for (final (index, track) in results.tracks.indexed)
              _TrackResult(
                tracks: results.tracks,
                track: track,
                index: index,
                onOpenArtist: onOpenArtist,
                onOpenAlbum: onOpenAlbum,
                onEditTrack: onEditTrack,
              ),
          ],
        ),
      if (results.tags.isNotEmpty)
        _Section(
          title: 'Tags',
          hidden: results.hidden(SearchEntity.tag, results.tags.length),
          children: [
            for (final tag in results.tags)
              _ResultRow(
                imagePath: null,
                fallbackSeed: tag.name,
                fallbackIcon: tagCategoryIcon(tag.categoryIcon),
                colour: tag.color == null ? null : Color(tag.color!),
                title: tag.name,
                subtitle: [
                  if (tag.categoryName != null) tag.categoryName!,
                  pluralize(tag.trackCount, 'track'),
                ].join(' · '),
                onTap: onOpenTag == null ? null : () => onOpenTag!(tag.id),
              ),
          ],
        ),
      if (results.playlists.isNotEmpty)
        _Section(
          title: 'Playlists',
          hidden:
              results.hidden(SearchEntity.playlist, results.playlists.length),
          children: [
            for (final playlist in results.playlists)
              _ResultRow(
                imagePath: playlist.imagePath,
                fallbackSeed: playlist.name,
                fallbackIcon: Icons.playlist_play,
                title: playlist.name,
                subtitle: [
                  pluralize(playlist.trackCount, 'track'),
                  if (playlist.childCount > 0)
                    pluralize(playlist.childCount, 'playlist'),
                ].join(' · '),
                onTap: onOpenPlaylist == null
                    ? null
                    : () => onOpenPlaylist!(playlist.id),
              ),
          ],
        ),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
      children: sections,
    );
  }
}

/// The single most likely answer, in a bigger shape than the rest.
class _TopResult extends ConsumerWidget {
  const _TopResult({
    required this.best,
    required this.results,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onOpenTag,
    this.onOpenPlaylist,
  });

  final ({SearchEntity entity, int id}) best;
  final SearchResults results;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int tagId)? onOpenTag;
  final void Function(int playlistId)? onOpenPlaylist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final player = ref.read(playerProvider.notifier);

    // Only worth a headline when it is not simply the first row below it.
    final shown = switch (best.entity) {
      SearchEntity.artist => results.artists.length,
      SearchEntity.album => results.albums.length,
      SearchEntity.track => results.tracks.length,
      SearchEntity.tag => results.tags.length,
      SearchEntity.playlist => results.playlists.length,
    };
    if (shown <= 1 && results.matchCount <= 1) return const SizedBox.shrink();

    final (
      String title,
      String subtitle,
      String? imagePath,
      IconData icon,
      VoidCallback? open,
      Future<void> Function()? play,
    ) card = switch (best.entity) {
      SearchEntity.artist => () {
          final artist =
              results.artists.firstWhere((a) => a.id == best.id);
          return (
            artist.name,
            'Artist · ${pluralize(artist.trackCount, 'track')}',
            artist.imagePath,
            Icons.person_outline,
            onOpenArtist == null ? null : () => onOpenArtist!(artist.id),
            null,
          );
        }(),
      SearchEntity.album => () {
          final album = results.albums.firstWhere((a) => a.id == best.id);
          return (
            album.title,
            'Album · ${album.artistName}',
            album.imagePath,
            Icons.album_outlined,
            onOpenAlbum == null ? null : () => onOpenAlbum!(album.id),
            null,
          );
        }(),
      SearchEntity.playlist => () {
          final playlist =
              results.playlists.firstWhere((p) => p.id == best.id);
          return (
            playlist.name,
            'Playlist · ${pluralize(playlist.trackCount, 'track')}',
            playlist.imagePath,
            Icons.playlist_play,
            onOpenPlaylist == null ? null : () => onOpenPlaylist!(playlist.id),
            null,
          );
        }(),
      SearchEntity.tag => () {
          final tag = results.tags.firstWhere((t) => t.id == best.id);
          return (
            tag.name,
            'Tag · ${pluralize(tag.trackCount, 'track')}',
            null,
            Icons.label_outline,
            onOpenTag == null ? null : () => onOpenTag!(tag.id),
            null,
          );
        }(),
      SearchEntity.track => () {
          final track = results.tracks.firstWhere((t) => t.id == best.id);
          return (
            track.title,
            'Song · ${_creditLine(track)}',
            track.imagePath,
            Icons.music_note,
            null,
            () => player.playAll(
              results.tracks.map((t) => t.id).toList(),
              startIndex: results.tracks.indexOf(track),
              source: QueueSource.search,
            ),
          );
        }(),
    };

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 20),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: card.$5 ?? () => card.$6?.call(),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Artwork(
                  storedPath: card.$3,
                  size: 96,
                  borderRadius: best.entity == SearchEntity.artist ? 48 : 10,
                  fallbackSeed: card.$1,
                  fallbackIcon: card.$4,
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Top result',
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        card.$1,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        card.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (card.$6 != null)
                  IconButton.filled(
                    tooltip: 'Play',
                    onPressed: () => card.$6!(),
                    icon: const Icon(Icons.play_arrow),
                  )
                else if (card.$5 != null)
                  IconButton.filledTonal(
                    tooltip: 'Open',
                    onPressed: card.$5,
                    icon: const Icon(Icons.arrow_forward),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What to call an artist that is not simply a person.
///
/// Null for a person, and null for "unknown", which is the scan admitting it
/// could not tell. Printing that admission next to the track count reads as a
/// fact about the artist rather than about the metadata.
String? _kindLabel(String kind) => switch (kind) {
      'group' => 'Group',
      'orchestra' => 'Orchestra',
      'character' => 'Character',
      _ => null,
    };

/// Every artist credited on a track, in the order they are credited.
///
/// Every one of them, not just the first: a song that says "Name1 x Name2" is
/// here because someone searched one of those names, and showing only the other
/// would look like the wrong result.
String _creditLine(TrackRow track) {
  final names = [
    for (final credit in track.credits) credit.name,
  ];
  return names.isEmpty ? 'Unknown artist' : names.join(', ');
}

/// A heading, its rows, and what it is not showing.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.children,
    this.hidden = 0,
  });

  final String title;
  final List<Widget> children;

  /// How many more matched than are listed. Said out loud rather than silently
  /// cut off, so six results never read as "that is all there is".
  final int hidden;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              if (hidden > 0) ...[
                const SizedBox(width: 10),
                Text(
                  '$hidden more',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

/// One result: art, a name, a line of context.
class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.imagePath,
    required this.title,
    required this.subtitle,
    this.fallbackSeed,
    this.fallbackIcon = Icons.album_outlined,
    this.rounded = false,
    this.colour,
    this.onTap,
  });

  final String? imagePath;
  final String title;
  final String subtitle;
  final String? fallbackSeed;
  final IconData fallbackIcon;

  /// Round art, for a person rather than a thing.
  final bool rounded;

  /// A tag's own colour, when it has one.
  final Color? colour;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            if (colour != null)
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colour!.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(fallbackIcon, size: 22, color: colour),
              )
            else
              Artwork(
                storedPath: imagePath,
                size: 44,
                borderRadius: rounded ? 22 : 8,
                fallbackSeed: fallbackSeed,
                fallbackIcon: fallbackIcon,
              ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// A song result, played as a queue of the songs found.
///
/// Playing one result queues the rest: a search is a set of songs, and playing
/// the third one only to stop after it would be a surprise.
class _TrackResult extends ConsumerWidget {
  const _TrackResult({
    required this.tracks,
    required this.track,
    required this.index,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onEditTrack,
  });

  final List<TrackRow> tracks;
  final TrackRow track;
  final int index;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int trackId)? onEditTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final isCurrent = player.current?.trackId == track.id;

    return TrackTile(
      track: track,
      index: index,
      isCurrent: isCurrent,
      isPlaying: isCurrent && player.isPlaying,
      onPlay: () => controller.playAll(
        tracks.map((t) => t.id).toList(),
        startIndex: index,
        source: QueueSource.search,
      ),
      onOpenArtist: onOpenArtist,
      onOpenAlbum: onOpenAlbum,
      onEditTrack: onEditTrack,
    );
  }
}
