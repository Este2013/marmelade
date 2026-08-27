import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/library/album_detail_view.dart';
import '../features/library/albums_view.dart';
import '../features/library/artist_detail_view.dart';
import '../features/library/artists_view.dart';
import '../features/library/credit_review_view.dart';
import '../features/library/songs_view.dart';
import '../features/player/now_playing_view.dart';
import '../features/player/player_bar.dart';
import '../features/settings/settings_view.dart';
import '../core/debug/screenshotter.dart';
import '../core/logging/app_log.dart';
import '../data/db/enums.dart' show ScanTrigger;
import '../widgets/empty_state.dart';
import '../widgets/time_text.dart';
import 'providers.dart';
import 'window_chrome.dart';

/// Top-level sections.
///
/// Now playing is deliberately absent. It is not a place in the library, it is
/// the player itself, so it opens by drawing the player bar up over the content
/// rather than by taking a rail slot alongside Albums and Artists.
enum LibrarySection {
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
  static const railDestinations = [albums, songs, artists, tags, playlists];
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

class _AppShellState extends ConsumerState<AppShell>
    with TickerProviderStateMixin {
  var _section = LibrarySection.albums;

  /// Drives the now-playing shade, drawn up out of the player bar.
  late final AnimationController _shade = AnimationController(
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 240),
    vsync: this,
  );

  /// Drives the player bar itself, which slides up the first time there is
  /// something to play and stays out of the way until then.
  late final AnimationController _bar = AnimationController(
    duration: const Duration(milliseconds: 340),
    reverseDuration: const Duration(milliseconds: 240),
    vsync: this,
  );

  late final Animation<double> _barCurve = CurvedAnimation(
    parent: _bar,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
    Screenshotter.scheduleIfRequested();

    // Debug affordance: start playback without driving the mouse.
    if (Platform.environment['MARMELADE_PLAY'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        AppLog.instance.warn('play requested by MARMELADE_PLAY');
        await ref.read(playerProvider.notifier).togglePlayPause();
        final player = ref.read(playerProvider);
        AppLog.instance.info(
          'play requested',
          fields: {
            'status': player.status.name,
            'track': player.current?.title ?? '(none)',
            'error': player.errorMessage ?? '(none)',
          },
        );
      });
    }

