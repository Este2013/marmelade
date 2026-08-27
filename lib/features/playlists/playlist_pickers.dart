import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../widgets/time_text.dart';
import 'playlists_view.dart';

/// Adds an album to a playlist, asking which one.
///
/// The tracks go in the album's running order, not the order a list happened to
/// show them in: adding a release to a playlist means adding it as a release.
Future<void> showAddAlbumToPlaylist(
  BuildContext context,
  WidgetRef ref,
  int albumId, {
  String? albumTitle,
}) async {
  final target = await _chooseTarget(
    context,
    ref,
    title: albumTitle == null
        ? 'Add this album to a playlist'
        : 'Add $albumTitle to a playlist',
  );
  if (target == null || !context.mounted) return;

  final added =
      await ref.read(playlistRepositoryProvider).addAlbum(target, albumId);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        added == 0
            ? 'That album has no tracks to add.'
            : 'Added ${pluralize(added, 'track')}',
      ),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// Offers the playlists, plus making a new one, and returns the chosen id.
Future<int?> _chooseTarget(
  BuildContext context,
  WidgetRef ref, {
  required String title,
}) async {
  final playlists = await ref.read(playlistsProvider.future);
  if (!context.mounted) return null;

  final chosen = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(title),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(-1),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.add, size: 18),
                SizedBox(width: 12),
                Text('New playlist...'),
              ],
            ),
          ),
        ),
        if (playlists.isNotEmpty) const Divider(),
        for (final playlist in playlists)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(playlist.id),
            child: Padding(
              // Indented by depth, so a nested playlist reads here as the same
              // thing it is in the playlists view.
              padding: EdgeInsets.only(
                left: playlist.depth * 20.0,
                top: 6,
                bottom: 6,
              ),
              child: Text(
                '${playlist.name} · '
                '${pluralize(playlist.trackCount, 'track')}',
              ),
            ),
          ),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return null;
  if (chosen != -1) return chosen;
  return createPlaylist(context, ref);
}

/// Searches for tracks and adds the chosen ones to [playlistId].
///
/// Multi-select, because filling a playlist one dialog at a time would be
/// tedious in exactly the situation this exists for.
Future<void> showAddTracksToPlaylist(
  BuildContext context,
  WidgetRef ref,
  int playlistId, {
  String? playlistName,
}) async {
  final chosen = await showDialog<List<int>>(
    context: context,
    builder: (context) => _TrackPickerDialog(
      title: playlistName == null
          ? 'Add songs'
          : 'Add songs to $playlistName',
      ref: ref,
    ),
  );
  if (chosen == null || chosen.isEmpty || !context.mounted) return;

  await ref.read(playlistRepositoryProvider).addTracks(playlistId, chosen);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Added ${pluralize(chosen.length, 'track')}'),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// Searches for an album and adds it to [playlistId].
Future<void> showAddAlbumToThisPlaylist(
  BuildContext context,
  WidgetRef ref,
  int playlistId, {
  String? playlistName,
}) async {
  final chosen = await showDialog<int>(
    context: context,
    builder: (context) => _AlbumPickerDialog(
      title: playlistName == null
          ? 'Add an album'
          : 'Add an album to $playlistName',
      ref: ref,
    ),
  );
  if (chosen == null || !context.mounted) return;

  final added =
      await ref.read(playlistRepositoryProvider).addAlbum(playlistId, chosen);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Added ${pluralize(added, 'track')}'),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// Type-to-find, multi-select track picker.
class _TrackPickerDialog extends StatefulWidget {
  const _TrackPickerDialog({required this.title, required this.ref});

  final String title;
  final WidgetRef ref;

  @override
  State<_TrackPickerDialog> createState() => _TrackPickerDialogState();
}

class _TrackPickerDialogState extends State<_TrackPickerDialog> {
  final _controller = TextEditingController();
  final _selected = <int>[];
  var _results =
      const <({int id, String title, String? artistLine, String? albumTitle})>[];
  var _searching = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    setState(() => _searching = true);
    final results =
        await widget.ref.read(playlistRepositoryProvider).findTracks(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search by title',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _controller.text.trim().isEmpty
                            ? 'Start typing to find songs.'
                            : _searching
                                ? 'Searching...'
                                : 'Nothing matches that.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final track = _results[index];
                        final picked = _selected.contains(track.id);
                        return CheckboxListTile(
                          dense: true,
                          value: picked,
                          title: Text(track.title),
                          subtitle: Text(
                            [
                              if (track.artistLine != null) track.artistLine!,
                              if (track.albumTitle != null) track.albumTitle!,
                            ].join(' · '),
                          ),
                          onChanged: (value) => setState(() {
                            // A list, not a set: the order they were ticked in
                            // is the order they are added in.
                            if (value == true) {
                              _selected.add(track.id);
                            } else {
                              _selected.remove(track.id);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected),
          child: Text(
            _selected.isEmpty
                ? 'Add'
                : 'Add ${pluralize(_selected.length, 'song')}',
          ),
        ),
      ],
    );
  }
}

/// Type-to-find album picker.
class _AlbumPickerDialog extends StatefulWidget {
  const _AlbumPickerDialog({required this.title, required this.ref});

  final String title;
  final WidgetRef ref;

  @override
  State<_AlbumPickerDialog> createState() => _AlbumPickerDialogState();
}

class _AlbumPickerDialogState extends State<_AlbumPickerDialog> {
  final _controller = TextEditingController();
  var _results =
      const <({int id, String title, String? artistName, int trackCount})>[];
  var _searching = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    setState(() => _searching = true);
    final results =
        await widget.ref.read(playlistRepositoryProvider).findAlbums(query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        height: 440,
        child: Column(
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search by title',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _results.isEmpty
                  ? Center(
                      child: Text(
                        _controller.text.trim().isEmpty
                            ? 'Start typing to find an album.'
                            : _searching
                                ? 'Searching...'
                                : 'Nothing matches that.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final album = _results[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.album_outlined),
                          title: Text(album.title),
                          subtitle: Text(
                            [
                              if (album.artistName != null) album.artistName!,
                              pluralize(album.trackCount, 'track'),
                            ].join(' · '),
                          ),
                          onTap: () => Navigator.of(context).pop(album.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
