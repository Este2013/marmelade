import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/library/album_detail_view.dart';
import '../features/library/albums_view.dart';
import '../features/library/artist_detail_view.dart';
import '../features/library/artists_view.dart';
import '../features/library/credit_review_view.dart';
import '../features/edit/album_editor_view.dart';
import '../features/edit/artist_editor_view.dart';
import '../features/edit/editor_save_state.dart';
import '../features/edit/track_editor_view.dart';
import '../features/library/songs_view.dart';
import '../features/player/now_playing_view.dart';
import '../features/playlists/playlist_detail_view.dart';
import '../features/playlists/playlists_view.dart';
import '../features/tags/tag_detail_view.dart';
import '../features/tags/tags_view.dart';
import '../features/player/player_bar.dart';
import '../features/search/search_view.dart';
import '../features/settings/changelog_dialog.dart';
import '../features/settings/settings_view.dart';
import '../core/debug/screenshotter.dart';
import '../core/logging/app_log.dart';
import '../data/db/enums.dart' show ScanTrigger;
import '../widgets/section_title.dart';
import '../widgets/time_text.dart';
import 'providers.dart';
import 'window_chrome.dart';

/// Top-level sections.
///
/// Now playing is deliberately absent. It is not a place in the library, it is
/// the player itself, so it opens by drawing the player bar up over the content
/// rather than by taking a rail slot alongside Albums and Artists.
enum LibrarySection {
  search('Search', Icons.search_outlined, Icons.search),
  albums('Albums', Icons.album_outlined, Icons.album),
  songs('Songs', Icons.music_note_outlined, Icons.music_note),
  artists('Artists', Icons.people_outline, Icons.people),
  tags('Tags', Icons.label_outline, Icons.label),
  playlists('Playlists', Icons.playlist_play_outlined, Icons.playlist_play),
  settings('Settings', Icons.settings_outlined, Icons.settings);

  const LibrarySection(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// The sections offered as rail destinations, in order.
  ///
  /// Settings is excluded and pinned to the foot of the rail instead: it is
  /// where the app gets configured, not another way to browse music.
  static const railDestinations = [search, albums, songs, artists, tags, playlists];
}

/// The application frame: navigation rail, content, and the player strip.
///
/// Each section keeps its own navigation stack, so switching to Settings and
/// back does not lose the album you had opened.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> with TickerProviderStateMixin {
  var _section = LibrarySection.albums;

  /// Drives the now-playing shade, drawn up out of the player bar.
  late final AnimationController _shade = AnimationController(duration: const Duration(milliseconds: 320), reverseDuration: const Duration(milliseconds: 240), vsync: this);

  /// Drives the player bar itself, which slides up the first time there is
  /// something to play and stays out of the way until then.
  late final AnimationController _bar = AnimationController(duration: const Duration(milliseconds: 340), reverseDuration: const Duration(milliseconds: 240), vsync: this);

  late final Animation<double> _barCurve = CurvedAnimation(parent: _bar, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    Screenshotter.scheduleIfRequested();
    // The query outlives the field itself, so coming back shows what was
    // typed.
    _searchController.text = ref.read(searchQueryProvider);

    // Debug affordance: start playback without driving the mouse.
    if (Platform.environment['MARMELADE_PLAY'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        AppLog.instance.warn('play requested by MARMELADE_PLAY');
        await ref.read(playerProvider.notifier).togglePlayPause();
        final player = ref.read(playerProvider);
        AppLog.instance.info('play requested', fields: {'status': player.status.name, 'track': player.current?.title ?? '(none)', 'error': player.errorMessage ?? '(none)'});
      });
    }

