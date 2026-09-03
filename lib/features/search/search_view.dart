import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart' show SearchEntity;
import '../../data/db/enums.dart' show QueueSource;
import '../../data/repositories/search_repository.dart';
import '../../domain/models/library_views.dart';
import '../../domain/search/query_suggestions.dart';
import '../../domain/search/smart_query.dart';
import '../../widgets/artwork.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/time_text.dart';
import '../../widgets/track_list.dart';
import '../tags/category_icons.dart';

/// Everything in the library a query could mean.
///
/// Results are grouped by kind rather than mixed into one list: "which artist"
/// and "which song" are different questions, and a single ranked list answers
/// neither well. The one exception is the top result, which leads because most
/// searches have an obvious answer and scanning five headings for it is work.
///
/// The field itself lives in the window's title bar now (see [SearchToolbar]
/// and [AppShell]), not here: a keystroke from anywhere in the app needs to
/// reach it, which only works if something outside this page owns it.
class SearchView extends ConsumerWidget {
  const SearchView({
    super.key,
    required this.onClear,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.onOpenTag,
    this.onOpenPlaylist,
    this.onEditTrack,
    this.onSeeMore,
  });

  /// Clears the query and refocuses the field, for the Escape shortcut.
  final VoidCallback onClear;

  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int tagId)? onOpenTag;
  final void Function(int playlistId)? onOpenPlaylist;
  final void Function(int trackId)? onEditTrack;

  /// Opens the full list for a section that had more matches than it showed
  /// here, with the same query already typed into that list's own filter.
  ///
  /// Nothing to carry the query into for tags or playlists -- neither list
  /// has a filter field of its own -- so this just switches to the section
  /// for those two.
  final void Function(SearchEntity kind)? onSeeMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(searchQueryProvider);
    final results = ref.watch(searchResultsProvider);

    return CallbackShortcuts(
      bindings: {
        // Escape clears rather than leaving: the field is the page.
        const SingleActivator(LogicalKeyboardKey.escape): onClear,
      },
      child: switch (results) {
        AsyncValue(hasError: true, :final error) => EmptyState(
            icon: Icons.error_outline,
            title: 'The search failed',
            message: '$error',
          ),
        // Previous results stay visible while the next search runs, so the
        // page does not flash empty between keystrokes.
        AsyncValue(:final value?) => _Results(
            results: value,
            query: query,
            onOpenArtist: onOpenArtist,
            onOpenAlbum: onOpenAlbum,
            onOpenTag: onOpenTag,
            onOpenPlaylist: onOpenPlaylist,
            onEditTrack: onEditTrack,
            onSeeMore: onSeeMore,
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

/// The search field, merged into the window's title bar.
///
/// Owned by [AppShell] rather than by [SearchView]: [controller] and
/// [focusNode] are handed in from there, so a keystroke from anywhere in the
/// app (Ctrl+F, Ctrl+K) can reach this field without going through the
/// section's own page, which may not even be the one on screen.
///
/// Understands the same field syntax a smart playlist's query does --
/// `artist:`, `is:`, `not:`, `OR` -- and offers the same kind of suggestions
/// [SmartQueryField] does. They cannot look the same, though: this field
/// lives in the fixed-height title bar, which must not grow to fit a row of
/// chips the way a playlist page can. Suggestions are a small floating popup
/// instead, one line each, anchored under the field rather than pushing the
/// bar taller.
class SearchToolbar extends ConsumerStatefulWidget {
  const SearchToolbar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClear;

  @override
  ConsumerState<SearchToolbar> createState() => _SearchToolbarState();
}

class _SearchToolbarState extends ConsumerState<SearchToolbar> {
  final _layerLink = LayerLink();
  OverlayEntry? _overlay;
  double _fieldWidth = 400;

  /// Which suggestion the arrow keys have moved to. Reset to the first
  /// whenever the text changes, since a fresh list of suggestions is a fresh
  /// choice -- there is no reason for the highlight to survive from "artist:"
  /// to "artist:nan".
  var _highlighted = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    widget.focusNode.addListener(_syncOverlay);
  }

  void _onTextChanged() {
    _highlighted = 0;
    _syncOverlay();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    widget.focusNode.removeListener(_syncOverlay);
    _removeOverlay();
    super.dispose();
  }

  /// The request for wherever the caret is, same as [SmartQueryField]'s.
  SuggestionRequest get _request {
    final selection = widget.controller.selection;
    final caret = selection.isValid
        ? selection.baseOffset
        : widget.controller.text.length;
    return suggestionAt(widget.controller.text, caret);
  }

  /// Everything to offer right now. Empty without focus, so a query left
  /// sitting in the field while something else has focus does not pop this
  /// open on its own.
  List<Suggestion> get _suggestions {
    if (!widget.focusNode.hasFocus) return const [];
    final request = _request;
    return switch (request.kind) {
      SuggestionKind.fields ||
      SuggestionKind.matchingFields =>
        suggestFields(request.partial),
      SuggestionKind.names =>
        request.field == QueryField.tag ? _tagSuggestions(request.partial) : const [],
      SuggestionKind.ages => [
          for (final age in ageSuggestions)
            Suggestion(
              insert: '${request.field!.keyword}:${age.value}',
              label: '${request.field!.keyword}:${age.value}',
              detail: age.label,
            ),
        ],
      SuggestionKind.comparators => [
          for (final comparator in comparatorSuggestions)
            Suggestion(
              insert: '${request.field!.keyword}:${comparator.value}',
              label: '${request.field!.keyword}:${comparator.value}',
              detail: comparator.label,
              continues: true,
            ),
        ],
      SuggestionKind.flags => [
          for (final entry in flagSuggestions)
            if (entry.flag.keyword
                .toLowerCase()
                .startsWith(request.partial.toLowerCase()))
              Suggestion(
                insert: 'is${request.separator}${entry.flag.keyword}',
                label: 'is:${entry.flag.keyword}',
                detail: entry.detail,
              ),
        ],
      SuggestionKind.none => const [],
    };
  }

  /// The tags matching what has been typed. No lookup needed -- unlike an
  /// artist or an album, every tag is already sitting in [taggedProvider].
  List<Suggestion> _tagSuggestions(String partial) {
    final typed = partial.replaceAll('"', '').toLowerCase();
    final tags = ref.read(taggedProvider).value ?? const [];
    return [
      for (final tag
          in tags.where((t) => t.name.toLowerCase().contains(typed)).take(8))
        Suggestion(
          insert: 'tag=${quoteIfNeeded(tag.name)}',
          label: tag.name,
          detail: '${tag.trackCount} tracks',
        ),
    ];
  }

  void _accept(Suggestion suggestion) {
    final applied =
        applySuggestion(widget.controller.text, _request.token, suggestion);
    widget.controller.value = TextEditingValue(
      text: applied.text,
      selection: TextSelection.collapsed(offset: applied.caret),
    );
    // Setting the controller directly bypasses the field's own onChanged.
    ref.read(searchQueryProvider.notifier).set(applied.text);
    widget.focusNode.requestFocus();
  }

  /// Moves the highlight, clamped rather than wrapped -- arrowing past either
  /// end should stop, not loop back around to surprise whoever is counting.
  void _moveHighlight(int delta, int count) {
    _highlighted = (_highlighted + delta).clamp(0, count - 1);
    _overlay?.markNeedsBuild();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final suggestions = _suggestions;
    if (suggestions.isEmpty) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.tab) {
      _accept(suggestions.first);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveHighlight(1, suggestions.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveHighlight(-1, suggestions.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _accept(suggestions[_highlighted.clamp(0, suggestions.length - 1)]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _removeOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _syncOverlay() {
    if (!mounted) return;
    if (_suggestions.isEmpty) {
      _removeOverlay();
      return;
    }
    if (_overlay == null) {
      _overlay = OverlayEntry(builder: (_) => _buildPopup());
      Overlay.of(context).insert(_overlay!);
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  Widget _buildPopup() {
    final suggestions = _suggestions;
    if (suggestions.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Positioned(
      width: _fieldWidth,
      child: CompositedTransformFollower(
        link: _layerLink,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: const Offset(0, 6),
        child: Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: suggestions.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.3),
                ),
                itemBuilder: (context, index) => _SuggestionRow(
                  suggestion: suggestions[index],
                  highlighted: index == _highlighted,
                  onSelect: () => _accept(suggestions[index]),
                  onHover: () {
                    if (_highlighted == index) return;
                    _highlighted = index;
                    _overlay?.markNeedsBuild();
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final theme = Theme.of(context);

    // Watched so a tag suggestion can be offered as soon as the provider
    // has an answer, not only whatever it held the moment focus landed here
    // -- the popup itself is an OverlayEntry, which sits outside the tree
    // Riverpod would otherwise rebuild on its own.
    ref.watch(taggedProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _overlay?.markNeedsBuild();
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        _fieldWidth = constraints.maxWidth;
        return Focus(
          onKeyEvent: _handleKey,
          child: CompositedTransformTarget(
            link: _layerLink,
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focusNode,
              autocorrect: false,
              textInputAction: TextInputAction.search,
              style: theme.textTheme.titleMedium,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        onPressed: widget.onClear,
                        icon: const Icon(Icons.close),
                      ),
                hintText: 'An artist, a song, an album, a tag, a playlist',
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  ref.read(searchQueryProvider.notifier).set(value),
              onSubmitted: (_) => widget.focusNode.requestFocus(),
            ),
          ),
        );
      },
    );
  }
}

/// One suggestion, one line: the completion on the left, what it means on
/// the right.
///
/// Accepted on tap-down rather than tap: a tap's pointer-up is what closes
/// the popup (the field loses focus first), and by then the row it landed on
/// is already gone.
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.suggestion,
    required this.onSelect,
    this.highlighted = false,
    this.onHover,
  });

  final Suggestion suggestion;
  final VoidCallback onSelect;

  /// Whether the arrow keys (or a previous hover) landed here. Enter accepts
  /// whichever row this is true for.
  final bool highlighted;

  /// Moves the highlight here on hover, so the mouse and the arrow keys agree
  /// about which row Enter would accept.
  final VoidCallback? onHover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return MouseRegion(
      onEnter: (_) => onHover?.call(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => onSelect(),
        child: Container(
          color: highlighted
              ? scheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              Text(
                suggestion.label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontFamily: 'Consolas'),
              ),
              if (suggestion.detail case final detail?) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    detail,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
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
    this.onSeeMore,
  });

  final SearchResults results;
  final String query;
  final void Function(int artistId)? onOpenArtist;
  final void Function(int albumId)? onOpenAlbum;
  final void Function(int tagId)? onOpenTag;
  final void Function(int playlistId)? onOpenPlaylist;
  final void Function(int trackId)? onEditTrack;
  final void Function(SearchEntity kind)? onSeeMore;

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
          onSeeMore: onSeeMore == null
              ? null
              : () => onSeeMore!(SearchEntity.artist),
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
          onSeeMore: onSeeMore == null
              ? null
              : () => onSeeMore!(SearchEntity.album),
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
          onSeeMore: onSeeMore == null
              ? null
              : () => onSeeMore!(SearchEntity.track),
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
          onSeeMore:
              onSeeMore == null ? null : () => onSeeMore!(SearchEntity.tag),
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
          onSeeMore: onSeeMore == null
              ? null
              : () => onSeeMore!(SearchEntity.playlist),
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
    this.onSeeMore,
  });

  final String title;
  final List<Widget> children;

  /// How many more matched than are listed. Said out loud rather than silently
  /// cut off, so six results never read as "that is all there is".
  final int hidden;

  /// Opens the full list for this section, with the query already in its
  /// filter. Null when there is nowhere to send it to (no `onSeeMore` was
  /// wired up at all), in which case the count is said but not tappable.
  final VoidCallback? onSeeMore;

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
                if (onSeeMore == null)
                  Text(
                    '$hidden more',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                else
                  InkWell(
                    onTap: onSeeMore,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '$hidden more',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            Icons.arrow_forward,
                            size: 14,
                            color: theme.colorScheme.primary,
                          ),
                        ],
                      ),
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
