import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/library/album_detail_view.dart';
import '../features/library/albums_view.dart';
import '../features/library/artist_detail_view.dart';
import '../features/library/artists_view.dart';
import '../features/library/songs_view.dart';
import '../features/player/player_bar.dart';
import '../features/settings/settings_view.dart';
import '../widgets/empty_state.dart';
import 'providers.dart';

/// Top-level sections, in rail order.
enum LibrarySection {
  albums('Albums', Icons.grid_view_outlined, Icons.grid_view_rounded),
  songs('Songs', Icons.music_note_outlined, Icons.music_note),
  artists('Artists', Icons.people_outline, Icons.people),
  tags('Tags', Icons.label_outline, Icons.label),
  playlists('Playlists', Icons.playlist_play_outlined, Icons.playlist_play),
  queue('Queue', Icons.queue_music_outlined, Icons.queue_music),
  settings('Settings', Icons.settings_outlined, Icons.settings);

  const LibrarySection(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
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

class _AppShellState extends ConsumerState<AppShell> {
  var _section = LibrarySection.albums;

  /// One navigator key per section, so each keeps its own history.
  final _navigatorKeys = {
    for (final section in LibrarySection.values)
      section: GlobalKey<NavigatorState>(),
  };

  void _select(LibrarySection section) {
    if (section == _section) {
      // Tapping the current section pops it back to its root, which is what
      // every other app with a rail does.
      _navigatorKeys[section]!.currentState?.popUntil((r) => r.isFirst);
      return;
    }
    setState(() => _section = section);
  }

  void _push(Widget page) {
    _navigatorKeys[_section]!.currentState?.push(
          MaterialPageRoute(builder: (_) => page),
        );
  }

  void _pop() => _navigatorKeys[_section]!.currentState?.maybePop();

  void _openAlbum(int albumId) => _push(AlbumDetailView(
        albumId: albumId,
        onOpenArtist: _openArtist,
        onBack: _pop,
      ));

  void _openArtist(int artistId) => _push(ArtistDetailView(
        artistId: artistId,
        onOpenAlbum: _openAlbum,
        onOpenArtist: _openArtist,
        onBack: _pop,
      ));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                _Rail(selected: _section, onSelect: _select),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
                Expanded(
                  child: IndexedStack(
                    index: LibrarySection.values.indexOf(_section),
                    children: [
                      for (final section in LibrarySection.values)
                        Navigator(
                          key: _navigatorKeys[section],
                          onGenerateRoute: (settings) => MaterialPageRoute(
                            settings: settings,
                            builder: (_) => _rootFor(section),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          PlayerBar(onExpand: () => _select(LibrarySection.queue)),
        ],
      ),
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
        LibrarySection.artists => ArtistsView(onOpenArtist: _openArtist),
        LibrarySection.tags => const _NotYetView(
            icon: Icons.label_outline,
            title: 'Tags',
          ),
        LibrarySection.playlists => const _NotYetView(
            icon: Icons.playlist_play_outlined,
            title: 'Playlists',
          ),
        LibrarySection.queue => const _NotYetView(
            icon: Icons.queue_music_outlined,
            title: 'Play queue',
          ),
        LibrarySection.settings => const SettingsView(),
      };
}

/// The navigation rail, with the app name at the top.
class _Rail extends StatelessWidget {
  const _Rail({required this.selected, required this.onSelect});

  final LibrarySection selected;
  final ValueChanged<LibrarySection> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // NavigationRail does not scroll, and seven labelled destinations plus the
    // logo do not fit once the player strip has taken its share of a short
    // window. Without this the rail overflows at the minimum window size the
    // app itself allows.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(
            child: NavigationRail(
              selectedIndex: LibrarySection.values.indexOf(selected),
              onDestinationSelected: (index) =>
                  onSelect(LibrarySection.values[index]),
              labelType: NavigationRailLabelType.all,
              backgroundColor: theme.colorScheme.surfaceContainerLow,
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
              destinations: [
                for (final section in LibrarySection.values)
                  NavigationRailDestination(
                    icon: Icon(section.icon),
                    selectedIcon: Icon(section.selectedIcon),
                    label: Text(section.label),
                  ),
              ],
            ),
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
      message: 'Not built yet. The data behind it is already indexed, so this '
          'view is the only thing missing.',
    );
  }
}