    // Debug affordance: open a section, the credit review page, or the
    // now-playing shade without driving the mouse. Pixel-hunting a navigation
    // rail from a script is fragile; naming the destination is not.
    final section = Platform.environment['MARMELADE_SECTION'];
    if (section != null && section.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = LibrarySection.values.where((s) => s.name == section).firstOrNull;
        if (target == null) {
          AppLog.instance.warn('unknown MARMELADE_SECTION', fields: {'value': section, 'known': LibrarySection.values.map((s) => s.name).join(',')});
          return;
        }
        _select(target);
        if (Platform.environment['MARMELADE_OPEN_REVIEW'] == '1') {
          _openCreditReview();
        }
        final artist = int.tryParse(Platform.environment['MARMELADE_ARTIST'] ?? '');
        if (artist != null) _openArtist(artist);
        final album = int.tryParse(Platform.environment['MARMELADE_ALBUM'] ?? '');
        if (album != null) _openAlbum(album);
        final editArtist = int.tryParse(Platform.environment['MARMELADE_EDIT_ARTIST'] ?? '');
        if (editArtist != null) _editArtist(editArtist);
        final editAlbum = int.tryParse(Platform.environment['MARMELADE_EDIT_ALBUM'] ?? '');
        if (editAlbum != null) _editAlbum(editAlbum);
        final editTrack = int.tryParse(Platform.environment['MARMELADE_EDIT_TRACK'] ?? '');
        if (editTrack != null) _editTrack(editTrack);
        final playlist = int.tryParse(Platform.environment['MARMELADE_PLAYLIST'] ?? '');
        if (playlist != null) _openPlaylist(playlist);
        final tag = int.tryParse(Platform.environment['MARMELADE_TAG'] ?? '');
        if (tag != null) _openTag(tag);
        if (Platform.environment['MARMELADE_REINDEX'] == '1') {
          ref.read(searchIndexerProvider).rebuildAll().then((_) => AppLog.instance.info('search index rebuilt on request'));
        }
        // Debug affordance: pre-fill a list's filter box, so a filtered view
        // can be photographed without driving the keyboard.
        final listFilter = Platform.environment['MARMELADE_FILTER'];
        if (listFilter != null && listFilter.isNotEmpty) {
          switch (target) {
            case LibrarySection.albums:
              ref.read(albumFilterProvider.notifier).set(listFilter);
            case LibrarySection.songs:
              ref.read(songFilterProvider.notifier).set(listFilter);
            case LibrarySection.artists:
              ref.read(artistFilterProvider.notifier).set(listFilter);
            default:
              AppLog.instance.warn('MARMELADE_FILTER does not apply to this section', fields: {'section': target.name});
          }
        }
        final query = Platform.environment['MARMELADE_SEARCH'];
        if (query != null && query.isNotEmpty) {
          _searchController.text = query;
          ref.read(searchQueryProvider.notifier).set(query);
        }
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final player = ref.read(playerProvider);
      if (player.hasTrack || player.hasQueue) _bar.value = 1;
    });

    // First launch after an update: say what changed, once. Answered from the
    // built-in changelog, so it needs no network and cannot be late.
    WidgetsBinding.instance.addPostFrameCallback((_) => _showWhatIsNew());

    if (Platform.environment['MARMELADE_NOW_PLAYING'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _toggleShade(open: true);
        if (Platform.environment['MARMELADE_LYRICS'] == '1') {
          _showSidePane(lyrics: true);
        }
      });
    }

    // Debug affordance: reproduce a library refresh without driving the UI.
    // Indexing is where the app does its heaviest work, and being able to
    // trigger it from a script is the difference between reading a crash log
    // and guessing.
    if (Platform.environment['MARMELADE_AUTOSCAN'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        AppLog.instance.warn('autoscan requested by MARMELADE_AUTOSCAN');
        _select(LibrarySection.settings);
        await ref.read(indexProgressProvider.notifier).refreshAll(trigger: ScanTrigger.startup);
        AppLog.instance.info('autoscan complete');
        if (Platform.environment['MARMELADE_AUTOSCAN_EXIT'] == '1') {
          AppLog.instance.sessionEnd('autoscan finished');
          exit(0);
        }
      });
    }
  }

  @override
  void dispose() {
    _shade.dispose();
    _bar.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Shows or hides the player bar to match whether anything is playable.
  void _syncBar(bool canPlay) {
    if (canPlay) {
      _bar.forward();
      return;
    }
    _bar.reverse();
    // Nothing to look at, so nothing to look at it in.
    _toggleShade(open: false);
  }

  /// The search field, owned here rather than by the search page: it now
  /// lives in the title bar (see [SearchToolbar]), and a keystroke from
  /// anywhere (Ctrl+F, Ctrl+K) needs to reach it regardless of which section's
  /// page happens to be mounted.
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  /// Puts the caret in the search field and selects what is there.
  ///
  /// Selecting rather than appending: arriving at search with something
  /// already typed almost always means a new search, and typing replaces it.
  void _focusSearchField() {
    if (!mounted) return;
    _searchFocus.requestFocus();
    _searchController.selection = TextSelection(baseOffset: 0, extentOffset: _searchController.text.length);
  }

  void _clearSearch() {
    _searchController.clear();
    ref.read(searchQueryProvider.notifier).set('');
    _searchFocus.requestFocus();
  }

  /// One navigator key per section, so each keeps its own history.
  final _navigatorKeys = {for (final section in LibrarySection.values) section: GlobalKey<NavigatorState>()};

  /// Sections that have been opened, in the order they were first opened.
  ///
  /// Doubles as the child list of the section stack, so an unvisited section
  /// costs nothing at all.
  final _visitedOrder = <LibrarySection>[LibrarySection.albums];

  /// What each section's title bar shows, mirroring that section's own
  /// Navigator stack one entry at a time.
  ///
  /// A detail page's back/edit row lives in the title bar rather than in the
  /// page itself now (see `WindowChrome.content`), so pushing a page and
  /// pushing its title-bar content are the same event -- tracked here,
  /// alongside the existing `_push`/`_pop`, rather than through a provider a
  /// hidden `IndexedStack` sibling could just as easily write to. The empty
  /// list means "show the section's own root toolbar".
  ///
  /// Every `_push` adds exactly one entry here, even a null-returning one for
  /// a page with no chrome of its own (an editor, still deferred) -- so this
  /// stack's depth always matches the Navigator's, and `_pop` can always pop
  /// exactly one of each without needing to know what the page pushed.
  ///
  /// `bleed` marks a page whose own background (a blurred backdrop, for the
  /// album and artist pages) should paint behind the caption strip instead
  /// of stopping below it -- see [_contentBleeds].
  final _chromeStack = <LibrarySection, List<({Widget? Function(BuildContext) builder, bool bleed})>>{for (final section in LibrarySection.values) section: []};

  void _pushChrome(Widget? Function(BuildContext) builder, {bool bleed = false}) => setState(() => _chromeStack[_section]!.add((builder: builder, bleed: bleed)));

  void _popChrome() {
    final stack = _chromeStack[_section]!;
    if (stack.isNotEmpty) setState(() => stack.removeLast());
  }

  /// Whether the section's current top page wants its own background to
  /// bleed behind the caption strip rather than starting below it.
  ///
  /// Only ever true for a pushed detail page (see [_push]); a section's root
  /// view is always a plain list with nothing to bleed.
  bool get _contentBleeds {
    final stack = _chromeStack[_section]!;
    return stack.isNotEmpty && stack.last.bleed;
  }

  /// Where the rail ends, so a section's chrome content can start there
  /// instead of under it.
  ///
  /// A rail with labels is wider than its `minWidth` suggests -- the widest
  /// label decides it -- so this is measured rather than guessed, once the
  /// rail has actually laid out. The starting value is only ever seen for the
  /// first frame or two.
  final _railKey = GlobalKey();
  var _railWidth = 96.0;

  void _measureRail() {
    final width = (_railKey.currentContext?.findRenderObject() as RenderBox?)?.size.width;
    if (width != null && (width - _railWidth).abs() > 0.5) {
      setState(() => _railWidth = width);
    }
  }

  /// Whether the shade is open or on its way open.
  bool get _shadeOpen => _shade.status == AnimationStatus.forward || _shade.status == AnimationStatus.completed;

  void _toggleShade({bool? open, bool showQueue = false}) {
    final target = open ?? !_shadeOpen;
    if (target && showQueue) _showSidePane(queue: true);
    target ? _shade.forward() : _shade.reverse();
  }

  void _select(LibrarySection section) {
    // Navigating anywhere closes the shade: it covers the very content being
    // navigated to, so leaving it up would look like nothing happened.
    _toggleShade(open: false);
    if (section == _section) {
      // Tapping the current section pops it back to its root, which is what
      // every other app with a rail does.
      _navigatorKeys[section]!.currentState?.popUntil((r) => r.isFirst);
      setState(() => _chromeStack[section]!.clear());
      return;
    }
    setState(() {
      if (!_visitedOrder.contains(section)) _visitedOrder.add(section);
      _section = section;
    });
  }

  void _push(Widget page, {Widget? Function(BuildContext)? chrome, bool bleed = false, bool retry = true}) {
    final navigator = _navigatorKeys[_section]!.currentState;
    if (navigator == null) {
      // A section selected in this same frame has no Navigator yet, so the
      // push would silently do nothing. One retry after the tree is built is
      // enough; failing twice means the section is genuinely not there.
      if (retry) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _push(page, chrome: chrome, bleed: bleed, retry: false));
      }
      return;
    }
    // Always exactly one chrome entry per pushed page -- null when the page
    // has no chrome of its own yet -- so `_pop` never has to guess whether a
    // matching chrome entry exists to pop.
    _pushChrome(chrome ?? (_) => null, bleed: bleed);
    navigator.push(MaterialPageRoute(builder: (_) => page));
  }

  void _pop() {
    _navigatorKeys[_section]!.currentState?.maybePop();
    _popChrome();
  }

  void _openAlbum(int albumId) => _push(
    AlbumDetailView(albumId: albumId, onOpenArtist: _openArtist, onOpenTag: _openTag, onEditTrack: _editTrack, topInset: WindowChrome.height),
    chrome: (_) => AlbumDetailChrome(albumId: albumId, onBack: _pop, onEdit: () => _editAlbum(albumId)),
    bleed: true,
  );

  void _openArtist(int artistId) => _push(
    ArtistDetailView(artistId: artistId, onOpenAlbum: _openAlbum, onOpenArtist: _openArtist, onEditArtist: _editArtist, onEditTrack: _editTrack, topInset: WindowChrome.height),
    chrome: (_) => ArtistDetailChrome(onBack: _pop, onEdit: () => _editArtist(artistId)),
    bleed: true,
  );

  void _openTag(int tagId) => _push(
    TagDetailView(tagId: tagId, onBack: _pop, onOpenArtist: _openArtist, onOpenAlbum: _openAlbum, onEditTrack: _editTrack),
    chrome: (_) => TagDetailChrome(tagId: tagId, onBack: _pop),
  );

  void _openPlaylist(int playlistId) => _push(
    PlaylistDetailView(playlistId: playlistId, onBack: _pop, onOpenPlaylist: _openPlaylist, onOpenArtist: _openArtist, onOpenAlbum: _openAlbum, onEditTrack: _editTrack, onOpenTag: _openTag),
    chrome: (_) => PlaylistDetailChrome(playlistId: playlistId, onBack: _pop),
  );

  void _editArtist(int artistId) {
    final saveState = EditorSaveState();
    _push(
      ArtistEditorView(artistId: artistId, onBack: _pop, onOpenArtist: _openArtist, saveState: saveState),
      chrome: (_) => ArtistEditorChrome(artistId: artistId, onBack: _pop, saveState: saveState),
    );
  }

  void _editAlbum(int albumId) {
    final saveState = EditorSaveState();
    _push(
      AlbumEditorView(albumId: albumId, onBack: _pop, saveState: saveState),
      chrome: (_) => AlbumEditorChrome(albumId: albumId, onBack: _pop, saveState: saveState),
    );
  }

  void _editTrack(int trackId) {
    final saveState = EditorSaveState();
    _push(
      TrackEditorView(trackId: trackId, onBack: _pop, saveState: saveState),
      chrome: (_) => TrackEditorChrome(trackId: trackId, onBack: _pop, saveState: saveState),
    );
  }

  /// Shows the release notes once, after the version has changed.
  Future<void> _showWhatIsNew() async {
    // Debug affordance: show it regardless of whether the version changed,
    // which is the only way to look at it without bumping the version.
    final forced = Platform.environment['MARMELADE_CHANGELOG'] == '1';
    // Screenshots would otherwise all be taken through this dialog.
    if (!forced && Platform.environment['MARMELADE_SHOT'] != null) return;

    final notes = forced ? await ref.read(currentChangesProvider.future) : await ref.read(justUpdatedProvider.future);
    if (notes == null || !mounted) return;
    await showChangelog(context, versions: [notes], title: 'What is new in ${notes.version}', subtitle: 'You have just updated.');
  }

  /// Goes to search and puts the caret in the field.
  ///
  /// From anywhere, including with the shade up: someone reaching for Ctrl+F
  /// wants to type, not to first work out what is covering the page.
  void _openSearch() {
    _toggleShade(open: false);
    if (_section != LibrarySection.search) {
      _select(LibrarySection.search);
      // The chrome for the newly-selected section does not exist yet in this
      // frame, so the caret has to wait for it.
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusSearchField());
      return;
    }
    // Already there: pop anything opened from a result, then focus.
    final navigator = _navigatorKeys[LibrarySection.search]?.currentState;
    while (navigator?.canPop() ?? false) {
      navigator!.pop();
    }
    _focusSearchField();
  }

  void _openCreditReview() {
    // Lives inside the Artists stack: it is about who the artists are, and it
    // keeps the rail to five destinations rather than adding one for something
    // that is empty most of the time.
    if (_section != LibrarySection.artists) {
      _select(LibrarySection.artists);
    }
    _push(CreditReviewView(onBack: _pop));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // The rail's width settles after its first real layout, not before.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _measureRail();
    });

    // Nothing playing and nothing queued means no player bar at all, rather
    // than a permanent strip saying so.
    ref.listen(playerProvider.select((s) => s.hasTrack || s.hasQueue), (_, canPlay) => _syncBar(canPlay));

    return CallbackShortcuts(
      bindings: {
        // Both, because both are muscle memory: Ctrl+F from file managers and
        // browsers, Ctrl+K from everything built in the last five years.
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _openSearch,
      },
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Row(
                      children: [
                        // The rail runs to the top edge of the window, which is
                        // the point of drawing our own caption.
                        _Rail(key: _railKey, selected: _section, onSelect: _select, pendingCredits: ref.watch(pendingCreditCountProvider).value ?? 0),
                        VerticalDivider(width: 1, thickness: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
                        Expanded(
                          child: Column(
                            children: [
                              // Room for the caption strip, unless the page on
                              // top wants to bleed its own background behind
                              // it instead (see `_contentBleeds`) -- the
                              // strip itself is transparent either way, so
                              // this is only about keeping ordinary content
                              // from scrolling underneath the window buttons.
                              if (!_contentBleeds) const SizedBox(height: WindowChrome.height),
                              Expanded(child: _sections()),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  // The shade covers the rail as well as the content, so the
                  // artwork gets the whole window. The way back is the close
                  // button in its header and the chevron in the bar below, both
                  // of which stay visible.
                  Positioned.fill(child: _shadeLayer()),
                  // Above everything, including the shade: a window that cannot
                  // be moved or closed because a panel is open would be a poor
                  // trade for the extra immersion.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    // Rebuilt as the shade animates, because the shade's own
                    // controls live in this strip now.
                    child: AnimatedBuilder(
                      animation: _shade,
                      builder: (context, _) => WindowChrome(
                        content: _shadeOpen ? _shadeLeading() : (_chromeStack[_section]!.isEmpty ? _rootChromeFor(_section) : _chromeStack[_section]!.last.builder(context)),
                        trailing: _shadeOpen ? _shadeTrailing() : null,
                        // Zero while the shade is open: its own backdrop
                        // already covers the rail by then, so its controls
                        // can start flush left as they always have.
                        contentInset: _shadeOpen ? 0 : _railWidth + 1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Listens to both controllers: the bar's own reveal, and the shade's,
            // because the bar's chevron points the other way while the shade is
            // up and nothing else would rebuild it.
            AnimatedBuilder(
              animation: Listenable.merge([_bar, _shade]),
              builder: (context, _) {
                // Gone entirely, not merely zero pixels tall. A clipped bar would
                // leave every transport control in the tree at zero height, and a
                // zero-area interactive node is what crashed this app on the
                // Windows accessibility bridge.
                if (_bar.value == 0) return const SizedBox.shrink();
                return SizeTransition(
                  sizeFactor: _barCurve,
                  axis: Axis.vertical,
                  // Bottom-aligned, so the bar's own bottom edge stays put and
                  // the rest of it rises into view.
                  alignment: Alignment.bottomCenter,
                  child: PlayerBar(expanded: _shadeOpen, onToggleExpanded: () => _toggleShade(), onOpenQueue: () => _toggleShade(open: true, showQueue: true)),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The library sections, one navigation stack each.
  ///
  /// IndexedStack lays out every child, not just the visible one, so a plain
  /// one would keep all sections querying the database and decoding album art
  /// at all times. Sections are therefore built on first visit and kept alive
  /// after, which preserves their scroll position without paying for the ones
  /// nobody has opened.
  Widget _sections() => IndexedStack(
    index: _visitedOrder.indexOf(_section),
    children: [
      for (final section in _visitedOrder)
        Navigator(
          key: _navigatorKeys[section],
          onGenerateRoute: (settings) => MaterialPageRoute(settings: settings, builder: (_) => _rootFor(section)),
        ),
    ],
  );

  /// Fade for the shade's controls in the caption strip.
  ///
  /// Null below the threshold, so the controls are absent rather than sitting
  /// there at zero opacity. An invisible interactive node is the shape of bug
  /// that crashed this app on the Windows accessibility bridge, and it is not
  /// worth reintroducing for a fade.
  double? _shadeControlsOpacity() {
    if (_shade.value <= 0.01) return null;
    return Curves.easeOut.transform((_shade.value / 0.6).clamp(0.0, 1.0));
  }

  /// The shade's close button and title, for the caption strip.
  Widget? _shadeLeading() {
    final opacity = _shadeControlsOpacity();
    if (opacity == null) return null;
    final theme = Theme.of(context);

    return Opacity(
      opacity: opacity,
      child: Row(
        children: [
          IconButton(tooltip: 'Close now playing', onPressed: () => _toggleShade(open: false), icon: const Icon(Icons.keyboard_arrow_down)),
          const SizedBox(width: 4),
          Text('Now playing', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// The shade's lyrics and queue toggles, for the caption strip.
  Widget? _shadeTrailing() {
    final opacity = _shadeControlsOpacity();
    if (opacity == null) return null;
    final queueVisible = ref.watch(queuePaneVisibleProvider);
    final lyricsVisible = ref.watch(lyricsPaneVisibleProvider);
    final queueLength = ref.watch(playerProvider.select((s) => s.queue.length));

    return Opacity(
      opacity: opacity,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Row(
          children: [
            IconButton(
              tooltip: lyricsVisible ? 'Hide the lyrics' : 'Show the lyrics',
              isSelected: lyricsVisible,
              onPressed: () => _showSidePane(lyrics: !lyricsVisible),
              icon: const Icon(Icons.lyrics_outlined),
            ),
            IconButton(
              // The count lives in the tooltip rather than a badge: a permanent
              // red dot on a control that is not a notification reads as an
              // alert about nothing.
              tooltip: queueVisible ? 'Hide the queue' : 'Show the queue (${pluralize(queueLength, 'track')})',
              isSelected: queueVisible,
              onPressed: () => _showSidePane(queue: !queueVisible),
              icon: const Icon(Icons.queue_music),
            ),
          ],
        ),
      ),
    );
  }

  /// Shows one of the shade's side panes, which share a slot.
  ///
  /// Turning one on turns the other off. They occupy the same column, so
  /// leaving both on would mean the second one silently replacing the first --
  /// a toggle whose effect depends on hidden state is worse than one that
  /// visibly swaps.
  void _showSidePane({bool? queue, bool? lyrics}) {
    if (queue != null) {
      ref.read(queuePaneVisibleProvider.notifier).set(queue);
      if (queue) ref.read(lyricsPaneVisibleProvider.notifier).set(false);
    }
    if (lyrics != null) {
      ref.read(lyricsPaneVisibleProvider.notifier).set(lyrics);
      if (lyrics) ref.read(queuePaneVisibleProvider.notifier).set(false);
    }
  }

  /// The now-playing shade, drawn up from the bottom edge.
  ///
  /// Built only while it is showing, so the view's providers subscribe to
  /// nothing at all while it is closed.
  Widget _shadeLayer() {
    return AnimatedBuilder(
      animation: _shade,
      builder: (context, _) {
        if (_shade.value == 0) return const SizedBox.shrink();
        final progress = Curves.easeOutCubic.transform(_shade.value);
        // Fades in over the first part of the reveal and out over the last, so
        // the content is already legible while the panel is still travelling
        // and does not blink out of existence at the end.
        final opacity = Curves.easeOut.transform((_shade.value / 0.55).clamp(0.0, 1.0));
        return Opacity(
          opacity: opacity,
          child: LayoutBuilder(
            builder: (context, constraints) => ClipRect(
              // An Align with a heightFactor reveals a full-size child from
              // the bottom up. Shrinking the child instead would reflow every
              // line of text on the way, which reads as a glitch rather than
              // a slide.
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: progress,
                child: SizedBox(
                  height: constraints.maxHeight,
                  width: constraints.maxWidth,
                  child: NowPlayingView(topInset: WindowChrome.height, onOpenArtist: _openArtist, onOpenAlbum: _openAlbum, onEditTrack: _editTrack),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _rootFor(LibrarySection section) => switch (section) {
    LibrarySection.search => SearchView(onClear: _clearSearch, onOpenArtist: _openArtist, onOpenAlbum: _openAlbum, onOpenTag: _openTag, onOpenPlaylist: _openPlaylist, onEditTrack: _editTrack),
    LibrarySection.albums => AlbumsView(onOpenAlbum: _openAlbum, onOpenTrack: (trackId) => ref.read(playerProvider.notifier).playTrack(trackId)),
    LibrarySection.songs => SongsView(onOpenArtist: _openArtist, onOpenAlbum: _openAlbum, onEditTrack: _editTrack),
    LibrarySection.artists => ArtistsView(onOpenArtist: _openArtist, onOpenReview: _openCreditReview),
    LibrarySection.tags => TagsView(onOpenTag: _openTag),
    LibrarySection.playlists => PlaylistsView(onOpenPlaylist: _openPlaylist),
    LibrarySection.settings => const SettingsView(),
  };

  /// What the caption strip shows for a section's root page, before anything
  /// has been pushed onto its [_chromeStack].
  ///
  /// Parallels [_rootFor] one level up: that switch picks the page, this one
  /// picks what used to be that page's own toolbar row. Sections not yet
  /// migrated return null, which leaves the strip showing nothing but drag
  /// space for now -- the same as before this change, just without a toolbar
  /// underneath it either.
  Widget? _rootChromeFor(LibrarySection section) => switch (section) {
    LibrarySection.search => SearchToolbar(controller: _searchController, focusNode: _searchFocus, onClear: _clearSearch),
    LibrarySection.albums => const AlbumsToolbar(),
    LibrarySection.songs => const SongsToolbar(),
    LibrarySection.artists => const ArtistsToolbar(),
    LibrarySection.tags => const TagsToolbar(),
    LibrarySection.playlists => const PlaylistsToolbar(),
    // A static title, not its own toolbar widget: nothing here reads from a
    // provider, so there is nothing a dedicated widget would buy over this.
    LibrarySection.settings => const SectionTitle(icon: Icons.settings, label: 'Settings'),
  };
}

/// The navigation rail: the app name at the top, Settings at the foot.
class _Rail extends StatelessWidget {
  const _Rail({super.key, required this.selected, required this.onSelect, this.pendingCredits = 0});

  final LibrarySection selected;
  final ValueChanged<LibrarySection> onSelect;

  /// Credits waiting to be reviewed, badged onto Artists.
  final int pendingCredits;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final destinations = LibrarySection.railDestinations;
    final selectedIndex = destinations.indexOf(selected);

    return NavigationRail(
      // Settings is not one of the destinations, so nothing in the rail proper
      // is selected while it is open. A null index says exactly that.
      selectedIndex: selectedIndex < 0 ? null : selectedIndex,
      onDestinationSelected: (index) => onSelect(destinations[index]),
      labelType: NavigationRailLabelType.selected,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      groupAlignment: 0,
      // The rail's own scrolling, rather than a wrapper: labelled destinations
      // plus the logo and Settings do not fit once the player strip has taken
      // its share of a short window.
      scrollable: true,
      trailingAtBottom: true,
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Tooltip(
          message: 'marmelade',
          child: Text(
            'm',
            style: theme.textTheme.headlineMedium?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w300),
          ),
        ),
      ),
      trailing: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _RailFootButton(section: LibrarySection.settings, selected: selected == LibrarySection.settings, onTap: () => onSelect(LibrarySection.settings)),
      ),
      destinations: [
        for (final section in destinations) NavigationRailDestination(icon: _badged(section, section.icon), selectedIcon: _badged(section, section.selectedIcon), label: Text(section.label)),
      ],
    );
  }

  /// Badges the Artists destination with the number of credits awaiting review.
  ///
  /// A count that nobody sees is a count nobody acts on, and the review queue
  /// is invisible by nature: the library looks finished either way.
  Widget _badged(LibrarySection section, IconData icon) {
    if (section != LibrarySection.artists || pendingCredits == 0) {
      return Icon(icon);
    }
    return Badge(label: Text('$pendingCredits'), child: Icon(icon));
  }
}

/// A rail entry pinned below the destinations.
///
/// NavigationRail only bottom-aligns its `trailing` widget, and a destination
/// is always part of the scrolling group, so a bottom-aligned Settings has to
/// be built by hand. It is shaped to match a real destination -- pill
/// indicator, icon, label underneath -- because looking like a different kind
/// of control would suggest it does a different kind of thing.
class _RailFootButton extends StatelessWidget {
  const _RailFootButton({required this.section, required this.selected, required this.onTap});

  final LibrarySection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      width: 56,

      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 6),

          height: 32,
          decoration: ShapeDecoration(shape: const StadiumBorder(), color: selected ? scheme.secondaryContainer : Colors.transparent),
          child: Center(child: Icon(selected ? section.selectedIcon : section.icon, size: 20, color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}