    // Debug affordance: open a section, the credit review page, or the
    // now-playing shade without driving the mouse. Pixel-hunting a navigation
    // rail from a script is fragile; naming the destination is not.
    final section = Platform.environment['MARMELADE_SECTION'];
    if (section != null && section.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = LibrarySection.values
            .where((s) => s.name == section)
            .firstOrNull;
        if (target == null) {
          AppLog.instance.warn(
            'unknown MARMELADE_SECTION',
            fields: {
              'value': section,
              'known': LibrarySection.values.map((s) => s.name).join(','),
            },
          );
          return;
        }
        _select(target);
        if (Platform.environment['MARMELADE_OPEN_REVIEW'] == '1') {
          _openCreditReview();
        }
        final artist = int.tryParse(
          Platform.environment['MARMELADE_ARTIST'] ?? '',
        );
        if (artist != null) _openArtist(artist);
        final album = int.tryParse(
          Platform.environment['MARMELADE_ALBUM'] ?? '',
        );
        if (album != null) _openAlbum(album);
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final player = ref.read(playerProvider);
      if (player.hasTrack || player.hasQueue) _bar.value = 1;
    });

    if (Platform.environment['MARMELADE_NOW_PLAYING'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _toggleShade(open: true),
      );
    }

    // Debug affordance: reproduce a library refresh without driving the UI.
    // Indexing is where the app does its heaviest work, and being able to
    // trigger it from a script is the difference between reading a crash log
    // and guessing.
    if (Platform.environment['MARMELADE_AUTOSCAN'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        AppLog.instance.warn('autoscan requested by MARMELADE_AUTOSCAN');
        _select(LibrarySection.settings);
        await ref
            .read(indexProgressProvider.notifier)
            .refreshAll(trigger: ScanTrigger.startup);
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

  /// One navigator key per section, so each keeps its own history.
  final _navigatorKeys = {
    for (final section in LibrarySection.values)
      section: GlobalKey<NavigatorState>(),
  };

  /// Sections that have been opened, in the order they were first opened.
  ///
  /// Doubles as the child list of the section stack, so an unvisited section
  /// costs nothing at all.
  final _visitedOrder = <LibrarySection>[LibrarySection.albums];

  /// Whether the shade is open or on its way open.
  bool get _shadeOpen =>
      _shade.status == AnimationStatus.forward ||
      _shade.status == AnimationStatus.completed;

  void _toggleShade({bool? open, bool showQueue = false}) {
    final target = open ?? !_shadeOpen;
    if (target && showQueue) {
      ref.read(queuePaneVisibleProvider.notifier).set(true);
    }
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
      return;
    }
    setState(() {
      if (!_visitedOrder.contains(section)) _visitedOrder.add(section);
      _section = section;
    });
  }

  void _push(Widget page, {bool retry = true}) {
    final navigator = _navigatorKeys[_section]!.currentState;
    if (navigator == null) {
      // A section selected in this same frame has no Navigator yet, so the
      // push would silently do nothing. One retry after the tree is built is
      // enough; failing twice means the section is genuinely not there.
      if (retry) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _push(page, retry: false),
        );
      }
      return;
    }
    navigator.push(MaterialPageRoute(builder: (_) => page));
  }

  void _pop() => _navigatorKeys[_section]!.currentState?.maybePop();

  void _openAlbum(int albumId) => _push(
    AlbumDetailView(albumId: albumId, onOpenArtist: _openArtist, onBack: _pop),
  );

  void _openArtist(int artistId) => _push(
    ArtistDetailView(
      artistId: artistId,
      onOpenAlbum: _openAlbum,
      onOpenArtist: _openArtist,
      onBack: _pop,
    ),
  );

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

    // Nothing playing and nothing queued means no player bar at all, rather
    // than a permanent strip saying so.
    ref.listen(
      playerProvider.select((s) => s.hasTrack || s.hasQueue),
      (_, canPlay) => _syncBar(canPlay),
    );

    return Scaffold(
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
                      _Rail(
                        selected: _section,
                        onSelect: _select,
                        pendingCredits:
                            ref.watch(pendingCreditCountProvider).value ?? 0,
                      ),
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: scheme.outlineVariant.withValues(alpha: 0.4),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            // Room for the caption strip. The strip itself is
                            // transparent and drawn on top, so this keeps the
                            // content from scrolling underneath the window
                            // buttons.
                            const SizedBox(height: WindowChrome.height),
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
                      leading: _shadeLeading(),
                      trailing: _shadeTrailing(),
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
                child: PlayerBar(
                  expanded: _shadeOpen,
                  onToggleExpanded: () => _toggleShade(),
                  onOpenQueue: () => _toggleShade(open: true, showQueue: true),
                ),
              );
            },
          ),
        ],
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
          onGenerateRoute: (settings) => MaterialPageRoute(
            settings: settings,
            builder: (_) => _rootFor(section),
          ),
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
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Close now playing',
            onPressed: () => _toggleShade(open: false),
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
          const SizedBox(width: 4),
          Text(
            'Now playing',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// The shade's queue toggle, for the caption strip.
  Widget? _shadeTrailing() {
    final opacity = _shadeControlsOpacity();
    if (opacity == null) return null;
    final queueVisible = ref.watch(queuePaneVisibleProvider);
    final queueLength = ref.watch(playerProvider.select((s) => s.queue.length));

    return Opacity(
      opacity: opacity,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: IconButton(
          // The count lives in the tooltip rather than a badge: a permanent
          // red dot on a control that is not a notification reads as an alert
          // about nothing.
          tooltip: queueVisible
              ? 'Hide the queue'
              : 'Show the queue (${pluralize(queueLength, 'track')})',
          isSelected: queueVisible,
          onPressed: () =>
              ref.read(queuePaneVisibleProvider.notifier).toggle(),
          icon: const Icon(Icons.queue_music),
        ),
      ),
    );
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
        final opacity = Curves.easeOut.transform(
          (_shade.value / 0.55).clamp(0.0, 1.0),
        );
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
                  child: NowPlayingView(
                    topInset: WindowChrome.height,
                    onOpenArtist: _openArtist,
                    onOpenAlbum: _openAlbum,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _rootFor(LibrarySection section) => switch (section) {
    LibrarySection.albums => AlbumsView(
      onOpenAlbum: _openAlbum,
      onOpenTrack: (trackId) =>
          ref.read(playerProvider.notifier).playTrack(trackId),
    ),
    LibrarySection.songs => SongsView(
      onOpenArtist: _openArtist,
      onOpenAlbum: _openAlbum,
    ),
    LibrarySection.artists => ArtistsView(
      onOpenArtist: _openArtist,
      onOpenReview: _openCreditReview,
    ),
    LibrarySection.tags => const _NotYetView(
      icon: Icons.label_outline,
      title: 'Tags',
    ),
    LibrarySection.playlists => const _NotYetView(
      icon: Icons.playlist_play_outlined,
      title: 'Playlists',
    ),
    LibrarySection.settings => const SettingsView(),
  };
}

/// The navigation rail: the app name at the top, Settings at the foot.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.selected,
    required this.onSelect,
    this.pendingCredits = 0,
  });

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
      labelType: NavigationRailLabelType.all,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
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
            style: theme.textTheme.headlineMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w300,
            ),
          ),
        ),
      ),
      trailing: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _RailFootButton(
          section: LibrarySection.settings,
          selected: selected == LibrarySection.settings,
          onTap: () => onSelect(LibrarySection.settings),
        ),
      ),
      destinations: [
        for (final section in destinations)
          NavigationRailDestination(
            icon: _badged(section, section.icon),
            selectedIcon: _badged(section, section.selectedIcon),
            label: Text(section.label),
          ),
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
  const _RailFootButton({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  final LibrarySection section;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      width: 72,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: 56,
                height: 32,
                decoration: ShapeDecoration(
                  shape: const StadiumBorder(),
                  color: selected
                      ? scheme.secondaryContainer
                      : Colors.transparent,
                ),
                child: Center(
                  child: Icon(
                    selected ? section.selectedIcon : section.icon,
                    size: 24,
                    color: selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                section.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Placeholder for a section that is designed but not yet built.
///
/// Better than a blank panel: it says the section exists and is coming, rather
/// than looking broken.
class _NotYetView extends StatelessWidget {
  const _NotYetView({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: icon,
      title: title,
      message:
          'Not built yet. The data behind it is already indexed, so this '
          'view is the only thing missing.',
    );
  }
}
